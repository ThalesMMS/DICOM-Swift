// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

import Foundation

/// jpegli adaptive-quantization field (WS-A / 0.3.0). A faithful scalar port of
/// libjxl v0.11.2 `lib/jpegli/adaptive_quantization.cc`: from the luma plane it
/// computes a per-8×8-block `aq_strength` that later modulates a per-coefficient
/// zero-bias (dead-zone) during quantization, quantizing busy/visually-masked
/// blocks harder while preserving smooth (banding-prone) ones.
///
/// This is the field computation only; the zero-bias application + RD-validation
/// vs jpegli are the next WS-A steps. Operates on luma in the [0,255] range
/// (JLISwift's `y` plane), matching the constants' `kInputScaling = 1/255`.
///
/// **Not yet wired into the encoder** — gated behind the forthcoming opt-in
/// quantization path; the simplified `adaptiveQuantField` λ-proxy is unchanged.
enum JLIAdaptiveQuant {

    static let kInputScaling: Float = 1.0 / 255.0

    // MARK: - Pointwise helpers (direct ports)

    /// Visual-masking exponent modulation (`ComputeMask`).
    @inline(__always)
    static func computeMask(_ outVal: Float) -> Float {
        let v1 = max(outVal * 0.74760422233706747, 1e-3)
        let v2 = 1.0 / (v1 + 305.04035728311436)
        let v3 = 1.0 / (v1 * v1 + 2.1925739705298404)
        let v4 = 1.0 / (v1 * v1 + 0.25 * 2.1925739705298404)
        return -0.74174993 + 3.2353257320940401 * v4
            + 12.906028311180409 * v2 + 5.0220313103171232 * v3
    }

    private static let kSGmul: Float = 226.0480446705883
    private static let kSGmul2: Float = 1.0 / 73.377132366608819
    private static let kLog2: Float = 0.693147181
    private static let kSGRetMul: Float = kSGmul2 * 18.6580932135 * kLog2
    private static let kSGVOffset: Float = 7.14672470003

    /// Ratio of derivatives of cube-root vs simple-gamma (moves between jxl opsin
    /// and butteraugli log-gamma space).
    @inline(__always)
    static func ratioOfDerivatives(_ v: Float, invert: Bool) -> Float {
        let kEpsilon: Float = 1e-2
        let kNumOffset = kEpsilon / kInputScaling / kInputScaling
        let kNumMul = kSGRetMul * 3 * kSGmul
        let kVOffset = (kSGVOffset * kLog2 + kEpsilon) / kInputScaling
        let kDenMul = kLog2 * kSGmul * kInputScaling * kInputScaling
        let vv = max(v, 0)
        let v2 = vv * vv
        let num = kNumMul * v2 + kNumOffset
        let den = (kDenMul * vv) * v2 + kVOffset
        return invert ? num / den : den / num
    }

    /// `MaskingSqrt` — a saturating sqrt used in the difference accumulation.
    @inline(__always)
    static func maskingSqrt(_ v: Float) -> Float {
        let mul = Float(211.50759899638012 * 1e8)
        return 0.25 * (v * mul.squareRoot() + 28).squareRoot()
    }

    // MARK: - Per-block modulations

    /// Sum over the 8×8 block of the inverse cube-root/gamma ratio, folded into
    /// the exponent (`GammaModulation`).
    private static func gammaModulation(
        _ p: UnsafePointer<Float>, x: Int, y: Int, width w: Int, _ outVal: Float
    ) -> Float {
        let kBias = 0.16 / kInputScaling
        let kScale = kInputScaling / 64.0
        var overall: Float = 0
        for dy in 0..<8 {
            let row = (y + dy) * w + x
            for dx in 0..<8 {
                overall += ratioOfDerivatives(p[row + dx] + kBias, invert: true)
            }
        }
        overall *= kScale
        let kGamma: Float = -0.15526878023684174 * 0.693147180559945
        return kGamma * log2(overall) + outVal
    }

