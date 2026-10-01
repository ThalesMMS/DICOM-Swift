// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.
// Isis modifications are recorded in Git.

import Foundation

/// Chroma subsampling and upsampling operations.
///
/// Handles chroma plane downsampling (encoder) and upsampling (decoder)
/// for the supported subsampling modes: 4:4:4, 4:2:2, 4:2:0, and 4:0:0.
enum ChromaSampling {

    /// Raw pointers for the parallel upsample. Each row is written independently,
    /// so sharing these across `concurrentPerform` workers is safe (the buffers
    /// stay alive for the synchronous duration of the call).
    private struct UpsamplePtrs: @unchecked Sendable {
        let src: UnsafePointer<Float>
        let dst: UnsafeMutablePointer<Float>
        let sx0: UnsafePointer<Int>
        let sx1: UnsafePointer<Int>
        let fx: UnsafePointer<Float>
    }

    /// Downsamples a component plane by a factor of 2 in each specified dimension.
    ///
    /// Uses simple box filtering (averaging) for downsampling.
    ///
    /// - Parameters:
    ///   - plane: Source plane data.
    ///   - width: Source plane width.
    ///   - height: Source plane height.
    ///   - horizontally: Whether to downsample horizontally (halve width).
    ///   - vertically: Whether to downsample vertically (halve height).
    /// - Returns: Downsampled plane data and new dimensions.
    static func downsample(_ plane: [Float], width: Int, height: Int,
                           horizontally: Bool, vertically: Bool) -> (data: [Float], width: Int, height: Int) {
        guard horizontally || vertically else {
            return (plane, width, height)
        }

        let newWidth = horizontally ? (width + 1) / 2 : width
        let newHeight = vertically ? (height + 1) / 2 : height
        var result = [Float](repeating: 0, count: newWidth * newHeight)

        // 2×2 fast path (the 4:2:0 default, ~8% of a color encode): interior
        // boxes are complete, so the per-pixel edge guards and the generic
        // sum/count bookkeeping vanish — the additions keep the exact serial
        // association of the generic loop (((a+b)+c)+d, top row first), and
        // /4, /2 are exact power-of-two scalings, so output is byte-identical.
        // Odd-edge boxes (1×2 / 2×1 / 1×1) are handled in matching order.
        if horizontally && vertically {
            plane.withUnsafeBufferPointer { sp in
                result.withUnsafeMutableBufferPointer { rp in
                    let src = sp.baseAddress!, dst = rp.baseAddress!
                    let fullW = width / 2, fullH = height / 2
                    for dy in 0..<fullH {
                        let rA = (dy * 2) * width, rB = rA + width
                        let dRow = dy * newWidth
                        for dx in 0..<fullW {
                            let sx = dx * 2
                            let sum = ((src[rA + sx] + src[rA + sx + 1])
                                       + src[rB + sx]) + src[rB + sx + 1]
                            dst[dRow + dx] = sum / 4
                        }
                        if newWidth > fullW {                         // odd width: 1×2 box
                            let sx = fullW * 2
                            dst[dRow + fullW] = (src[rA + sx] + src[rB + sx]) / 2
                        }
                    }
                    if newHeight > fullH {                            // odd height: 2×1 boxes
                        let rA = (fullH * 2) * width
                        let dRow = fullH * newWidth
                        for dx in 0..<fullW {
                            let sx = dx * 2
                            dst[dRow + dx] = (src[rA + sx] + src[rA + sx + 1]) / 2
                        }
                        if newWidth > fullW {                         // odd corner: 1×1
                            dst[dRow + fullW] = src[rA + fullW * 2]
                        }
                    }
                }
            }
            return (result, newWidth, newHeight)
        }

        let hStep = horizontally ? 2 : 1
        let vStep = vertically ? 2 : 1

        for dy in 0..<newHeight {
            for dx in 0..<newWidth {
                var sum: Float = 0
                var count: Float = 0
                for vy in 0..<vStep {
                    let sy = dy * vStep + vy
                    guard sy < height else { continue }
                    for vx in 0..<hStep {
                        let sx = dx * hStep + vx
                        guard sx < width else { continue }
                        sum += plane[sy * width + sx]
                        count += 1
                    }
                }
                result[dy * newWidth + dx] = sum / count
            }
        }

        return (result, newWidth, newHeight)
    }

