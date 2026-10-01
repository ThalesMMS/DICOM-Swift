// RenderStages.swift — issue #2333
//
// Ports of the libjxl render-pipeline stages the VarDCT decoder needs
// beyond Gaborish/EPF: the frame-edge mirroring rule, the upsampling
// stage (`render_pipeline/stage_upsampling.cc`), noise synthesis
// (`dec_noise.cc`, `noise.h`, `stage_noise.cc`, `xorshift128plus-inl.h`)
// and the `CustomTransformData` header fields (`image_metadata.cc`).
// Reference semantics are libjxl 0.11/0.12; comments cite the source.

import Foundation

/// `image_ops.h::Mirror`: reflect an out-of-range coordinate into
/// `0..<size` without repeating the edge sample (−1 → 0, −2 → 1).
@inline(__always)
package func libjxlMirror(_ x: Int, _ size: Int) -> Int {
    var v = x
    while v < 0 || v >= size {
        if v < 0 { v = -v - 1 } else { v = 2 * size - 1 - v }
    }
    return v
}

/// `CustomTransformData`: the upsampling weights (default or custom).
package struct CustomTransformData: Sendable {
    package var upsampling2Weights: [Float]
    package var upsampling4Weights: [Float]
    package var upsampling8Weights: [Float]

    package init(
        upsampling2Weights: [Float] = CustomTransformData.kweights2,
        upsampling4Weights: [Float] = CustomTransformData.kweights4,
        upsampling8Weights: [Float] = CustomTransformData.kweights8
    ) {
        self.upsampling2Weights = upsampling2Weights
        self.upsampling4Weights = upsampling4Weights
        self.upsampling8Weights = upsampling8Weights
    }

    package static let `default` = CustomTransformData()

    /// Weights for `shift` (1, 2 or 3).
    package func weights(forShift shift: Int) -> [Float] {
        switch shift {
        case 1: return upsampling2Weights
        case 2: return upsampling4Weights
        default: return upsampling8Weights
        }
    }

    /// `CustomTransformData::VisitFields`: `all_default`, the nested
    /// `OpsinInverseMatrix` bundle for XYB images, then
    /// `custom_weights_mask` u(3) and the F16 weight lists it selects.
    package static func read(from r: inout BitReader, xybEncoded: Bool) throws -> CustomTransformData {
        if try r.readBit() { return .default }
        if xybEncoded {
            let opsinDefault = try r.readBit()
            guard opsinDefault else {
                throw BitstreamError.malformedValue("custom opsin inverse matrix not supported")
            }
        }
        let mask = try r.read(bits: 3)
        var data = CustomTransformData.default
        if mask & 1 != 0 {
            data.upsampling2Weights = try (0..<15).map { _ in halfToFloat(UInt16(try r.read(bits: 16))) }
        }
        if mask & 2 != 0 {
            data.upsampling4Weights = try (0..<55).map { _ in halfToFloat(UInt16(try r.read(bits: 16))) }
        }
        if mask & 4 != 0 {
            data.upsampling8Weights = try (0..<210).map { _ in halfToFloat(UInt16(try r.read(bits: 16))) }
        }
        return data
    }

    package static let kweights2: [Float] = [
        -0.01716200, -0.03452303, -0.04022174, -0.02921014, -0.00624645,
        0.14111091, 0.28896755, 0.00278718, -0.01610267, 0.56661550,
        0.03777607, -0.01986694, -0.03144731, -0.01185068, -0.00213539
    ]

    package static let kweights4: [Float] = [
        -0.02419067, -0.03491987, -0.03693351, -0.03094285, -0.00529785,
        -0.01663432, -0.03556863, -0.03888905, -0.03516850, -0.00989469,
        0.23651958, 0.33392945, -0.01073543, -0.01313181, -0.03556694,
        0.13048175, 0.40103025, 0.03951150, -0.02077584, 0.46914198,
        -0.00209270, -0.01484589, -0.04064806, 0.18942530, 0.56279892,
        0.06674400, -0.02335494, -0.03551682, -0.00754830, -0.02267919,
        -0.02363578, 0.00315804, -0.03399098, -0.01359519, -0.00091653,
        -0.00335467, -0.01163294, -0.01610294, -0.00974088, -0.00191622,
        -0.01095446, -0.03198464, -0.04455121, -0.02799790, -0.00645912,
        0.06390599, 0.22963888, 0.00630981, -0.01897349, 0.67537268,
        0.08483369, -0.02534994, -0.02205197, -0.01667999, -0.00384443
    ]

    package static let kweights8: [Float] = [
        -0.02928613, -0.03706353, -0.03783812, -0.03324558, -0.00447632,
        -0.02519406, -0.03752601, -0.03901508, -0.03663285, -0.00646649,
        -0.02066407, -0.03838633, -0.04002101, -0.03900035, -0.00901973,
        -0.01626393, -0.03954148, -0.04046620, -0.03979621, -0.01224485,
        0.29895328, 0.35757708, -0.02447552, -0.01081748, -0.04314594,
        0.23903219, 0.41119301, -0.00573046, -0.01450239, -0.04246845,
        0.17567618, 0.45220643, 0.02287757, -0.01936783, -0.03583255,
        0.11572472, 0.47416733, 0.06284440, -0.02685066, 0.42720050,
        -0.02248939, -0.01155273, -0.04562755, 0.28689496, 0.49093869,
        -0.00007891, -0.01545926, -0.04562659, 0.21238920, 0.53980934,
        0.03369474, -0.02070211, -0.03866988, 0.14229550, 0.56593398,
        0.08045181, -0.02888298, -0.03680918, -0.00542229, -0.02920477,
        -0.02788574, -0.02118180, -0.03942402, -0.00775547, -0.02433614,
        -0.03193943, -0.02030828, -0.04044014, -0.01074016, -0.01930822,
        -0.03620399, -0.01974125, -0.03919545, -0.01456093, -0.00045072,
        -0.00360110, -0.01020207, -0.01231907, -0.00638988, -0.00071592,
        -0.00279122, -0.00957115, -0.01288327, -0.00730937, -0.00107783,
        -0.00210156, -0.00890705, -0.01317668, -0.00813895, -0.00153491,
        -0.02128481, -0.04173044, -0.04831487, -0.03293190, -0.00525260,
        -0.01720322, -0.04052736, -0.05045706, -0.03607317, -0.00738030,
        -0.01341764, -0.03965629, -0.05151616, -0.03814886, -0.01005819,
        0.18968273, 0.33063684, -0.01300105, -0.01372950, -0.04017465,
        0.13727832, 0.36402234, 0.01027890, -0.01832107, -0.03365072,
        0.08734506, 0.38194295, 0.04338228, -0.02525993, 0.56408126,
        0.00458352, -0.01648227, -0.04887868, 0.24585519, 0.62026135,
        0.04314807, -0.02213737, -0.04158014, 0.16637289, 0.65027023,
        0.09621636, -0.03101388, -0.04082742, -0.00904519, -0.02790922,
        -0.02117818, 0.00798662, -0.03995711, -0.01243427, -0.02231705,
        -0.02946266, 0.00992055, -0.03600283, -0.01684920, -0.00111684,
        -0.00411204, -0.01297130, -0.01723725, -0.01022545, -0.00165306,
        -0.00313110, -0.01218016, -0.01763266, -0.01125620, -0.00231663,
        -0.01374149, -0.03797620, -0.05142937, -0.03117307, -0.00581914,
        -0.01064003, -0.03608089, -0.05272168, -0.03375670, -0.00795586,
        0.09628104, 0.27129991, -0.00353779, -0.01734151, -0.03153981,
        0.05686230, 0.28500998, 0.02230594, -0.02374955, 0.68214326,
        0.05018048, -0.02320852, -0.04383616, 0.18459474, 0.71517975,
        0.10805613, -0.03263677, -0.03637639, -0.01394373, -0.02511203,
        -0.01728636, 0.05407331, -0.02867568, -0.01893131, -0.00240854,
        -0.00446511, -0.01636187, -0.02377053, -0.01522848, -0.00333334,
        -0.00819975, -0.02964169, -0.04499287, -0.02745350, -0.00612408,
        0.02727416, 0.19446600, 0.00159832, -0.02232473, 0.74982506,
        0.11452620, -0.03348048, -0.01605681, -0.02070339, -0.00458223
    ]
}