    /// High-frequency content modulation — sum of |right| and |below| abs diffs
    /// over the block (`HfModulation`).
    private static func hfModulation(
        _ p: UnsafePointer<Float>, x: Int, y: Int, width w: Int, height h: Int, _ outVal: Float
    ) -> Float {
        let kSumCoeff = Float(-2.0052193233688884) * kInputScaling / 112.0
        var sum: Float = 0
        for dy in 0..<8 {
            let row = (y + dy) * w + x
            let nextRow = (dy == 7) ? row : row + w
            for dx in 0..<8 {
                if dx < 7 { sum += abs(p[row + dx] - p[row + dx + 1]) }   // right
                sum += abs(p[row + dx] - p[nextRow + dx])                 // below
            }
        }
        return sum * kSumCoeff + outVal
    }

    // MARK: - Field

    /// Computes per-block `aq_strength` (≥ 0) for the block-padded luma `plane`
    /// (`width = blocksH·8`, `height = blocksV·8`, values in [0,255]).
    /// `yQuant01` is the Y quant table's first AC step (`quantval[1]`).
    static func computeField(
        plane: [Float], planeWidth: Int, planeHeight: Int,
        blocksH: Int, blocksV: Int, yQuant01: Int
    ) -> [Float] {
        // Work on the block-padded W×H grid; edge-replicate the (possibly
        // smaller, e.g. 886-wide) source plane so the multi-resolution indexing
        // is exact and reads never go out of bounds.
        let w = blocksH * 8, h = blocksV * 8
        var padded = [Float](unsafeUninitializedCapacity: w * h) { _, c in c = w * h }
        plane.withUnsafeBufferPointer { src in
            padded.withUnsafeMutableBufferPointer { dst in
                let s = src.baseAddress!, d = dst.baseAddress!
                for y in 0..<h {
                    let sy = min(y, planeHeight - 1) * planeWidth
                    let dy = y * w
                    for x in 0..<w { d[dy + x] = s[sy + min(x, planeWidth - 1)] }
                }
            }
        }
        let pw = w / 4, ph = h / 4
        var pre = [Float](repeating: 0, count: pw * ph)
        let matchGammaOffset = 0.019 / kInputScaling
        let limit: Float = 0.2

        padded.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            var rowAccum = [Float](repeating: 0, count: w)
            rowAccum.withUnsafeMutableBufferPointer { ra in
                let acc = ra.baseAddress!
                for y in 0..<h {
                    let row = y * w
                    let rowT = max(0, y - 1) * w
                    let rowB = min(h - 1, y + 1) * w
                    for x in 0..<w {
                        let inv = p[row + x]
                        let base = 0.25 * (p[row + max(0, x - 1)] + p[row + min(w - 1, x + 1)]
                                           + p[rowT + x] + p[rowB + x])
                        let g = ratioOfDerivatives(inv + matchGammaOffset, invert: false)
                        var diff = g * (inv - base)
                        diff = diff * diff
                        diff = min(diff, limit)
                        diff = maskingSqrt(diff)
                        acc[x] = (y & 3) == 0 ? diff : acc[x] + diff
                    }
                    if (y & 3) == 3 {
                        let yo = (y / 4) * pw
                        for xo in 0..<pw {
                            let b = xo * 4
                            pre[yo + xo] = 0.25 * (acc[b] + acc[b + 1] + acc[b + 2] + acc[b + 3])
                        }
                    }
                }
            }
        }

        // Fuzzy erosion: weighted sum of the 4 smallest in each 3×3 neighborhood,
        // then 2× box-downsample to block resolution.
        var eroded = [Float](repeating: 0, count: pw * ph)
        var nb = [Float](repeating: 0, count: 9)
        for y in 0..<ph {
            for x in 0..<pw {
                var i = 0
                for dy in -1...1 {
                    let yy = min(max(0, y + dy), ph - 1) * pw
                    for dx in -1...1 {
                        nb[i] = pre[yy + min(max(0, x + dx), pw - 1)]; i += 1
                    }
                }
                nb.sort()
                eroded[y * pw + x] = 0.125 * nb[0] + 0.075 * nb[1] + 0.06 * nb[2] + 0.05 * nb[3]
            }
        }

        // Per-block modulations + the final 0.6/field − 1 strength transform.
        let yq = Float(yQuant01)
        let kAcQuant: Float = 0.841
        let baseLevel = 0.48 * kAcQuant
        var dampen: Float = 1
        if yq >= 9 { dampen = max(0, 1 - (yq - 9) / (65 - 9)) }
        let mul = kAcQuant * dampen
        let add = (1 - dampen) * baseLevel