    /// Upsamples a component plane by a factor of 2 in each specified dimension.
    ///
    /// Uses bilinear interpolation for smooth upsampling.
    ///
    /// - Parameters:
    ///   - plane: Source plane data.
    ///   - width: Source plane width.
    ///   - height: Source plane height.
    ///   - targetWidth: Target width after upsampling.
    ///   - targetHeight: Target height after upsampling.
    /// - Returns: Upsampled plane data.
    static func upsample(_ plane: [Float], width: Int, height: Int,
                          targetWidth: Int, targetHeight: Int) -> [Float] {
        guard targetWidth != width || targetHeight != height else {
            return plane
        }
        // Issue #2853: 2×1 and 2×2 chroma use the triangle ("fancy") filter of libjpeg, with chroma samples sited
        // between luma pairs, so decoded colour matches the reference decoders; other factors stay bilinear.
        let doublesWidth = (targetWidth + 1) / 2 == width
        if doublesWidth, targetHeight == height {
            return fancyUpsampled(plane, width: width, height: height, targetWidth: targetWidth,
                                  targetHeight: targetHeight, vertical: false)
        }
        if doublesWidth, (targetHeight + 1) / 2 == height {
            return fancyUpsampled(plane, width: width, height: height, targetWidth: targetWidth,
                                  targetHeight: targetHeight, vertical: true)
        }

        // The x-mapping (source columns + fractional weight) is identical for
        // every row, so precompute it once instead of per pixel. The inner loop
        // then uses raw pointers for the source/destination planes, avoiding the
        // per-element copy-on-write check that dominated the decode profile.
        // Same bilinear formula and operand order → byte-identical output.
        let xScale = Float(width - 1) / Float(max(1, targetWidth - 1))
        var sx0 = [Int](repeating: 0, count: targetWidth)
        var sx1 = [Int](repeating: 0, count: targetWidth)
        var fxs = [Float](repeating: 0, count: targetWidth)
        for tx in 0..<targetWidth {
            let srcX = Float(tx) * xScale
            let x0 = min(Int(srcX), width - 1)
            sx0[tx] = x0
            sx1[tx] = min(x0 + 1, width - 1)
            fxs[tx] = srcX - Float(x0)
        }
        let yScale = Float(height - 1) / Float(max(1, targetHeight - 1))

        var result = [Float](unsafeUninitializedCapacity: targetWidth * targetHeight) {
            _, c in c = targetWidth * targetHeight
        }
        // Hoist into Sendable scalars for the parallel closure.
        let th = targetHeight, tw = targetWidth, w = width, h = height, ys = yScale
        plane.withUnsafeBufferPointer { srcBuf in
            result.withUnsafeMutableBufferPointer { dstBuf in
                sx0.withUnsafeBufferPointer { x0b in
                    sx1.withUnsafeBufferPointer { x1b in
                        fxs.withUnsafeBufferPointer { fxb in
                            let ptrs = UpsamplePtrs(
                                src: srcBuf.baseAddress!, dst: dstBuf.baseAddress!,
                                sx0: x0b.baseAddress!, sx1: x1b.baseAddress!, fx: fxb.baseAddress!)
                            // Each output row is independent → bit-identical whether
                            // computed serially or split across cores.
                            let rows: @Sendable (Int, Int) -> Void = { rowStart, rowEnd in
                                let p = ptrs.src, d = ptrs.dst
                                let X0 = ptrs.sx0, X1 = ptrs.sx1, FX = ptrs.fx
                                for ty in rowStart..<rowEnd {
                                    let srcY = Float(ty) * ys
                                    let sy0 = min(Int(srcY), h - 1)
                                    let sy1 = min(sy0 + 1, h - 1)
                                    let fy = srcY - Float(sy0)
                                    let row0 = sy0 * w, row1 = sy1 * w
                                    let drow = ty * tw
                                    for tx in 0..<tw {
                                        let x0 = X0[tx], x1 = X1[tx], fx = FX[tx]
                                        let v00 = p[row0 + x0], v10 = p[row0 + x1]
                                        let v01 = p[row1 + x0], v11 = p[row1 + x1]
                                        d[drow + tx] = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) +
                                                       v01 * (1 - fx) * fy + v11 * fx * fy
                                    }
                                }
                            }
                            let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
                            if tw * th >= 65_536 && th >= 2 * cores {
                                let chunkRows = (th + cores - 1) / cores
                                let chunks = (th + chunkRows - 1) / chunkRows
                                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                                    let s = c * chunkRows
                                    rows(s, min(s + chunkRows, th))
                                }
                            } else {
                                rows(0, th)
                            }
                        }
                    }
                }
            }
        }
        return result
    }

    /// libjpeg's h2v1/h2v2 fancy upsampling in floating point: each output sample weighs its nearest source sample
    /// by 3/4 and the next one out by 1/4, per doubled axis, with edges replicated.
    private static func fancyUpsampled(_ plane: [Float], width: Int, height: Int, targetWidth: Int,
                                       targetHeight: Int, vertical: Bool) -> [Float] {
        var result = [Float](repeating: 0, count: targetWidth * targetHeight)
        var row = [Float](repeating: 0, count: width)
        for ty in 0 ..< targetHeight {
            if vertical {
                let sy = ty / 2
                let neighbour = ty.isMultiple(of: 2) ? max(sy - 1, 0) : min(sy + 1, height - 1)
                for x in 0 ..< width {
                    row[x] = 0.75 * plane[sy * width + x] + 0.25 * plane[neighbour * width + x]
                }
            } else {
                for x in 0 ..< width { row[x] = plane[ty * width + x] }
            }
            let base = ty * targetWidth
            for tx in 0 ..< targetWidth {
                let sx = tx / 2
                let neighbour = tx.isMultiple(of: 2) ? max(sx - 1, 0) : min(sx + 1, width - 1)
                result[base + tx] = 0.75 * row[sx] + 0.25 * row[neighbour]
            }
        }
        return result
    }

    /// Returns the horizontal and vertical sampling factors for a subsampling mode.
    static func samplingFactors(for mode: JLIChromaSubsampling) -> (h: Int, v: Int) {
        switch mode {
        case .yuv444: return (1, 1)
        case .yuv422: return (2, 1)
        case .yuv420: return (2, 2)
        case .yuv400: return (1, 1)  // Grayscale, no chroma
        }
    }
}