/// `stage_upsampling.cc::UpsamplingStage`: a 5×5 kernel per output
/// phase built from the symmetric weight list; each output is clamped
/// to the min/max of the 5×5 input neighbourhood; input borders mirror.
package struct Upsampler {
    package let shift: Int
    private let n: Int
    /// `kernel[k * 25 + i]` for phase `k = oy * N + ox`.
    private let kernel: [Float]

    package init(weights: [Float], shift: Int) {
        precondition((1...3).contains(shift))
        self.shift = shift
        let n = 1 << shift
        self.n = n
        let h = n / 2
        var kernel = [Float](repeating: 0, count: n * n * 25)
        for ky in 0..<h {
            for kx in 0..<h {
                let offset0 = (ky * n + kx) * 25
                let offset1 = (ky * n + (n - 1 - kx)) * 25
                let offset2 = ((n - 1 - ky) * n + kx) * 25
                let offset3 = ((n - 1 - ky) * n + (n - 1 - kx)) * 25
                for py in 0..<5 {
                    for px in 0..<5 {
                        let j = 5 * ky + py
                        let i = 5 * kx + px
                        let my = min(i, j)
                        let mx = max(i, j)
                        let w = weights[5 * h * my - my * (my - 1) / 2 + mx - my]
                        kernel[offset0 + py * 5 + px] = w
                        kernel[offset1 + py * 5 + (4 - px)] = w
                        kernel[offset2 + (4 - py) * 5 + px] = w
                        kernel[offset3 + (4 - py) * 5 + (4 - px)] = w
                    }
                }
            }
        }
        self.kernel = kernel
    }

    /// Upsamples `plane` (`width × height`) to `(width·N) × (height·N)`.
    package func apply(_ plane: [Float], width: Int, height: Int) -> [Float] {
        precondition(plane.count == width * height)
        let outWidth = width * n
        var out = [Float](repeating: 0, count: outWidth * height * n)
        // Mirror-padded copy (border 2) so the inner loop is branch-free.
        let pw = width + 4
        var padded = [Float](repeating: 0, count: pw * (height + 4))
        for y in 0..<(height + 4) {
            let sy = libjxlMirror(y - 2, height)
            for x in 0..<(width + 4) {
                padded[y * pw + x] = plane[sy * width + libjxlMirror(x - 2, width)]
            }
        }
        var window = [Float](repeating: 0, count: 25)
        for y in 0..<height {
            for x in 0..<width {
                var lo = Float.greatestFiniteMagnitude
                var hi = -Float.greatestFiniteMagnitude
                for iy in 0..<5 {
                    let row = (y + iy) * pw + x
                    for ix in 0..<5 {
                        let v = padded[row + ix]
                        window[iy * 5 + ix] = v
                        lo = min(lo, v)
                        hi = max(hi, v)
                    }
                }
                for oy in 0..<n {
                    let dstRow = (y * n + oy) * outWidth + x * n
                    for ox in 0..<n {
                        let k = (n * oy + ox) * 25
                        // Accumulation order of `ProcessRowImpl` (three
                        // fused accumulators, then `(acc1 + acc2) + acc0`).
                        var acc0 = window[0] * kernel[k]
                        var acc1 = window[1] * kernel[k + 1]
                        var acc2 = window[2] * kernel[k + 2]
                        var i = 3
                        while i < 24 {
                            acc0 = acc0.addingProduct(window[i], kernel[k + i])
                            acc1 = acc1.addingProduct(window[i + 1], kernel[k + i + 1])
                            acc2 = acc2.addingProduct(window[i + 2], kernel[k + i + 2])
                            i += 3
                        }
                        acc0 = acc0.addingProduct(window[24], kernel[k + 24])
                        let result = (acc1 + acc2) + acc0
                        out[dstRow + ox] = min(max(result, lo), hi)
                    }
                }
            }
        }
        return out
    }
}

