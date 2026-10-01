// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// jpegli's perceptual quantization-table model, ported from libjxl v0.11.2
/// `lib/jpegli/quant.cc` (Apache-2.0). Rather than scaling the ITU-T Annex K
/// tables by an IJG quality factor, jpegli derives each quantization step from
/// perceptually-tuned base matrices and a per-coefficient *non-linear* function
/// of the Butteraugli `distance`. Selected by
/// ``JLIEncoderConfiguration/perceptualQuantTables``; the Annex K path
/// (``Quantization/scaleTable(_:quality:)``) remains the default.
///
/// Only the YCbCr (non-XYB, baseline) model is ported: the default single chroma
/// table uses jpegli's Cr base matrix for both Cb and Cr, and 4:2:0 applies the
/// extra global (1.22) and per-coefficient chroma rescales jpegli uses.
extension Quantization {
    /// `kGlobalScaleYCbCr` — overall YCbCr scale.
    static let jpegliGlobalScaleYCbCr = 1.73966010
    /// `k420GlobalScale` — extra global scale applied for 4:2:0.
    static let jpegliGlobalScale420 = 1.22
    /// `kDist0` — distance below which scaling is linear (`scale == distance`).
    static let jpegliDist0 = 1.5

    static let jpegliBaseY: [Double] = [
        1.239740935, 1.72271151, 2.921216716, 2.812737435, 3.339819712, 3.463603763, 3.840915218, 3.86956,
        1.72271151, 2.092889441, 2.84567609, 2.704506821, 3.440767352, 3.166232352, 4.025208742, 4.035324491,
        2.921216716, 2.84567609, 2.958740352, 3.386294897, 3.619523781, 3.904628, 3.757835838, 4.237447516,
        2.812737435, 2.704506821, 3.386294897, 3.380058822, 4.167986742, 4.805510627, 4.784259, 4.605934,
        3.339819712, 3.440767352, 3.619523781, 4.167986742, 4.579851258, 4.923237, 5.574107, 5.485333361,
        3.463603763, 3.166232352, 3.904628, 4.805510627, 4.923237, 5.43936, 5.093895742, 6.087225442,
        3.840915218, 4.025208742, 3.757835838, 4.784259, 5.574107, 5.093895742, 5.438461, 5.403735949,
        3.86956, 4.035324491, 4.237447516, 4.605934, 5.485333361, 6.087225442, 5.403735949, 4.377871012,
    ]

    /// jpegli's Cr base matrix — used for the single chroma table (Cb and Cr).
    static let jpegliBaseChroma: [Double] = [
        2.921725496, 4.497681013, 7.356344521, 6.583891507, 8.53560874, 8.799434353, 9.188341534, 9.482700481,
        4.497681013, 6.309548852, 7.024608963, 7.156445324, 8.049059219, 7.012429066, 6.711923184, 8.380307846,
        7.356344521, 7.024608963, 6.892101177, 6.882819916, 8.78222609, 6.877475, 7.885817597, 8.67909,
        6.583891507, 7.156445324, 6.882819916, 7.003072945, 7.72234647, 7.95542572, 7.473411, 8.362933243,
        8.53560874, 8.049059219, 8.78222609, 7.72234647, 6.778005927, 9.484922742, 9.043702664, 8.0531782,
        8.799434353, 7.012429066, 6.877475, 7.95542572, 9.484922742, 8.607606527, 9.922697394, 64.2513518,
        9.188341534, 6.711923184, 7.885817597, 7.473411, 9.043702664, 9.922697394, 63.18493655, 83.3529434,
        9.482700481, 8.380307846, 8.67909, 8.362933243, 8.0531782, 64.2513518, 83.3529434, 114.8920245,
    ]

