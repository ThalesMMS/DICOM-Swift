// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Accelerate framework-backed DSP operations for the JPEG pipeline.
///
/// JLISwift only targets Apple platforms, so Accelerate is always available —
/// callers can depend on this enum without a `canImport` guard.

import Accelerate

enum AccelerateDSP {

    // MARK: - DCT

    /// Precomputed 8×8 normalized DCT-II matrix.
    ///
    /// `C[u][n] = α(u) · cos(π·(2n+1)·u / 16)` with `α(0) = 1/√8`, `α(u>0) = √(2/8) = 1/2`.
    /// (Earlier revisions used half-scale α and produced quarter-magnitude coefficients
    /// — quantization then nuked everything.)
    static let dctMatrix: [Float] = {
        var matrix = [Float](repeating: 0, count: 64)
        for u in 0..<8 {
            let alpha: Float = u == 0 ? 1.0 / sqrt(8.0) : sqrt(2.0 / 8.0)
            for n in 0..<8 {
                matrix[u * 8 + n] = alpha * cos(Float(2 * n + 1) * Float(u) * .pi / 16.0)
            }
        }
        return matrix
    }()

    /// Transposed DCT matrix.
    static let dctMatrixTransposed: [Float] = {
        var transposed = [Float](repeating: 0, count: 64)
        for i in 0..<8 {
            for j in 0..<8 {
                transposed[j * 8 + i] = dctMatrix[i * 8 + j]
            }
        }
        return transposed
    }()

