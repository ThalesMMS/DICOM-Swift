// Gaborish — VarDCT post-DCT smoothing filter.
//
// One pass of a 3×3 separable-style convolution applied to each
// reconstructed channel after IDCT. Reduces DCT-block ringing
// artefacts; the encoder side applies a *separately-calibrated*
// 5×5 inverse-Gaborish sharpening kernel BEFORE the forward DCT
// (`GaborishInverse5x5` below) so that the encoder-decoder pair,
// while not mathematically inverse, produces visually pleasing
// rate-distortion behaviour (the libjxl 5×5 kernel constants were
// butteraugli-optimised).
//
// Spec: ISO/IEC 18181-1 §K.4.1. libjxl: `lib/jxl/render_pipeline/
// stage_gaborish.cc`. Per-channel weights are carried in
// `LoopFilter.gab_*_weight{1,2}`; the spec defaults reproduce the
// 1.1× scaling of libjxl's hardcoded `0.104699568f` /
// `0.055680538f` for x/y/b weight1 / weight2 — we expose the
// constants here as `defaultWeight1` / `defaultWeight2`.
//
// Kernel (per-pixel):
//
//     out = w0·center
//         + w1·(top + bottom + left + right)
//         + w2·(tl + tr + bl + br)
//
// where (`w1`, `w2`) come from `(gab_*_weight1, gab_*_weight2)`
// and `w0` is set so the kernel sums to 1: `w0 + 4·(w1 + w2) = 1`.
//
// The inverse uses the same repeated-edge mirror convention as the decoder,
// including one- and two-sample dimensions.

import Foundation

package enum Gaborish {

    /// libjxl spec-default `gab_*_weight1` for all three planes.
    /// Decoder honours the LoopFilter-carried per-plane weights;
    /// we expose the default for callers that don't have a
    /// custom LoopFilter handy.
    package static let defaultWeight1: Float = 1.1 * 0.104699568   // ≈ 0.1151694247
    /// libjxl spec-default `gab_*_weight2` for all three planes.
    package static let defaultWeight2: Float = 1.1 * 0.055680538   // ≈ 0.0612486

    /// Apply Gaborish to a single channel's pixel buffer in-place.
    /// `pixels` is row-major float32 length `width*height`. Border
    /// pixels mirror the nearest in-image neighbour (libjxl's
    /// `kInOut` mode does the same with replicate-1 padding).
    /// `stage_gaborish.cc`: normalised 3×3 weights, rows mirrored at the
    /// frame edge, `fma(sum2, w2, fma(sum1, w1, m·w0))` with
    /// `sum1 = (l + r) + (t + b)` and `sum2 = (tl + tr) + (bl + br)`.
    package static func apply(
        to pixels: inout [Float],
        width: Int, height: Int,
        weight1: Float = defaultWeight1,
        weight2: Float = defaultWeight2
    ) {
        precondition(pixels.count == width * height,
                     "buffer must equal width*height")
        precondition(width > 0 && height > 0)
        let div = 1 + 4 * (weight1 + weight2)
        let mul = 1.0 / div
        let w0 = 1.0 * mul
        let w1 = weight1 * mul
        let w2 = weight2 * mul
        var out = pixels
        pixels.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                let source = input.baseAddress!, destination = output.baseAddress!
                for y in 0..<height {
                    let row = y * width
                    let top = libjxlMirror(y - 1, height) * width
                    let bottom = libjxlMirror(y + 1, height) * width
                    @inline(__always) func write(_ x: Int, _ left: Int, _ right: Int) {
                        let sum1 = (source[row + left] + source[row + right]) + (source[top + x] + source[bottom + x])
                        let sum2 = (source[top + left] + source[top + right]) + (source[bottom + left] + source[bottom + right])
                        destination[row + x] = (source[row + x] * w0).addingProduct(sum1, w1).addingProduct(sum2, w2)
                    }
                    write(0, 0, min(1, width - 1))
                    @inline(__always) func load(_ i: Int) -> SIMD4<Float> {
                        UnsafeRawPointer(source + i).loadUnaligned(as: SIMD4<Float>.self)
                    }
                    var x = 1
                    while x + 4 < width {
                        let sum1 = (load(row + x - 1) + load(row + x + 1)) + (load(top + x) + load(bottom + x))
                        let sum2 = (load(top + x - 1) + load(top + x + 1)) + (load(bottom + x - 1) + load(bottom + x + 1))
                        let result = (load(row + x) * w0)
                            .addingProduct(sum1, SIMD4(repeating: w1)).addingProduct(sum2, SIMD4(repeating: w2))
                        UnsafeMutableRawPointer(destination + row + x).storeBytes(of: result, as: SIMD4<Float>.self)
                        x += 4
                    }
                    while x < width - 1 { write(x, x - 1, x + 1); x += 1 }
                    if width > 1 { write(width - 1, width - 2, width - 1) }
                }
            }
        }
        pixels = out
    }

    package static let kGaborishInverse5x5: [Float] = [
        -0.09495815671340026,    // axis-1   (r)
        -0.041031725066768575,   // diagonal (d)
         0.013710004822696948,   // axis-2   (R)
         0.006510206083837737,   // knight   (L)
        -0.0014789063378272242,  // corner   (D)
    ]

    /// Apply the 5×5 inverse-Gaborish kernel to a single channel's
    /// pixel buffer in-place. `mul` defaults to 1.0 (the libjxl
    /// encoder's standard call). Border pixels mirror the nearest
    /// in-image neighbour (libjxl `Symmetric5` boundary mode).
    package static func applyInverse5x5(
        to pixels: inout [Float],
        width: Int, height: Int,
        mul: Float = 1.0
    ) {
        precondition(pixels.count == width * height,
                     "buffer must equal width*height")
        precondition(width >= 1 && height >= 1)
        let g = kGaborishInverse5x5
        let sum = 1.0 + mul * 4.0 *
            (g[0] + g[1] + g[2] + g[4] + 2 * g[3])
        let normalize = 1.0 / sum
        let nm = mul * normalize
        let wCenter = normalize
        let wAxis1  = nm * g[0]
        let wDiag1  = nm * g[1]
        let wAxis2  = nm * g[2]
        let wKnight = nm * g[3]
        let wCorner = nm * g[4]

        var out = pixels
        for y in 0..<height {
            for x in 0..<width {
                @inline(__always) func px(_ dy: Int, _ dx: Int) -> Float {
                    let ny = libjxlMirror(y + dy, height)
                    let nx = libjxlMirror(x + dx, width)
                    return pixels[ny * width + nx]
                }
                var v: Float = wCenter * px(0, 0)
                v += wAxis1 *
                    (px(-1, 0) + px(1, 0) + px(0, -1) + px(0, 1))
                v += wDiag1 *
                    (px(-1, -1) + px(-1, 1) + px(1, -1) + px(1, 1))
                v += wAxis2 *
                    (px(-2, 0) + px(2, 0) + px(0, -2) + px(0, 2))
                v += wKnight * (
                    px(-2, -1) + px(-2, 1) + px(2, -1) + px(2, 1) +
                    px(-1, -2) + px(-1, 2) + px(1, -2) + px(1, 2)
                )
                v += wCorner *
                    (px(-2, -2) + px(-2, 2) + px(2, -2) + px(2, 2))
                out[y * width + x] = v
            }
        }
        pixels = out
    }
}
