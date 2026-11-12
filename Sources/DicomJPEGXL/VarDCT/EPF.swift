//
//  EPF.swift
//  DicomJPEGXL
//
//  EPF — VarDCT edge-preserving filter (loop filter, post-Gaborish).
//
//  Raster-Lab — May 2026
//

// EPF — VarDCT edge-preserving filter (loop filter, post-Gaborish).
//
// ISO/IEC 18181-1 §C.9.2. libjxl: `lib/jxl/render_pipeline/stage_epf.cc` +
// `lib/jxl/epf.cc::ComputeSigma`. Up to **three iterations** (`epf_iters`
// ∈ {0, 1, 2, 3}, default 2) of a Sum-of-Absolute-Differences (SAD)
// based bilateral filter with per-pixel weights derived from a per-block
// sigma image:
//
//     EPF0 — 7×7 (plus-with-diagonals: 12 neighbours, each 3×3-plus SAD)
//     EPF1 — 5×5 (plus-only: 4 neighbours, each 3×3-plus SAD)
//     EPF2 — 3×3 (plus-only: 4 neighbours, single-pixel diff)
//
// The weight per neighbour is `max(0, sad · inv_sigma + 1)` where
// `inv_sigma` is **negative** (so larger SAD → smaller weight, with a
// floor of zero). The center pixel always contributes weight 1.
//
// **Sigma computation** (per 8×8 block):
//     sigma_quant = epf_quant_mul / (quant_scale · row_quant · kInvSigmaNum)
//     sigma       = sigma_quant · epf_sharp_lut[sharpness]   // sharpness ∈ 0..7
//     sigma       = min(-1e-4, sigma)                        // clamp to negative
//     stored      = 1 / sigma                                // inv_sigma
//
// **kMinSigma early-exit**: if `inv_sigma < kMinSigma`, the block's
// pixels pass through unchanged. For typical cjxl-emitted fixtures
// with `epf_sharp_lut[0] = 0` (default LUT) and `sharpness = 0`,
// the LUT lookup is 0 → sigma is clamped to -1e-4 → inv_sigma is
// -10000 → which is far below `kMinSigma = -3.905`, so EPF is a
// **no-op for sharp content**. Real-world fixtures with non-zero
// sharpness exercise the full bilateral kernel.
//
// EPF0/1/2 use the reference arithmetic operation for operation (pair order, fused multiply-adds, the
// double-precision sigma scales) over mirror-padded planes, four pixels per SIMD group, so filtered
// samples equal libjxl's (#3254).

import Foundation

package enum EPFError: Error, Sendable, Equatable {
    /// Legacy error case retained for source compatibility; current kernels handle non-zero sharpness.
    case unsupportedNonZeroSharpness(blockX: Int, blockY: Int, invSigma: Float)
}

/// Per-block parameters needed by `EPF.compute*`.
package struct EPFParams: Sendable {
    /// Number of iterations to apply (0..3). 0 = skip EPF entirely.
    package let epfIters: Int
    /// libjxl `epf_quant_mul` (default 0.46).
    package let quantMul: Float
    /// libjxl `epf_sharp_lut[0..7]` — default `[i/7 for i in 0..7]`.
    package let sharpLut: [Float]
    /// Per-channel SAD scales — default `[X=40, Y=5, B=3.5]`.
    package let channelScale: (Float, Float, Float)
    /// Pass-1 / pass-2 weight floors.
    package let pass1ZeroFlush: Float
    package let pass2ZeroFlush: Float
    /// libjxl `epf_pass0_sigma_scale` (default 0.9).
    package let pass0SigmaScale: Float
    /// libjxl `epf_pass2_sigma_scale` (default 6.5).
    package let pass2SigmaScale: Float
    /// libjxl `epf_border_sad_mul` (default 0.667).
    package let borderSadMul: Float

    package static let `default` = EPFParams(
        epfIters: 2,
        quantMul: 0.46,
        sharpLut: (0..<8).map { Float($0) / 7.0 },
        channelScale: (40.0, 5.0, 3.5),
        pass1ZeroFlush: 0.45,
        pass2ZeroFlush: 0.6,
        pass0SigmaScale: 0.9,
        pass2SigmaScale: 6.5,
        borderSadMul: 2.0 / 3.0
    )
}