/// `noise.h::NoiseParams` + `dec_noise.cc::DecodeNoise`.
package struct NoiseParams: Sendable {
    package static let numPoints = 8
    package var lut: [Float]

    package init(lut: [Float] = [Float](repeating: 0, count: NoiseParams.numPoints)) {
        precondition(lut.count == NoiseParams.numPoints)
        self.lut = lut
    }

    /// Eight 10-bit values divided by `kNoisePrecision` (1024).
    package static func read(from r: inout BitReader) throws -> NoiseParams {
        var lut = [Float](repeating: 0, count: numPoints)
        for i in 0..<numPoints {
            lut[i] = Float(try r.read(bits: 10)) / 1024.0
        }
        return NoiseParams(lut: lut)
    }

    package var hasAny: Bool { lut.contains { abs($0) > 1e-3 } }
}

/// `xorshift128plus-inl.h`: eight interleaved xorshift128+ lanes seeded
/// through SplitMix64.
package struct Xorshift128Plus {
    package static let lanes = 8
    private var s0 = [UInt64](repeating: 0, count: 8)
    private var s1 = [UInt64](repeating: 0, count: 8)

    private static func splitMix64(_ input: UInt64) -> UInt64 {
        var z = input
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    package init(seed1: UInt32, seed2: UInt32, seed3: UInt32, seed4: UInt32) {
        s0[0] = Self.splitMix64(((UInt64(seed1) << 32) &+ UInt64(seed2)) &+ 0x9E3779B97F4A7C15)
        s1[0] = Self.splitMix64(((UInt64(seed3) << 32) &+ UInt64(seed4)) &+ 0x9E3779B97F4A7C15)
        for i in 1..<Self.lanes {
            s0[i] = Self.splitMix64(s0[i - 1])
            s1[i] = Self.splitMix64(s1[i - 1])
        }
    }

    /// `Fill`: eight 64-bit outputs, one per lane.
    package mutating func fill(_ bits: inout [UInt64]) {
        for i in 0..<Self.lanes {
            var a = s0[i]
            let b = s1[i]
            bits[i] = a &+ b
            s0[i] = b
            a ^= a << 23
            a ^= b ^ (a >> 18) ^ (b >> 5)
            s1[i] = a
        }
    }
}

/// `dec_noise.cc` (random planes) + `stage_noise.cc` (convolution and
/// the additive stage).
package enum NoiseSynthesis {
    /// `BitsToFloat`: `(bits >> 9) | 0x3F800000` → [1, 2).
    @inline(__always)
    private static func bitsToFloat(_ bits: UInt32) -> Float {
        Float(bitPattern: (bits >> 9) | 0x3F80_0000)
    }

    /// `RandomImage`: fills `rect` rows of `plane` (stride `stride`) with
    /// the RNG stream in libjxl's batch order (16 floats per `Fill`).
    private static func randomRect(
        rng: inout Xorshift128Plus, plane: inout [Float], stride: Int,
        x0: Int, y0: Int, xsize: Int, ysize: Int
    ) {
        var batch = [UInt64](repeating: 0, count: Xorshift128Plus.lanes)
        var floats = [Float](repeating: 0, count: 16)
        @inline(__always) func decodeBatch() {
            for i in 0..<8 {
                floats[2 * i] = bitsToFloat(UInt32(truncatingIfNeeded: batch[i]))
                floats[2 * i + 1] = bitsToFloat(UInt32(truncatingIfNeeded: batch[i] >> 32))
            }
        }
        for y in 0..<ysize {
            let row = (y0 + y) * stride + x0
            var x = 0
            while x + 16 < xsize {
                rng.fill(&batch)
                decodeBatch()
                for i in 0..<16 { plane[row + x + i] = floats[i] }
                x += 16
            }
            rng.fill(&batch)
            decodeBatch()
            var i = 0
            while x < xsize {
                plane[row + x] = floats[i]
                x += 1
                i += 1
            }
        }
    }

    /// `PrepareNoiseInput` + `Random3Planes` for every AC group: three
    /// `width × height` planes in the upsampled frame domain.
    package static func randomPlanes(
        width: Int, height: Int, groupDim: Int, upsampling: Int,
        numGroupsX: Int, numGroupsY: Int,
        visibleFrameIndex: Int, nonvisibleFrameIndex: Int
    ) -> [[Float]] {
        var planes = (0..<3).map { _ in [Float](repeating: 0, count: width * height) }
        for gy in 0..<numGroupsY {
            for gx in 0..<numGroupsX {
                // The group's rect in the upsampled image, clipped to it.
                let gx0 = gx * groupDim * upsampling
                let gy0 = gy * groupDim * upsampling
                let gx1 = min(gx0 + groupDim * upsampling, width)
                let gy1 = min(gy0 + groupDim * upsampling, height)
                for iy in 0..<upsampling {
                    for ix in 0..<upsampling {
                        let x0 = gx0 + ix * groupDim
                        let y0 = gy0 + iy * groupDim
                        let xsize = x0 <= gx1 ? min(groupDim, gx1 - x0) : 0
                        let ysize = y0 <= gy1 ? min(groupDim, gy1 - y0) : 0
                        var rng = Xorshift128Plus(
                            seed1: UInt32(truncatingIfNeeded: visibleFrameIndex),
                            seed2: UInt32(truncatingIfNeeded: nonvisibleFrameIndex),
                            seed3: UInt32(truncatingIfNeeded: (gx * upsampling + ix) * groupDim),
                            seed4: UInt32(truncatingIfNeeded: (gy * upsampling + iy) * groupDim))
                        for c in 0..<3 {
                            randomRect(rng: &rng, plane: &planes[c], stride: width,
                                       x0: x0, y0: y0, xsize: xsize, ysize: ysize)
                        }
                    }
                }
            }
        }
        return planes
    }

    /// `ConvolveNoiseStage`: 5×5 kernel, centre −3.84, others 0.16,
    /// mirrored borders.
    package static func convolve(_ plane: [Float], width: Int, height: Int) -> [Float] {
        let pw = width + 4
        var padded = [Float](repeating: 0, count: pw * (height + 4))
        for y in 0..<(height + 4) {
            let sy = libjxlMirror(y - 2, height)
            for x in 0..<(width + 4) {
                padded[y * pw + x] = plane[sy * width + libjxlMirror(x - 2, width)]
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let centre = padded[(y + 2) * pw + x + 2]
                var others: Float = 0
                for i in -2...2 {
                    others += padded[y * pw + x + 2 + i]
                    others += padded[(y + 1) * pw + x + 2 + i]
                    others += padded[(y + 3) * pw + x + 2 + i]
                    others += padded[(y + 4) * pw + x + 2 + i]
                }
                others += padded[(y + 2) * pw + x]
                others += padded[(y + 2) * pw + x + 1]
                others += padded[(y + 2) * pw + x + 3]
                others += padded[(y + 2) * pw + x + 4]
                out[y * width + x] = (centre * -3.84).addingProduct(others, 0.16)
            }
        }
        return out
    }

    /// `StrengthEvalLut` + `NoiseStrength`: piecewise-linear LUT over
    /// `x·6`, clamped to [0, 1].
    @inline(__always)
    private static func strength(_ x: Float, lut: [Float]) -> Float {
        let scaled = max(0, x * 6)
        var floorX = scaled.rounded(.down)
        var frac = scaled - floorX
        if scaled >= 7 {
            floorX = 6
            frac = 1
        }
        let idx = Int(floorX)
        let low = lut[idx]
        let high = lut[idx + 1]
        let v = ((high - low) * frac) + low
        return max(0, min(v, 1))
    }

    /// `AddNoiseStage`: adds the convolved noise to XYB in place.
    package static func add(
        x: inout [Float], y: inout [Float], b: inout [Float],
        noise: [[Float]], params: NoiseParams, ytox: Float, ytob: Float
    ) {
        let lut = params.lut
        let normConst: Float = 0.22
        let rgCorr: Float = 0.9921875
        let rgnCorr: Float = 0.0078125
        for i in 0..<x.count {
            let vx = x[i]
            let vy = y[i]
            let inG = (vy - vx) * 0.5
            let inR = (vy + vx) * 0.5
            let strengthG = strength(inG, lut: lut)
            let strengthR = strength(inR, lut: lut)
            let rndR = noise[0][i] * normConst
            let rndG = noise[1][i] * normConst
            let rndC = noise[2][i] * normConst
            let redNoise = strengthR * (rgCorr * rndC).addingProduct(rgnCorr, rndR)
            let greenNoise = strengthG * (rgCorr * rndC).addingProduct(rgnCorr, rndG)
            let rgNoise = redNoise + greenNoise
            x[i] = (redNoise - greenNoise).addingProduct(ytox, rgNoise) + vx
            y[i] = vy + rgNoise
            b[i] = b[i].addingProduct(ytob, rgNoise)
        }
    }
}