    /// `kExponent` — per-coefficient exponent for the non-linear distance scale.
    static let jpegliExponent: [Double] = [
        1, 0.51, 0.67, 0.74, 1, 1, 1, 1,
        0.51, 0.66, 0.69, 0.87, 1, 1, 1, 1,
        0.67, 0.69, 0.84, 0.83, 0.96, 1, 1, 1,
        0.74, 0.87, 0.83, 1, 1, 0.91, 0.91, 1,
        1, 1, 0.96, 1, 1, 1, 1, 1,
        1, 1, 1, 0.91, 1, 1, 1, 1,
        1, 1, 1, 0.91, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1,
    ]

    /// `k420Rescale` — per-coefficient chroma rescale applied only for 4:2:0.
    static let jpegli420Rescale: [Double] = [
        0.4093, 0.3209, 0.3477, 0.3333, 0.3144, 0.2823, 0.3214, 0.3354,
        0.3209, 0.3111, 0.3489, 0.2801, 0.3059, 0.3119, 0.4135, 0.3445,
        0.3477, 0.3489, 0.3586, 0.3257, 0.2727, 0.3754, 0.3369, 0.3484,
        0.3333, 0.2801, 0.3257, 0.302, 0.3515, 0.341, 0.3971, 0.3839,
        0.3144, 0.3059, 0.2727, 0.3515, 0.3105, 0.3397, 0.2716, 0.3836,
        0.2823, 0.3119, 0.3754, 0.341, 0.3397, 0.3212, 0.3203, 0.0726,
        0.3214, 0.4135, 0.3369, 0.3971, 0.2716, 0.3203, 0.0798, 0.0553,
        0.3354, 0.3445, 0.3484, 0.3839, 0.3836, 0.0726, 0.0553, 0.3368,
    ]

    /// `DistanceToScale`: per-coefficient non-linear mapping from Butteraugli
    /// distance to a quantization scale. Linear below ``jpegliDist0``.
    static func jpegliDistanceToScale(_ distance: Double, _ k: Int) -> Double {
        if distance < jpegliDist0 { return distance }
        let e = jpegliExponent[k]
        let mul = pow(jpegliDist0, 1.0 - e)
        return max(0.5 * distance, mul * pow(distance, e))
    }

    /// Builds a natural-order 64-entry quant table for `distance` using jpegli's
    /// perceptual model. `chroma` selects the Cr base matrix; `isYUV420` adds the
    /// 4:2:0 global and per-coefficient chroma rescales. Clamped to 1...255
    /// (baseline 8-bit).
    static func perceptualQuantTable(distance: Double, chroma: Bool, isYUV420: Bool) -> [Int] {
        let base = chroma ? jpegliBaseChroma : jpegliBaseY
        var gscale = jpegliGlobalScaleYCbCr
        if isYUV420 { gscale *= jpegliGlobalScale420 }
        var table = [Int](repeating: 0, count: 64)
        for k in 0..<64 {
            var scale = gscale * jpegliDistanceToScale(distance, k)
            if isYUV420 && chroma { scale *= jpegli420Rescale[k] }
            table[k] = max(1, min(255, Int((scale * base[k]).rounded())))
        }
        return table
    }