extension EPFParams {
    /// The frame's coded EPF parameters (`LoopFilter`).
    package init(loopFilter lf: LoopFilter) {
        self.init(
            epfIters: Int(lf.epfIters),
            quantMul: lf.epfQuantMul,
            sharpLut: lf.epfSharpLut,
            channelScale: (lf.epfChannelScale[0], lf.epfChannelScale[1], lf.epfChannelScale[2]),
            pass1ZeroFlush: lf.epfPass1ZeroFlush,
            pass2ZeroFlush: lf.epfPass2ZeroFlush,
            pass0SigmaScale: lf.epfPass0SigmaScale,
            pass2SigmaScale: lf.epfPass2SigmaScale,
            borderSadMul: lf.epfBorderSadMul
        )
    }
}

package enum EPF {

    /// libjxl `epf.h::kInvSigmaNum`. Used in the per-block sigma
    /// formula to derive `sigma_quant` from `quant_scale × row_quant`.
    package static let kInvSigmaNum: Float = -1.1715728752538099024

    /// libjxl `epf.h::kMinSigma`. Per-block sigma values strictly
    /// below this floor cause the EPF stage to early-exit (pixel
    /// pass-through). The `<` in the comparison means values *more
    /// negative* than this floor get the pass-through; values
    /// closer to zero (or positive) trigger the bilateral kernel.
    package static let kMinSigma: Float = -3.90524291751269967465540850526868

    /// Compute per-block `inv_sigma` from the EPF sharpness and
    /// quantiser state. Returns the value libjxl stores in its
    /// `sigma_` image (which is actually `1/sigma`, i.e., inverse).
    /// The caller samples this value when filtering each pixel.
    package static func computeInvSigma(
        sharpness: UInt8,
        rowQuant: Int32,
        quantScale: Float,
        params: EPFParams
    ) -> Float {
        // libjxl `epf.cc::ComputeSigma`:
        //
        //     sigma_quant = epf_quant_mul / (quant_scale * row_quant * kInvSigmaNum)
        //     sigma       = sigma_quant * epf_sharp_lut[sharpness]
        //     sigma       = min(-1e-4, sigma)         // always negative
        //     stored      = 1 / sigma                 // inv_sigma
        let sigmaQuant = params.quantMul
            / (quantScale * Float(rowQuant) * kInvSigmaNum)
        let lutIdx = min(Int(sharpness), params.sharpLut.count - 1)
        var sigma = sigmaQuant * params.sharpLut[lutIdx]
        sigma = min(-1e-4, sigma)
        return 1.0 / sigma
    }

    /// Decide whether EPF would be a no-op for a per-block
    /// `inv_sigma`. libjxl: `if (row_sigma[bx] < kMinSigma) → pass
    /// through`. For our fixture with default LUT and sharpness=0,
    /// the LUT lookup is 0, sigma clamps to -1e-4, inv_sigma is
    /// -10000 — far below kMinSigma — so this returns `true` and
    /// no filtering is applied.
    @inline(__always)
    package static func isNoOp(invSigma: Float) -> Bool {
        return invSigma < kMinSigma
    }

    /// Apply all enabled EPF stages to three XYB plane buffers in
    /// place, gated by `params.epfIters`:
    ///
    ///     epf_iters >= 1 → EPF1 (5×5 plus, 4 neighbours)
    ///     epf_iters >= 2 → EPF2 (3×3 plus, 4 neighbours)
    ///     epf_iters >= 3 → EPF0 (7×7 plus-with-diagonals, 12 neighbours)
    ///
    /// Per libjxl `dec_cache.cc::PreparePipeline`. Each stage is its own
    /// pass over the planes; intermediate results are written to scratch
    /// buffers and ping-pong'd. Per-block `inv_sigma` is recomputed
    /// from `sharpnessField`, `perBlockQF`, and `quantScale`.
    package static func applyAllStages(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        sharpnessField: [UInt8],
        perBlockQF: [Int32],
        quantScale: Float,
        params: EPFParams
    ) throws {
        guard params.epfIters > 0 else { return }
        precondition(planeX.count == width * height
                     && planeY.count == width * height
                     && planeB.count == width * height,
                     "plane buffers must be exactly width*height")

        let blocksX = (width + 7) / 8
        let blocksY = (height + 7) / 8
        precondition(sharpnessField.count >= blocksX * blocksY,
                     "sharpness field must cover the block grid")
        precondition(perBlockQF.count >= blocksX * blocksY,
                     "perBlockQF must cover the block grid")

        // Build the per-block inv_sigma table.
        var invSigmaPerBlock = [Float](repeating: 0,
                                        count: blocksX * blocksY)
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let bi = by * blocksX + bx
                invSigmaPerBlock[bi] = computeInvSigma(
                    sharpness: sharpnessField[bi],
                    rowQuant: perBlockQF[bi],
                    quantScale: quantScale,
                    params: params
                )
            }
        }

        try applyAllStages(planeX: &planeX, planeY: &planeY, planeB: &planeB,
                           width: width, height: height,
                           invSigmaPerBlock: invSigmaPerBlock, params: params)
    }

    /// The EPF stages over a ready per-block `inv_sigma` table (one entry per 8×8 block, row-major). Modular frames
    /// use a constant table, `kInvSigmaNum / epf_sigma_for_modular` (libjxl `dec_frame.cc::ProcessDCGroup`).
    package static func applyAllStages(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        invSigmaPerBlock: [Float],
        params: EPFParams
    ) throws {
        guard params.epfIters > 0 else { return }
        let blocksX = (width + 7) / 8
        let blocksY = (height + 7) / 8
        precondition(planeX.count == width * height
                     && planeY.count == width * height
                     && planeB.count == width * height,
                     "plane buffers must be exactly width*height")
        precondition(invSigmaPerBlock.count >= blocksX * blocksY,
                     "inv_sigma table must cover the block grid")
        // Stage application order per libjxl `dec_cache.cc` — the
        // render pipeline adds stages 0, 1, 2 in that order, so EPF0
        // (iters ≥ 3) runs FIRST, then EPF1 (iters ≥ 1), then EPF2
        // (iters ≥ 2).
        if params.epfIters >= 3 {
            applyEPF0(planeX: &planeX, planeY: &planeY, planeB: &planeB,
                      width: width, height: height,
                      blocksX: blocksX, invSigmaPerBlock: invSigmaPerBlock,
                      params: params)
        }
        if params.epfIters >= 1 {
            applyEPF1(planeX: &planeX, planeY: &planeY, planeB: &planeB,
                      width: width, height: height,
                      blocksX: blocksX, invSigmaPerBlock: invSigmaPerBlock,
                      params: params)
        }
        if params.epfIters >= 2 {
            applyEPF2(planeX: &planeX, planeY: &planeY, planeB: &planeB,
                      width: width, height: height,
                      blocksX: blocksX, invSigmaPerBlock: invSigmaPerBlock,
                      params: params)
        }
    }

    // MARK: - Stages (libjxl `render_pipeline/stage_epf.cc`, operation for operation)
    //
    // Each stage reads mirror-padded copies of the three planes and filters four adjacent pixels per SIMD
    // group (lanes never cross an 8×8 block, so one sigma serves the group). The arithmetic is the
    // reference's, in its order: SADs summed in the reference's pair order, channel SADs folded with
    // fused multiply-adds, `ZeroIfNegative(fma(sad, inv_sigma, 1))` weights, fused accumulation, and
    // `1 / w` then a multiply (`JXL_HIGH_PRECISION`). The pass-0 and pass-2 sigma scales multiply the
    // double literal 1.65 as the reference does. Issue #3254: Modular frames filtered with these
    // stages decode exactly as djxl.

    /// `sad_mul_center` / `sad_mul_border` of the stages.
    private static func sadMulTables(sm: Float, borderSadMul: Float) -> (center: [Float], border: [Float]) {
        let bsm = sm * borderSadMul
        return ([bsm, sm, sm, sm, sm, sm, sm, bsm], [Float](repeating: bsm, count: 8))
    }

    /// A plane mirrored by `pad` samples on every side (`libjxlMirror`, the render pipeline's symmetric
    /// border), with four spare zero columns so that a SIMD group at the right edge stays in bounds.
    private static func padded(_ plane: [Float], width: Int, height: Int, pad: Int) -> (data: [Float], stride: Int) {
        let stride = width + 2 * pad + 4
        var data = [Float](repeating: 0, count: stride * (height + 2 * pad))
        let columns = (0..<(width + 2 * pad)).map { libjxlMirror($0 - pad, width) }
        plane.withUnsafeBufferPointer { source in
            data.withUnsafeMutableBufferPointer { out in
                for row in 0..<(height + 2 * pad) {
                    let sourceRow = libjxlMirror(row - pad, height) * width
                    let outRow = row * stride
                    for (column, sourceColumn) in columns.enumerated() {
                        out[outRow + column] = source[sourceRow + sourceColumn]
                    }
                }
            }
        }
        return (data, stride)
    }

    @inline(__always)
    private static func absDiff(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        let d = a - b
        return d.replacing(with: -d, where: d .< SIMD4<Float>.zero)
    }

    /// `Weight`: `ZeroIfNegative(MulAdd(sad, inv_sigma, 1))`.
    @inline(__always)
    private static func weight(_ sad: SIMD4<Float>, _ invSigma: SIMD4<Float>) -> SIMD4<Float> {
        let v = SIMD4<Float>(repeating: 1).addingProduct(sad, invSigma)
        return v.replacing(with: SIMD4<Float>.zero, where: v .< SIMD4<Float>.zero)
    }

    /// Runs `kernel` over every four-pixel group with the group's `inv_sigma` lanes, writing the three
    /// outputs; groups in blocks below `kMinSigma` pass through. `kernel` receives a loader
    /// `(channel, dy, dx) -> lanes` relative to the group.
    private static func runStage(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int, blocksX: Int, invSigmaPerBlock: [Float],
        pad: Int, sm: Float, borderSadMul: Float,
        kernel: (_ load: (Int, Int, Int) -> SIMD4<Float>, _ invSigma: SIMD4<Float>)
            -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    ) {
        let (px, rowStride) = padded(planeX, width: width, height: height, pad: pad)
        let py = padded(planeY, width: width, height: height, pad: pad).data
        let pb = padded(planeB, width: width, height: height, pad: pad).data
        let tables = sadMulTables(sm: sm, borderSadMul: borderSadMul)
        var outX = planeX, outY = planeY, outB = planeB
        px.withUnsafeBufferPointer { bx in
            py.withUnsafeBufferPointer { by in
                pb.withUnsafeBufferPointer { bb in
                    outX.withUnsafeMutableBufferPointer { ox in
                        outY.withUnsafeMutableBufferPointer { oy in
                            outB.withUnsafeMutableBufferPointer { ob in
                                let planes = [bx.baseAddress!, by.baseAddress!, bb.baseAddress!]
                                for y in 0..<height {
                                    let table = (y % 8 == 0 || y % 8 == 7) ? tables.border : tables.center
                                    let sigmaRow = (y / 8) * blocksX
                                    for x in stride(from: 0, to: width, by: 4) {
                                        let base = invSigmaPerBlock[sigmaRow + x / 8]
                                        let lanes = min(4, width - x)
                                        if base < kMinSigma { continue }  // outputs already hold the input
                                        let ix = x % 8
                                        let invSigma = SIMD4<Float>(repeating: base)
                                            * SIMD4<Float>(table[ix], table[ix + 1], table[ix + 2], table[ix + 3])
                                        let origin = (y + pad) * rowStride + x + pad
                                        let (rx, ry, rb) = kernel({ channel, dy, dx in
                                            UnsafeRawPointer(planes[channel] + origin + dy * rowStride + dx)
                                                .loadUnaligned(as: SIMD4<Float>.self)
                                        }, invSigma)
                                        let i = y * width + x
                                        for lane in 0..<lanes {
                                            ox[i + lane] = rx[lane]
                                            oy[i + lane] = ry[lane]
                                            ob[i + lane] = rb[lane]
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        planeX = outX
        planeY = outY
        planeB = outB
    }

    /// The common tail of every stage: centre weight 1, then `AddPixel` per neighbour, then `X · (1 / w)`.
    private struct Accumulator {
        var w = SIMD4<Float>(repeating: 1)
        var x: SIMD4<Float>, y: SIMD4<Float>, b: SIMD4<Float>

        init(_ x: SIMD4<Float>, _ y: SIMD4<Float>, _ b: SIMD4<Float>) {
            self.x = x; self.y = y; self.b = b
        }

        @inline(__always)
        mutating func add(_ weight: SIMD4<Float>, _ cx: SIMD4<Float>, _ cy: SIMD4<Float>, _ cb: SIMD4<Float>) {
            w += weight
            x = x.addingProduct(weight, cx)
            y = y.addingProduct(weight, cy)
            b = b.addingProduct(weight, cb)
        }

        var result: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
            let inverse = SIMD4<Float>(repeating: 1) / w
            return (x * inverse, y * inverse, b * inverse)
        }
    }

    /// `EPF1Stage`: 4 neighbours, each weighted by a 3×3-plus SAD.
    static func applyEPF1(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        blocksX: Int, invSigmaPerBlock: [Float],
        params: EPFParams
    ) {
        let scales = [params.channelScale.0, params.channelScale.1, params.channelScale.2]
        runStage(planeX: &planeX, planeY: &planeY, planeB: &planeB, width: width, height: height,
                 blocksX: blocksX, invSigmaPerBlock: invSigmaPerBlock, pad: 2,
                 sm: 1.65, borderSadMul: params.borderSadMul) { load, invSigma in
            var sad0 = SIMD4<Float>.zero, sad1 = SIMD4<Float>.zero
            var sad2 = SIMD4<Float>.zero, sad3 = SIMD4<Float>.zero
            for c in 0..<3 {
                // p<dx+2><dy+2>, the reference's names.
                let p20 = load(c, -2, 0), p21 = load(c, -1, 0)
                var sad0c = absDiff(p20, p21)
                let p11 = load(c, -1, -1)
                var sad1c = absDiff(p11, p21)
                let p31 = load(c, -1, 1)
                var sad2c = absDiff(p31, p21)
                let p02 = load(c, 0, -2), p12 = load(c, 0, -1)
                sad1c += absDiff(p02, p12)
                sad0c += absDiff(p11, p12)
                let p22 = load(c, 0, 0)
                var t = absDiff(p12, p22)
                sad1c += t
                sad2c += t
                t = absDiff(p22, p21)
                var sad3c = t
                sad0c += t
                let p32 = load(c, 0, 1)
                sad0c += absDiff(p31, p32)
                t = absDiff(p22, p32)
                sad1c += t
                sad2c += t
                let p42 = load(c, 0, 2)
                sad2c += absDiff(p42, p32)
                let p13 = load(c, 1, -1)
                sad3c += absDiff(p13, p12)
                let p23 = load(c, 1, 0)
                t = absDiff(p22, p23)
                sad0c += t
                sad3c += t
                sad1c += absDiff(p13, p23)
                let p33 = load(c, 1, 1)
                sad2c += absDiff(p33, p23)
                sad3c += absDiff(p33, p32)
                let p24 = load(c, 2, 0)
                sad3c += absDiff(p24, p23)
                let scale = SIMD4<Float>(repeating: scales[c])
                sad0 = sad0.addingProduct(sad0c, scale)
                sad1 = sad1.addingProduct(sad1c, scale)
                sad2 = sad2.addingProduct(sad2c, scale)
                sad3 = sad3.addingProduct(sad3c, scale)
            }
            var acc = Accumulator(load(0, 0, 0), load(1, 0, 0), load(2, 0, 0))
            acc.add(weight(sad0, invSigma), load(0, -1, 0), load(1, -1, 0), load(2, -1, 0))
            acc.add(weight(sad1, invSigma), load(0, 0, -1), load(1, 0, -1), load(2, 0, -1))
            acc.add(weight(sad2, invSigma), load(0, 0, 1), load(1, 0, 1), load(2, 0, 1))
            acc.add(weight(sad3, invSigma), load(0, 1, 0), load(1, 1, 0), load(2, 1, 0))
            return acc.result
        }
    }

    /// `EPF2Stage`: 4 neighbours, each weighted by its own single-pixel difference.
    static func applyEPF2(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        blocksX: Int, invSigmaPerBlock: [Float],
        params: EPFParams
    ) {
        let s0 = SIMD4<Float>(repeating: params.channelScale.0)
        let s1 = SIMD4<Float>(repeating: params.channelScale.1)
        let s2 = SIMD4<Float>(repeating: params.channelScale.2)
        runStage(planeX: &planeX, planeY: &planeY, planeB: &planeB, width: width, height: height,
                 blocksX: blocksX, invSigmaPerBlock: invSigmaPerBlock, pad: 1,
                 sm: Float(Double(params.pass2SigmaScale) * 1.65), borderSadMul: params.borderSadMul) { load, invSigma in
            let rx = load(0, 0, 0), ry = load(1, 0, 0), rb = load(2, 0, 0)
            var acc = Accumulator(rx, ry, rb)
            for (dy, dx) in plusNeighbours {
                let cx = load(0, dy, dx), cy = load(1, dy, dx), cb = load(2, dy, dx)
                var sad = absDiff(cx, rx) * s0
                sad = sad.addingProduct(absDiff(cy, ry), s1)
                sad = sad.addingProduct(absDiff(cb, rb), s2)
                acc.add(weight(sad, invSigma), cx, cy, cb)
            }
            return acc.result
        }
    }

    /// The four `AddPixel` neighbours of `EPF2Stage` as (dy, dx), in the reference's order.
    private static let plusNeighbours: [(Int, Int)] = [(-1, 0), (0, -1), (0, 1), (1, 0)]
    /// `sads_off` of `EPF0Stage` as (dy, dx).
    private static let epf0Neighbours: [(Int, Int)] = [
        (-2, 0), (-1, -1), (-1, 0), (-1, 1), (0, -2), (0, -1),
        (0, 1), (0, 2), (1, -1), (1, 0), (1, 1), (2, 0)
    ]
    /// `plus_off` of `EPF0Stage` as (dy, dx).
    private static let epf0Plus: [(Int, Int)] = [(0, 0), (-1, 0), (0, -1), (1, 0), (0, 1)]

    /// `EPF0Stage`: 12 neighbours of a 5×5 plus, each weighted by a 3×3-plus SAD.
    static func applyEPF0(
        planeX: inout [Float], planeY: inout [Float], planeB: inout [Float],
        width: Int, height: Int,
        blocksX: Int, invSigmaPerBlock: [Float],
        params: EPFParams
    ) {
        let scales = [params.channelScale.0, params.channelScale.1, params.channelScale.2]
        runStage(planeX: &planeX, planeY: &planeY, planeB: &planeB, width: width, height: height,
                 blocksX: blocksX, invSigmaPerBlock: invSigmaPerBlock, pad: 3,
                 sm: Float(Double(params.pass0SigmaScale) * 1.65), borderSadMul: params.borderSadMul) { load, invSigma in
            withUnsafeTemporaryAllocation(of: SIMD4<Float>.self, capacity: 12) { sads in
                sads.initialize(repeating: SIMD4<Float>.zero)
                for c in 0..<3 {
                    let scale = SIMD4<Float>(repeating: scales[c])
                    for (i, (ny, nx)) in epf0Neighbours.enumerated() {
                        var sad = SIMD4<Float>.zero
                        for (oy, ox) in epf0Plus {
                            sad += absDiff(load(c, oy, ox), load(c, ny + oy, nx + ox))
                        }
                        sads[i] = sads[i].addingProduct(sad, scale)
                    }
                }
                var acc = Accumulator(load(0, 0, 0), load(1, 0, 0), load(2, 0, 0))
                for (i, (dy, dx)) in epf0Neighbours.enumerated() {
                    acc.add(weight(sads[i], invSigma), load(0, dy, dx), load(1, dy, dx), load(2, dy, dx))
                }
                return acc.result
            }
        }
    }
}