        var field = [Float](repeating: 0, count: blocksH * blocksV)
        padded.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            for yb in 0..<blocksV {
                for xb in 0..<blocksH {
                    var v = eroded[(yb * 2) * pw + xb * 2] + eroded[(yb * 2) * pw + xb * 2 + 1]
                          + eroded[(yb * 2 + 1) * pw + xb * 2] + eroded[(yb * 2 + 1) * pw + xb * 2 + 1]
                    v = computeMask(v)
                    v = hfModulation(p, x: xb * 8, y: yb * 8, width: w, height: h, v)
                    v = gammaModulation(p, x: xb * 8, y: yb * 8, width: w, v)
                    let qf = exp(v) * mul + add
                    field[yb * blocksH + xb] = max(0, 0.6 / qf - 1.0)
                }
            }
        }
        return field
    }

    // MARK: - Zero-bias (dead-zone) tables + per-coefficient quantization

    /// AC zero-bias offset per channel (Y, Cb, Cr); DC offset is 0.
    static let kZeroBiasOffsetAC: [Float] = [0.59082, 0.58146, 0.57988]

    /// Per-channel, per-coefficient zero-bias: `offset[k] + aq_strength·mul[k]` is
    /// the dead-zone threshold on the quantized coefficient magnitude. `mul` is a
    /// distance-interpolated blend of the low- and high-quality tables (libjxl
    /// `quant.cc`); `distance` 1.0 → HQ, 3.0 → LQ. Natural (not zigzag) order.
    static func zeroBias(distance: Double, component c: Int) -> (offset: [Float], mul: [Float]) {
        let mix0 = Float(min(max((distance - 1.0) / (3.0 - 1.0), 0.0), 1.0))   // → LQ weight
        let mix1 = 1 - mix0                                                     // → HQ weight
        let cc = min(max(c, 0), 2)
        var mul = [Float](repeating: 0, count: 64)
        var offset = [Float](repeating: 0, count: 64)
        for k in 0..<64 {
            mul[k] = mix0 * kZeroBiasMulLQ[cc * 64 + k] + mix1 * kZeroBiasMulHQ[cc * 64 + k]
            offset[k] = k == 0 ? 0 : kZeroBiasOffsetAC[cc]
        }
        return (offset, mul)
    }

    static let kZeroBiasMulLQ: [Float] = [
        // c=0
        0.0000, 0.0568, 0.3880, 0.6190, 0.6190, 0.4490, 0.4490, 0.6187,
        0.0568, 0.5829, 0.6189, 0.6190, 0.6190, 0.7190, 0.6190, 0.6189,
        0.3880, 0.6189, 0.6190, 0.6190, 0.6190, 0.6190, 0.6187, 0.6100,
        0.6190, 0.6190, 0.6190, 0.6190, 0.5890, 0.3839, 0.7160, 0.6190,
        0.6190, 0.6190, 0.6190, 0.5890, 0.6190, 0.3880, 0.5860, 0.4790,
        0.4490, 0.7190, 0.6190, 0.3839, 0.3880, 0.6190, 0.6190, 0.6190,
        0.4490, 0.6190, 0.6187, 0.7160, 0.5860, 0.6190, 0.6204, 0.6190,
        0.6187, 0.6189, 0.6100, 0.6190, 0.4790, 0.6190, 0.6190, 0.3480,
        // c=1
        0.0000, 1.1640, 0.9373, 1.1319, 0.8016, 0.9136, 1.1530, 0.9430,
        1.1640, 0.9188, 0.9160, 1.1980, 1.1830, 0.9758, 0.9430, 0.9430,
        0.9373, 0.9160, 0.8430, 1.1720, 0.7083, 0.9430, 0.9430, 0.9430,
        1.1319, 1.1980, 1.1720, 1.1490, 0.8547, 0.9430, 0.9430, 0.9430,
        0.8016, 1.1830, 0.7083, 0.8547, 0.9430, 0.9430, 0.9430, 0.9430,
        0.9136, 0.9758, 0.9430, 0.9430, 0.9430, 0.9430, 0.9430, 0.9430,
        1.1530, 0.9430, 0.9430, 0.9430, 0.9430, 0.9430, 0.9430, 0.9480,
        0.9430, 0.9430, 0.9430, 0.9430, 0.9430, 0.9430, 0.9480, 0.9430,
        // c=2
        0.0000, 1.3190, 0.4308, 0.4460, 0.0661, 0.0660, 0.2660, 0.2960,
        1.3190, 0.3280, 0.3093, 0.0750, 0.0505, 0.1594, 0.3060, 0.2113,
        0.4308, 0.3093, 0.3060, 0.1182, 0.0500, 0.3060, 0.3915, 0.2426,
        0.4460, 0.0750, 0.1182, 0.0512, 0.0500, 0.2130, 0.3930, 0.1590,
        0.0661, 0.0505, 0.0500, 0.0500, 0.3055, 0.3360, 0.5148, 0.5403,
        0.0660, 0.1594, 0.3060, 0.2130, 0.3360, 0.5060, 0.5874, 0.3060,
        0.2660, 0.3060, 0.3915, 0.3930, 0.5148, 0.5874, 0.3060, 0.3060,
        0.2960, 0.2113, 0.2426, 0.1590, 0.5403, 0.3060, 0.3060, 0.3060,
    ]

    static let kZeroBiasMulHQ: [Float] = [
        // c=0
        0.0000, 0.0044, 0.2521, 0.6547, 0.8161, 0.6130, 0.8841, 0.8155,
        0.0044, 0.6831, 0.6553, 0.6295, 0.7848, 0.7843, 0.8474, 0.7836,
        0.2521, 0.6553, 0.7834, 0.7829, 0.8161, 0.8072, 0.7743, 0.9242,
        0.6547, 0.6295, 0.7829, 0.8654, 0.7829, 0.6986, 0.7818, 0.7726,
        0.8161, 0.7848, 0.8161, 0.7829, 0.7471, 0.7827, 0.7843, 0.7653,
        0.6130, 0.7843, 0.8072, 0.6986, 0.7827, 0.7848, 0.9508, 0.7653,
        0.8841, 0.8474, 0.7743, 0.7818, 0.7843, 0.9508, 0.7839, 0.8437,
        0.8155, 0.7836, 0.9242, 0.7726, 0.7653, 0.7653, 0.8437, 0.7819,
        // c=1
        0.0000, 1.0816, 1.0556, 1.2876, 1.1554, 1.1567, 1.8851, 0.5488,
        1.0816, 1.1537, 1.1850, 1.0712, 1.1671, 2.0719, 1.0544, 1.4764,
        1.0556, 1.1850, 1.2870, 1.1981, 1.8181, 1.2618, 1.0564, 1.1191,
        1.2876, 1.0712, 1.1981, 1.4753, 2.0609, 1.0564, 1.2645, 1.0564,
        1.1554, 1.1671, 1.8181, 2.0609, 0.7324, 1.1163, 0.8464, 1.0564,
        1.1567, 2.0719, 1.2618, 1.0564, 1.1163, 1.0040, 1.0564, 1.0564,
        1.8851, 1.0544, 1.0564, 1.2645, 0.8464, 1.0564, 1.0564, 1.0564,
        0.5488, 1.4764, 1.1191, 1.0564, 1.0564, 1.0564, 1.0564, 1.0564,
        // c=2
        0.0000, 0.5392, 0.6659, 0.8968, 0.6829, 0.6328, 0.5802, 0.4836,
        0.5392, 0.6746, 0.6760, 0.6102, 0.6015, 0.6958, 0.7327, 0.4897,
        0.6659, 0.6760, 0.6957, 0.6543, 0.4396, 0.6330, 0.7081, 0.2583,
        0.8968, 0.6102, 0.6543, 0.5913, 0.6457, 0.5828, 0.5139, 0.3565,
        0.6829, 0.6015, 0.4396, 0.6457, 0.5633, 0.4263, 0.6371, 0.5949,
        0.6328, 0.6958, 0.6330, 0.5828, 0.4263, 0.2847, 0.2909, 0.6629,
        0.5802, 0.7327, 0.7081, 0.5139, 0.6371, 0.2909, 0.6644, 0.6644,
        0.4836, 0.4897, 0.2583, 0.3565, 0.5949, 0.6629, 0.6644, 0.6644,
    ]
}