    /// `kGlobalScaleXYB` — overall XYB scale.
    static let jpegliGlobalScaleXYB = 1.43951668
    static let jpegliBaseXYB_X: [Double] = [
        7.5629935, 19.824781, 22.572495, 20.67067, 22.686459, 23.569628, 25.812908, 36.330757,
        19.824781, 21.550318, 19.937223, 20.542421, 21.86455, 23.904139, 28.284407, 32.660976,
        22.572495, 19.937223, 21.901726, 19.122345, 21.751581, 24.67247, 25.424965, 32.665382,
        20.67067, 20.542421, 19.122345, 20.161022, 25.371969, 25.96689, 30.980495, 31.340601,
        22.686459, 21.86455, 21.751581, 25.371969, 26.243185, 40.59922, 43.262463, 63.301094,
        23.569628, 23.904139, 24.67247, 25.96689, 40.59922, 48.302677, 34.096436, 61.985214,
        25.812908, 28.284407, 25.424965, 30.980495, 43.262463, 34.096436, 34.493744, 66.970276,
        36.330757, 32.660976, 32.665382, 31.340601, 63.301094, 61.985214, 66.970276, 39.965271,
    ]
    static let jpegliBaseXYB_Y: [Double] = [
        1.6262001, 3.2199242, 3.4903779, 3.9148359, 4.8337212, 4.9108844, 5.3137121, 6.1676793,
        3.2199242, 3.4547899, 3.603683, 4.2652836, 4.8368387, 4.8226223, 5.6120515, 6.3431473,
        3.4903779, 3.603683, 3.9044559, 4.3374395, 4.8435097, 5.405798, 5.606636, 6.1075134,
        3.9148359, 4.2652836, 4.3374395, 4.6064835, 5.1751475, 5.4013925, 6.0399809, 6.7825232,
        4.8337212, 4.8368387, 4.8435097, 5.1751475, 5.374805, 6.1410837, 7.6529307, 7.5235214,
        4.9108844, 4.8226223, 5.405798, 5.4013925, 6.1410837, 6.3431473, 7.108305, 7.6008301,
        5.3137121, 5.6120515, 5.606636, 6.0399809, 7.6529307, 7.108305, 7.0943155, 7.0478363,
        6.1676793, 6.3431473, 6.1075134, 6.7825232, 7.5235214, 7.6008301, 7.0478363, 6.9186144,
    ]
    static let jpegliBaseXYB_B: [Double] = [
        3.3038473, 10.068926, 12.278522, 14.604117, 16.210732, 19.231453, 28.012955, 55.668289,
        10.068926, 11.408502, 11.387135, 15.493417, 16.536493, 14.915342, 26.374872, 40.861443,
        12.278522, 11.387135, 17.088688, 13.950035, 16.000322, 28.566063, 26.21242, 30.126013,
        14.604117, 15.493417, 13.950035, 21.123503, 26.157978, 25.557922, 40.685936, 33.805634,
        16.210732, 16.536493, 16.000322, 26.157978, 26.804283, 26.158772, 35.734398, 43.685703,
        19.231453, 14.915342, 28.566063, 25.557922, 26.158772, 34.541813, 41.319794, 48.786766,
        28.012955, 26.374872, 26.21242, 40.685936, 35.734398, 41.319794, 47.632946, 55.349846,
        55.668289, 40.861443, 30.126013, 33.805634, 43.685703, 48.786766, 55.349846, 63.60656,
    ]

    /// Builds a natural-order quant table for an XYB channel (0=X, 1=Y, 2=B) from
    /// jpegli's XYB base matrices and the non-linear distance scale. XYB is always
    /// 4:4:4, so there's no chroma rescale. Clamped to 1...255.
    static func perceptualQuantTableXYB(distance: Double, channel: Int) -> [Int] {
        let base = channel == 0 ? jpegliBaseXYB_X : (channel == 1 ? jpegliBaseXYB_Y : jpegliBaseXYB_B)
        var table = [Int](repeating: 0, count: 64)
        for k in 0..<64 {
            let scale = jpegliGlobalScaleXYB * jpegliDistanceToScale(distance, k)
            table[k] = max(1, min(255, Int((scale * base[k]).rounded())))
        }
        return table
    }

    /// Maps an IJG quality (1–100) to a Butteraugli distance — libjxl's
    /// `JpegQualityToDistance`. Used when no explicit distance is configured.
    static func distanceForQuality(_ quality: Double) -> Double {
        let q = max(1.0, min(100.0, quality))
        if q >= 100.0 { return 0.01 }
        if q >= 30.0 { return 0.1 + (100.0 - q) * 0.09 }
        return 53.0 / 3000.0 * q * q - 23.0 / 20.0 * q + 25.0
    }
}