    /// Forward 2D DCT-II on an 8×8 block via `vDSP_mmul`. `F = C · f · Cᵀ`.
    ///
    /// Convenience wrapper that allocates output. Hot paths should use
    /// ``forwardDCT(_:into:scratch:)`` to reuse buffers across blocks.
    static func forwardDCT(_ block: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: 64)
        var scratch = [Float](repeating: 0, count: 64)
        forwardDCT(block, into: &output, scratch: &scratch)
        return output
    }

    /// Inverse 2D DCT-II on an 8×8 block via `vDSP_mmul`. `f = Cᵀ · F · C`.
    static func inverseDCT(_ block: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: 64)
        var scratch = [Float](repeating: 0, count: 64)
        inverseDCT(block, into: &output, scratch: &scratch)
        return output
    }

    /// Forward DCT into a caller-supplied output buffer; pass a reusable 64-element
    /// `scratch` buffer to eliminate per-block allocation in tight encoding loops.
    static func forwardDCT(
        _ block: [Float], into output: inout [Float], scratch: inout [Float]
    ) {
        precondition(block.count == 64 && output.count == 64 && scratch.count == 64)
        vDSP_mmul(dctMatrix, 1, block, 1, &scratch, 1, 8, 8, 8)
        vDSP_mmul(scratch, 1, dctMatrixTransposed, 1, &output, 1, 8, 8, 8)
    }

    /// Inverse DCT into a caller-supplied output buffer.
    static func inverseDCT(
        _ block: [Float], into output: inout [Float], scratch: inout [Float]
    ) {
        precondition(block.count == 64 && output.count == 64 && scratch.count == 64)
        vDSP_mmul(dctMatrixTransposed, 1, block, 1, &scratch, 1, 8, 8, 8)
        vDSP_mmul(scratch, 1, dctMatrix, 1, &output, 1, 8, 8, 8)
    }

    // MARK: - Batched DCT
    //
    // For a 512×512 4:4:4 encode, the per-block DCT path issues ~12k `vDSP_mmul`
    // calls. Each call's dispatch overhead is in the hundreds of nanoseconds — for
    // an 8×8 matmul that's only ~1k FLOPs, the overhead dominates the actual work
    // by an order of magnitude. The batched routines below collapse all of those
    // calls into two large mmuls, with one O(N×64) rearrangement in between.
    //
    // Layout: every batch buffer is sized `blockCount * 64`, with block `i` at
    // offset `64*i` and stored row-major within (matches what the encoder extracts
    // from image planes and what dequantize naturally produces in the decoder).

    /// Forward DCT-II on `n` contiguous 8×8 blocks: `F_i = C · f_i · Cᵀ` for each i.
    ///
    /// `input` and `output` are both at least `n * 64` long; only the first `n * 64`
    /// elements are read/written. `output` may NOT alias `input`. `scratch` is also
    /// caller-supplied and may be oversized (so a single allocation can serve
    /// multiple consecutive batches of different sizes).
    static func forwardDCTBatch(
        _ input: [Float], into output: inout [Float], scratch: inout [Float],
        blockCount n: Int
    ) {
        precondition(input.count >= n * 64 && output.count >= n * 64 && scratch.count >= n * 64)
        guard n > 0 else { return }
        let eightN = vDSP_Length(8 * n)

        // Pack input (per-block-contig) into M-layout (8 × 8N row-major) where
        // block i occupies columns [8i, 8i+8). After packing,
        //   M[r * 8N + 8i + c] == input[64i + 8r + c].
        // We use the scratch buffer as M.
        input.withUnsafeBufferPointer { inBuf in
            scratch.withUnsafeMutableBufferPointer { mBuf in
                let src = inBuf.baseAddress!
                let dst = mBuf.baseAddress!
                let rowStride = 8 * n
                for i in 0..<n {
                    for r in 0..<8 {
                        // 8 contiguous floats per row of one block.
                        memcpy(
                            dst + r * rowStride + 8 * i,
                            src + 64 * i + 8 * r,
                            8 * MemoryLayout<Float>.size
                        )
                    }
                }
            }
        }

        // Pass 1: T = C · M, both shaped (8 × 8N). Write into `output` to free
        // scratch for the next rearrangement.
        vDSP_mmul(dctMatrix, 1, scratch, 1, &output, 1, 8, eightN, 8)

        // Rearrange T (8 × 8N col-block-major) → V (8N × 8 per-block-contig)
        // for the second-pass right-multiply. After rearranging,
        //   V[64i + 8r + c] == T[r * 8N + 8i + c].
        output.withUnsafeBufferPointer { tBuf in
            scratch.withUnsafeMutableBufferPointer { vBuf in
                let src = tBuf.baseAddress!
                let dst = vBuf.baseAddress!
                let rowStride = 8 * n
                for i in 0..<n {
                    for r in 0..<8 {
                        memcpy(
                            dst + 64 * i + 8 * r,
                            src + r * rowStride + 8 * i,
                            8 * MemoryLayout<Float>.size
                        )
                    }
                }
            }
        }

        // Pass 2: F = V · Cᵀ, both shaped (8N × 8). Output is per-block-contig.
        vDSP_mmul(scratch, 1, dctMatrixTransposed, 1, &output, 1, eightN, 8, 8)
    }

    /// Inverse DCT-II on `n` contiguous 8×8 blocks: `f_i = Cᵀ · F_i · C` for each i.
    /// Same layout/aliasing rules as ``forwardDCTBatch(_:into:scratch:blockCount:)``.
    static func inverseDCTBatch(
        _ input: [Float], into output: inout [Float], scratch: inout [Float],
        blockCount n: Int
    ) {
        precondition(input.count >= n * 64 && output.count >= n * 64 && scratch.count >= n * 64)
        guard n > 0 else { return }
        let eightN = vDSP_Length(8 * n)

        // Pack input → M (8 × 8N col-block layout).
        input.withUnsafeBufferPointer { inBuf in
            scratch.withUnsafeMutableBufferPointer { mBuf in
                let src = inBuf.baseAddress!
                let dst = mBuf.baseAddress!
                let rowStride = 8 * n
                for i in 0..<n {
                    for r in 0..<8 {
                        memcpy(
                            dst + r * rowStride + 8 * i,
                            src + 64 * i + 8 * r,
                            8 * MemoryLayout<Float>.size
                        )
                    }
                }
            }
        }

        // Pass 1: T = Cᵀ · M, both shaped (8 × 8N).
        vDSP_mmul(dctMatrixTransposed, 1, scratch, 1, &output, 1, 8, eightN, 8)

        // Rearrange T → V (8N × 8 per-block-contig).
        output.withUnsafeBufferPointer { tBuf in
            scratch.withUnsafeMutableBufferPointer { vBuf in
                let src = tBuf.baseAddress!
                let dst = vBuf.baseAddress!
                let rowStride = 8 * n
                for i in 0..<n {
                    for r in 0..<8 {
                        memcpy(
                            dst + 64 * i + 8 * r,
                            src + r * rowStride + 8 * i,
                            8 * MemoryLayout<Float>.size
                        )
                    }
                }
            }
        }

        // Pass 2: f = V · C, both shaped (8N × 8). Output per-block-contig.
        vDSP_mmul(scratch, 1, dctMatrix, 1, &output, 1, eightN, 8, 8)
    }

    /// Inverse DCT on `n` blocks straight from entropy-order coefficients: the
    /// pack pass gathers `Float(zigzag[64i + invZig[8r+c]]) · quantTable[8r+c]`
    /// directly into the GEMM layout, fusing the inverse-zigzag scatter and the
    /// dequantize pass (and their two intermediate buffers) into the data
    /// movement that had to happen anyway. Per element this is the exact same
    /// Int32→Float convert and IEEE multiply at the exact same value the
    /// separate passes performed, so the GEMM input — and the whole decode —
    /// is bit-identical.
    ///
    /// Pointer-based so disjoint block ranges can run on separate cores;
    /// `output` and `scratch` must each hold `64·n` floats for *this* range.
    static func inverseDCTBatchDequantized(
        zigzag: UnsafePointer<Int32>, quantTable qt: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>, scratch: UnsafeMutablePointer<Float>,
        blockCount n: Int
    ) {
        guard n > 0 else { return }
        let eightN = vDSP_Length(8 * n)
        let rowStride = 8 * n

        // Fused pack: M[r·8N + 8i + c] = dequant(zigzag coefficient at natural
        // position 8r+c) — replaces inverse-zigzag scatter + dequant sweep + pack
        // memcpy with one pass.
        Quantization.inverseZigzagOrder.withUnsafeBufferPointer { izb in
            let invZig = izb.baseAddress!
            for i in 0..<n {
                let src = zigzag + 64 * i
                for r in 0..<8 {
                    let dst = scratch + r * rowStride + 8 * i
                    let qrow = qt + 8 * r
                    let zrow = invZig + 8 * r
                    for c in 0..<8 {
                        dst[c] = Float(src[zrow[c]]) * qrow[c]
                    }
                }
            }
        }

        // Pass 1: T = Cᵀ · M (8 × 8N).
        vDSP_mmul(dctMatrixTransposed, 1, scratch, 1, output, 1, 8, eightN, 8)

        // Rearrange T → V (8N × 8 per-block-contig).
        for i in 0..<n {
            for r in 0..<8 {
                memcpy(scratch + 64 * i + 8 * r,
                       output + r * rowStride + 8 * i,
                       8 * MemoryLayout<Float>.size)
            }
        }

        // Pass 2: f = V · C (8N × 8). Output per-block-contig.
        vDSP_mmul(scratch, 1, dctMatrix, 1, output, 1, eightN, 8, 8)
    }

    // MARK: - Image-level color conversion (BT.601)

    /// Converts interleaved RGB(A) bytes to planar Y/Cb/Cr Float planes via vDSP.
    ///
    /// `componentCount` is 3 for tight-packed RGB or 4 for RGBA (alpha is ignored).
    /// All three output planes are sized `pixelCount` elements. This replaces a per-pixel
    /// Swift loop with stride-aware `vDSP_vfltu8` deinterleaves plus three fused
    /// multiply-add chains — typically 4–8× faster on large images.
    static func imageRGBToYCbCr(
        data: [UInt8], pixelCount: Int, componentCount: Int
    ) -> (y: [Float], cb: [Float], cr: [Float]) {
        precondition(componentCount == 3 || componentCount == 4)
        precondition(data.count >= pixelCount * componentCount)

        let n = vDSP_Length(pixelCount)
        let stride = vDSP_Stride(componentCount)

        // Outputs allocated *uninitialized* (vDSP fully overwrites every element,
        // so the zero-fill is wasted) and returned directly (no copy). R/G/B live
        // in one uninitialized scratch block. All vDSP calls use raw pointers so
        // the in-place `vDSP_vsma` chain doesn't trip Swift array copy-on-write
        // (the previous `&y … y … &y` form copied `y` on every call). Same math →
        // byte-identical output.
        func uninit() -> [Float] {
            [Float](unsafeUninitializedCapacity: pixelCount) { _, c in c = pixelCount }
        }
        var y = uninit(), cb = uninit(), cr = uninit()
        let rgbScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: pixelCount * 3)
        defer { rgbScratch.deallocate() }
        let r = rgbScratch.baseAddress!, g = r + pixelCount, b = r + pixelCount * 2

        data.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            if componentCount == 3 {
                // Strided vDSP_vfltu8 gathers were the single biggest encode
                // stage (~18%): one byte per 3 touched per pass, 3 passes. Split
                // instead into a vImage byte deinterleave (pure data movement)
                // + 3 stride-1 widening passes — same conversion per element,
                // byte-identical output, sequential memory traffic.
                let planes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: pixelCount * 3)
                defer { planes.deallocate() }
                let pr = planes.baseAddress!, pg = pr + pixelCount, pb = pr + pixelCount * 2
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: 1,
                                        width: vImagePixelCount(pixelCount), rowBytes: pixelCount * 3)
                var dR = vImage_Buffer(data: pr, height: 1,
                                       width: vImagePixelCount(pixelCount), rowBytes: pixelCount)
                var dG = vImage_Buffer(data: pg, height: 1,
                                       width: vImagePixelCount(pixelCount), rowBytes: pixelCount)
                var dB = vImage_Buffer(data: pb, height: 1,
                                       width: vImagePixelCount(pixelCount), rowBytes: pixelCount)
                vImageConvert_RGB888toPlanar8(&src, &dR, &dG, &dB, vImage_Flags(kvImageNoFlags))
                vDSP_vfltu8(pr, 1, r, 1, n)
                vDSP_vfltu8(pg, 1, g, 1, n)
                vDSP_vfltu8(pb, 1, b, 1, n)
            } else {
                vDSP_vfltu8(base + 0, stride, r, 1, n)
                vDSP_vfltu8(base + 1, stride, g, 1, n)
                vDSP_vfltu8(base + 2, stride, b, 1, n)
            }
        }

        var center: Float = 128.0
        // Y = 0.299 R + 0.587 G + 0.114 B
        var yR: Float = 0.299, yG: Float = 0.587, yB: Float = 0.114
        y.withUnsafeMutableBufferPointer { yp in
            let yb = yp.baseAddress!
            vDSP_vsmul(r, 1, &yR, yb, 1, n)
            vDSP_vsma(g, 1, &yG, yb, 1, yb, 1, n)
            vDSP_vsma(b, 1, &yB, yb, 1, yb, 1, n)
        }
        // Cb = -0.168736 R - 0.331264 G + 0.5 B + 128
        var cbR: Float = -0.168736, cbG: Float = -0.331264, cbB: Float = 0.5
        cb.withUnsafeMutableBufferPointer { cbp in
            let cbb = cbp.baseAddress!
            vDSP_vsmul(r, 1, &cbR, cbb, 1, n)
            vDSP_vsma(g, 1, &cbG, cbb, 1, cbb, 1, n)
            vDSP_vsma(b, 1, &cbB, cbb, 1, cbb, 1, n)
            vDSP_vsadd(cbb, 1, &center, cbb, 1, n)
        }
        // Cr = 0.5 R - 0.418688 G - 0.081312 B + 128
        var crR: Float = 0.5, crG: Float = -0.418688, crB: Float = -0.081312
        cr.withUnsafeMutableBufferPointer { crp in
            let crb = crp.baseAddress!
            vDSP_vsmul(r, 1, &crR, crb, 1, n)
            vDSP_vsma(g, 1, &crG, crb, 1, crb, 1, n)
            vDSP_vsma(b, 1, &crB, crb, 1, crb, 1, n)
            vDSP_vsadd(crb, 1, &center, crb, 1, n)
        }
        return (y, cb, cr)
    }

    /// Converts planar Y/Cb/Cr Float planes back to interleaved RGB bytes via vDSP.
    static func imageYCbCrToRGB(
        y: [Float], cb: [Float], cr: [Float], pixelCount: Int
    ) -> [UInt8] {
        precondition(y.count == pixelCount && cb.count == pixelCount && cr.count == pixelCount)
        let n = vDSP_Length(pixelCount)

        // One uninitialized scratch block (cbS, crS, r, g, b) + raw pointers so
        // the in-place `g` updates don't trip copy-on-write, and no buffer is
        // zero-filled before vDSP overwrites it. Output allocated uninitialized
        // (the 3 strided vDSP_vfixru8 cover every byte). Byte-identical math.
        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: pixelCount * 5)
        defer { scratch.deallocate() }
        let cbS = scratch.baseAddress!
        let crS = cbS + pixelCount, r = cbS + pixelCount * 2
        let g = cbS + pixelCount * 3, b = cbS + pixelCount * 4

        var neg128: Float = -128.0
        var rCr: Float = 1.402, gCb: Float = -0.344136, gCr: Float = -0.714136, bCb: Float = 1.772
        var lo: Float = 0.0, hi: Float = 255.0

        return y.withUnsafeBufferPointer { yp in
            cb.withUnsafeBufferPointer { cbp in
                cr.withUnsafeBufferPointer { crp in
                    let yb = yp.baseAddress!, cbb = cbp.baseAddress!, crb = crp.baseAddress!
                    vDSP_vsadd(cbb, 1, &neg128, cbS, 1, n)
                    vDSP_vsadd(crb, 1, &neg128, crS, 1, n)
                    // R = Y + 1.402 Cr',  G = Y - 0.344136 Cb' - 0.714136 Cr',  B = Y + 1.772 Cb'
                    vDSP_vsma(crS, 1, &rCr, yb, 1, r, 1, n)
                    vDSP_vsmul(cbS, 1, &gCb, g, 1, n)
                    vDSP_vsma(crS, 1, &gCr, g, 1, g, 1, n)
                    vDSP_vadd(yb, 1, g, 1, g, 1, n)
                    vDSP_vsma(cbS, 1, &bCb, yb, 1, b, 1, n)
                    vDSP_vclip(r, 1, &lo, &hi, r, 1, n)
                    vDSP_vclip(g, 1, &lo, &hi, g, 1, n)
                    vDSP_vclip(b, 1, &lo, &hi, b, 1, n)
                    // vDSP_vfixru8 rounds to nearest (ties to even), matching the
                    // scalar `Int(value.rounded())` semantics. The strided form of
                    // these three stores was the single biggest decode stage
                    // (~31% wall, half of it in vfixru8 alone): each pass touched
                    // one byte in 3 across the whole image. Convert stride-1 into
                    // contiguous byte planes instead (identical rounding — only
                    // the addressing changes) and interleave with one vImage pass
                    // (pure byte movement) → byte-identical output.
                    let planes = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: pixelCount * 3)
                    defer { planes.deallocate() }
                    let pr = planes.baseAddress!, pg = pr + pixelCount, pb = pr + pixelCount * 2
                    vDSP_vfixru8(r, 1, pr, 1, n)
                    vDSP_vfixru8(g, 1, pg, 1, n)
                    vDSP_vfixru8(b, 1, pb, 1, n)
                    return [UInt8](unsafeUninitializedCapacity: pixelCount * 3) { buf, cnt in
                        var sR = vImage_Buffer(data: pr, height: 1,
                                               width: vImagePixelCount(pixelCount), rowBytes: pixelCount)
                        var sG = vImage_Buffer(data: pg, height: 1,
                                               width: vImagePixelCount(pixelCount), rowBytes: pixelCount)
                        var sB = vImage_Buffer(data: pb, height: 1,
                                               width: vImagePixelCount(pixelCount), rowBytes: pixelCount)
                        var dst = vImage_Buffer(data: buf.baseAddress!, height: 1,
                                                width: vImagePixelCount(pixelCount), rowBytes: pixelCount * 3)
                        vImageConvert_Planar8toRGB888(&sR, &sG, &sB, &dst, vImage_Flags(kvImageNoFlags))
                        cnt = pixelCount * 3
                    }
                }
            }
        }
    }

    // MARK: - 16-bit (12-bit precision) color conversion
    //
    // Separate from the 8-bit path above so that path stays bit-identical. Input
    // and output samples are little-endian UInt16; `center` is the chroma offset
    // 2^(P-1) (2048 for 12-bit) and `maxValue` is 2^P-1 (4095). The BT.601 matrix
    // is the same — only the sample range and IO width differ.

    /// Converts interleaved little-endian UInt16 RGB(A) to planar Y/Cb/Cr planes.
    static func imageRGB16ToYCbCr(
        data: [UInt8], pixelCount: Int, componentCount: Int, center: Float
    ) -> (y: [Float], cb: [Float], cr: [Float]) {
        precondition(componentCount == 3 || componentCount == 4)
        precondition(data.count >= pixelCount * componentCount * 2)

        // Same structure as the 8-bit path post-0.2.0: one uninitialized scratch
        // block for R/G/B, uninitialized outputs, and raw pointers throughout so
        // the in-place vDSP_vsma chains can't trip array copy-on-write (the
        // `y … &y` form copies the plane per call). Identical math → identical
        // bytes; only the redundant zero-fills and COW copies go away.
        func uninit() -> [Float] {
            [Float](unsafeUninitializedCapacity: pixelCount) { _, c in c = pixelCount }
        }
        var y = uninit(), cb = uninit(), cr = uninit()
        let rgbScratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: pixelCount * 3)
        defer { rgbScratch.deallocate() }
        let r = rgbScratch.baseAddress!, g = r + pixelCount, b = r + pixelCount * 2

        // Scalar little-endian deinterleave — UInt8 storage isn't UInt16-aligned.
        data.withUnsafeBufferPointer { buf in
            let s = buf.baseAddress!
            for i in 0..<pixelCount {
                let p = i * componentCount * 2
                r[i] = Float(UInt16(s[p])     | (UInt16(s[p + 1]) << 8))
                g[i] = Float(UInt16(s[p + 2]) | (UInt16(s[p + 3]) << 8))
                b[i] = Float(UInt16(s[p + 4]) | (UInt16(s[p + 5]) << 8))
            }
        }

        let n = vDSP_Length(pixelCount)
        var ctr = center
        var yR: Float = 0.299, yG: Float = 0.587, yB: Float = 0.114
        y.withUnsafeMutableBufferPointer { yp in
            let yb = yp.baseAddress!
            vDSP_vsmul(r, 1, &yR, yb, 1, n)
            vDSP_vsma(g, 1, &yG, yb, 1, yb, 1, n)
            vDSP_vsma(b, 1, &yB, yb, 1, yb, 1, n)
        }
        var cbR: Float = -0.168736, cbG: Float = -0.331264, cbB: Float = 0.5
        cb.withUnsafeMutableBufferPointer { cbp in
            let cbb = cbp.baseAddress!
            vDSP_vsmul(r, 1, &cbR, cbb, 1, n)
            vDSP_vsma(g, 1, &cbG, cbb, 1, cbb, 1, n)
            vDSP_vsma(b, 1, &cbB, cbb, 1, cbb, 1, n)
            vDSP_vsadd(cbb, 1, &ctr, cbb, 1, n)
        }
        var crR: Float = 0.5, crG: Float = -0.418688, crB: Float = -0.081312
        cr.withUnsafeMutableBufferPointer { crp in
            let crb = crp.baseAddress!
            vDSP_vsmul(r, 1, &crR, crb, 1, n)
            vDSP_vsma(g, 1, &crG, crb, 1, crb, 1, n)
            vDSP_vsma(b, 1, &crB, crb, 1, crb, 1, n)
            vDSP_vsadd(crb, 1, &ctr, crb, 1, n)
        }
        return (y, cb, cr)
    }

    /// Converts planar Y/Cb/Cr back to interleaved little-endian UInt16 RGB,
    /// de-centering chroma at `center` and clamping to `0...maxValue`.
    static func imageYCbCr16ToRGB(
        y: [Float], cb: [Float], cr: [Float], pixelCount: Int, center: Float, maxValue: Float
    ) -> [UInt8] {
        precondition(y.count == pixelCount && cb.count == pixelCount && cr.count == pixelCount)
        let n = vDSP_Length(pixelCount)

        // One scratch block (cbS, crS, r, g, b) + raw pointers — same fix as the
        // 8-bit path: the previous `g … &g` in-place forms copied the plane per
        // call and every buffer was zero-filled before being fully overwritten.
        // Identical op sequence on identical values → byte-identical output.
        let scratch = UnsafeMutableBufferPointer<Float>.allocate(capacity: pixelCount * 5)
        defer { scratch.deallocate() }
        let cbS = scratch.baseAddress!
        let crS = cbS + pixelCount, r = cbS + pixelCount * 2
        let g = cbS + pixelCount * 3, b = cbS + pixelCount * 4

        var negCenter = -center
        var rCr: Float = 1.402
        var gCb: Float = -0.344136, gCr: Float = -0.714136
        var bCb: Float = 1.772
        var lo: Float = 0.0, hi = maxValue

        return y.withUnsafeBufferPointer { yp in
            cb.withUnsafeBufferPointer { cbp in
                cr.withUnsafeBufferPointer { crp in
                    let yb = yp.baseAddress!, cbb = cbp.baseAddress!, crb = crp.baseAddress!
                    vDSP_vsadd(cbb, 1, &negCenter, cbS, 1, n)
                    vDSP_vsadd(crb, 1, &negCenter, crS, 1, n)
                    vDSP_vsma(crS, 1, &rCr, yb, 1, r, 1, n)
                    vDSP_vsmul(cbS, 1, &gCb, g, 1, n)
                    vDSP_vsma(crS, 1, &gCr, g, 1, g, 1, n)
                    vDSP_vadd(yb, 1, g, 1, g, 1, n)
                    vDSP_vsma(cbS, 1, &bCb, yb, 1, b, 1, n)
                    vDSP_vclip(r, 1, &lo, &hi, r, 1, n)
                    vDSP_vclip(g, 1, &lo, &hi, g, 1, n)
                    vDSP_vclip(b, 1, &lo, &hi, b, 1, n)

                    var out = [UInt8](unsafeUninitializedCapacity: pixelCount * 6) {
                        _, c in c = pixelCount * 6
                    }
                    out.withUnsafeMutableBufferPointer { op in
                        let o = op.baseAddress!
                        for i in 0..<pixelCount {
                            let p = i * 6
                            let rv = UInt16(r[i].rounded(.toNearestOrEven))
                            let gv = UInt16(g[i].rounded(.toNearestOrEven))
                            let bv = UInt16(b[i].rounded(.toNearestOrEven))
                            o[p]     = UInt8(rv & 0xFF); o[p + 1] = UInt8(rv >> 8)
                            o[p + 2] = UInt8(gv & 0xFF); o[p + 3] = UInt8(gv >> 8)
                            o[p + 4] = UInt8(bv & 0xFF); o[p + 5] = UInt8(bv >> 8)
                        }
                    }
                    return out
                }
            }
        }
    }

    // MARK: - Batched quantization

    /// Quantize `n` contiguous 8×8 blocks against a single 64-element inverse table.
    ///
    /// `input` and `output` are sized `n * 64`. `invTable[k] = 1.0 / table[k]` —
    /// the encoder precomputes this once. Uses a tight pointer loop with `i & 63`
    /// table indexing; LLVM autovectorizes the multiply/round/convert into NEON.
    /// Avoids per-block dispatch overhead from the prior `vDSP_vmul`/`vDSP_vfix32`
    /// pair (which also allocated two scratch arrays per call).
    static func quantizeBatch(
        _ input: [Float], invTable: [Float],
        into output: inout [Int32], blockCount n: Int
    ) {
        precondition(input.count >= n * 64 && invTable.count == 64 && output.count >= n * 64)
        input.withUnsafeBufferPointer { inBuf in
            invTable.withUnsafeBufferPointer { invBuf in
                output.withUnsafeMutableBufferPointer { outBuf in
                    let inP = inBuf.baseAddress!
                    let invP = invBuf.baseAddress!
                    let outP = outBuf.baseAddress!
                    for i in 0..<(n * 64) {
                        let q = (inP[i] * invP[i & 63]).rounded(.toNearestOrEven)
                        outP[i] = Int32(q)
                    }
                }
            }
        }
    }

    /// Dequantize `n` contiguous 8×8 blocks against a single 64-element table.
    static func dequantizeBatch(
        _ input: [Int32], table: [Float],
        into output: inout [Float], blockCount n: Int
    ) {
        precondition(input.count >= n * 64 && table.count == 64 && output.count >= n * 64)
        input.withUnsafeBufferPointer { inBuf in
            table.withUnsafeBufferPointer { tabBuf in
                output.withUnsafeMutableBufferPointer { outBuf in
                    let inP = inBuf.baseAddress!
                    let tabP = tabBuf.baseAddress!
                    let outP = outBuf.baseAddress!
                    for i in 0..<(n * 64) {
                        outP[i] = Float(inP[i]) * tabP[i & 63]
                    }
                }
            }
        }
    }

    // MARK: - Vectorized quantization / level shift

    /// Subtract 128 from each element (in-place).
    static func levelShiftDown(_ block: inout [Float]) {
        var offset: Float = -128.0
        vDSP_vsadd(block, 1, &offset, &block, 1, 64)
    }

    /// Add 128, clamp to [0, 255], in-place.
    static func levelShiftUpClamped(_ block: inout [Float]) {
        var offset: Float = 128.0
        var lo: Float = 0.0
        var hi: Float = 255.0
        vDSP_vsadd(block, 1, &offset, &block, 1, 64)
        vDSP_vclip(block, 1, &lo, &hi, &block, 1, 64)
    }

    /// Divide block by quantization table (precomputed as reciprocals) and round to int.
    /// Pass `invTable` = `1.0 / table[i]` (computed once per encode).
    static func quantize(
        _ block: [Float], invTable: [Float], into output: inout [Int32]
    ) {
        precondition(block.count == 64 && invTable.count == 64 && output.count == 64)
        var scratch = [Float](repeating: 0, count: 64)
        vDSP_vmul(block, 1, invTable, 1, &scratch, 1, 64)
        var rounded = [Float](repeating: 0, count: 64)
        // vDSP_vrnd rounds to nearest even (the IEEE default), matching jpegli/IJG.
        for i in 0..<64 { rounded[i] = scratch[i].rounded(.toNearestOrEven) }
        vDSP_vfix32(rounded, 1, &output, 1, 64)
    }

    /// Multiply quantized coefficients by quantization table → float DCT coefficients.
    static func dequantize(
        _ quantized: [Int32], table: [Float], into output: inout [Float]
    ) {
        precondition(quantized.count == 64 && table.count == 64 && output.count == 64)
        var asFloat = [Float](repeating: 0, count: 64)
        vDSP_vflt32(quantized, 1, &asFloat, 1, 64)
        vDSP_vmul(asFloat, 1, table, 1, &output, 1, 64)
    }

    // MARK: - Color Conversion

    /// Converts RGB to YCbCr for a row of pixels using Accelerate vector operations.
    ///
    /// - Parameters:
    ///   - r: Red channel values (0–255 as Float).
    ///   - g: Green channel values.
    ///   - b: Blue channel values.
    /// - Returns: (Y, Cb, Cr) channel arrays.
    static func rgbToYCbCr(
        r: [Float], g: [Float], b: [Float]
    ) -> (y: [Float], cb: [Float], cr: [Float]) {
        let count = r.count
        var y = [Float](repeating: 0, count: count)
        var cb = [Float](repeating: 0, count: count)
        var cr = [Float](repeating: 0, count: count)

        // Y = 0.299R + 0.587G + 0.114B
        var temp1 = [Float](repeating: 0, count: count)
        var temp2 = [Float](repeating: 0, count: count)
        var scale: Float = 0.299
        vDSP_vsmul(r, 1, &scale, &y, 1, vDSP_Length(count))
        scale = 0.587
        vDSP_vsmul(g, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(y, 1, temp1, 1, &y, 1, vDSP_Length(count))
        scale = 0.114
        vDSP_vsmul(b, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(y, 1, temp1, 1, &y, 1, vDSP_Length(count))

        // Cb = -0.168736R - 0.331264G + 0.5B + 128
        scale = -0.168736
        vDSP_vsmul(r, 1, &scale, &cb, 1, vDSP_Length(count))
        scale = -0.331264
        vDSP_vsmul(g, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(cb, 1, temp1, 1, &cb, 1, vDSP_Length(count))
        scale = 0.5
        vDSP_vsmul(b, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(cb, 1, temp1, 1, &cb, 1, vDSP_Length(count))
        scale = 128.0
        vDSP_vsadd(cb, 1, &scale, &cb, 1, vDSP_Length(count))

        // Cr = 0.5R - 0.418688G - 0.081312B + 128
        scale = 0.5
        vDSP_vsmul(r, 1, &scale, &cr, 1, vDSP_Length(count))
        scale = -0.418688
        vDSP_vsmul(g, 1, &scale, &temp1, 1, vDSP_Length(count))
        vDSP_vadd(cr, 1, temp1, 1, &cr, 1, vDSP_Length(count))
        scale = -0.081312
        vDSP_vsmul(b, 1, &scale, &temp2, 1, vDSP_Length(count))
        vDSP_vadd(cr, 1, temp2, 1, &cr, 1, vDSP_Length(count))
        scale = 128.0
        vDSP_vsadd(cr, 1, &scale, &cr, 1, vDSP_Length(count))

        return (y, cb, cr)
    }

    // MARK: - Block Operations

    /// Level-shifts an 8×8 block by subtracting 128 using Accelerate.
    static func levelShift(_ block: inout [Float]) {
        var offset: Float = -128.0
        vDSP_vsadd(block, 1, &offset, &block, 1, 64)
    }

    /// Inverse level-shifts an 8×8 block by adding 128 and clamping to 0–255.
    static func inverseLevelShift(_ block: inout [Float]) {
        var offset: Float = 128.0
        vDSP_vsadd(block, 1, &offset, &block, 1, 64)
        var low: Float = 0.0
        var high: Float = 255.0
        vDSP_vclip(block, 1, &low, &high, &block, 1, 64)
    }
}
