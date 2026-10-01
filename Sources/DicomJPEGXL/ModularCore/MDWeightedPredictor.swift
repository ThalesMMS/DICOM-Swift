// MDWeightedPredictor — the stateful weighted predictor of the Modular
// sub-bitstream (ISO/IEC 18181-1 Annex C.7.5), written for DICOM-Swift
// (issue #2332) with the exact arithmetic of the reference decoder
// (`weighted::State`, libjxl `lib/jxl/modular/encoding/context_predict.h`,
// BSD-3-Clause, see ThirdPartyLicenses/libjxl): 64-bit intermediates,
// 32-bit error storage with wrapping conversions, the `divlookup` table
// and the monotonicity clamp. State lives in flat buffers so the per-pixel
// path allocates nothing.
//
// Usage per channel: construct once, then for every pixel in raster order
// call `predict(...)` (which also yields property 15) and afterwards
// `updateErrors(actual:x:y:)` with the reconstructed value.

import Foundation

struct MDWeightedPredictor {
    static let predictionRound: Int64 = ((1 << 3) >> 1) - 1

    /// `1 << 24 / (i + 1)` for `i` in `0..<64`.
    static let divLookup: [UInt32] = [
        16_777_216, 8_388_608, 5_592_405, 4_194_304, 3_355_443, 2_796_202, 2_396_745, 2_097_152,
        1_864_135, 1_677_721, 1_525_201, 1_398_101, 1_290_555, 1_198_372, 1_118_481, 1_048_576,
        986_895, 932_067, 883_011, 838_860, 798_915, 762_600, 729_444, 699_050,
        671_088, 645_277, 621_378, 599_186, 578_524, 559_240, 541_200, 524_288,
        508_400, 493_447, 479_349, 466_033, 453_438, 441_505, 430_185, 419_430,
        409_200, 399_457, 390_167, 381_300, 372_827, 364_722, 356_962, 349_525,
        342_392, 335_544, 328_965, 322_638, 316_551, 310_689, 305_040, 299_593,
        294_337, 289_262, 284_359, 279_620, 275_036, 270_600, 266_305, 262_144
    ]

    private var p0: Int64 = 0, p1: Int64 = 0, p2: Int64 = 0, p3: Int64 = 0
    /// The combined prediction *before* removing the extra bits.
    private var pred: Int64 = 0
    /// Four running absolute-error tallies, two rows each, laid out as
    /// `predictor * rowPair + index`.
    private var predErrors: [UInt32]
    /// Signed prediction errors, two rows.
    private var error: [Int32]
    private let xsize: Int
    private let rowPair: Int
    private let p1C: Int64, p2C: Int64, p3Ca: Int64, p3Cb: Int64, p3Cc: Int64, p3Cd: Int64, p3Ce: Int64
    private let w0: UInt32, w1: UInt32, w2: UInt32, w3: UInt32

    init(header: WeightedPredictorHeader, xsize: Int) {
        self.xsize = xsize
        rowPair = (xsize + 2) * 2
        predErrors = [UInt32](repeating: 0, count: rowPair * 4)
        error = [Int32](repeating: 0, count: rowPair)
        p1C = Int64(header.p1C); p2C = Int64(header.p2C)
        p3Ca = Int64(header.p3Ca); p3Cb = Int64(header.p3Cb); p3Cc = Int64(header.p3Cc)
        p3Cd = Int64(header.p3Cd); p3Ce = Int64(header.p3Ce)
        w0 = header.weights.0; w1 = header.weights.1; w2 = header.weights.2; w3 = header.weights.3
    }

    @inline(__always)
    private static func floorLog2Nonzero(_ x: UInt64) -> Int {
        63 - x.leadingZeroBitCount
    }

    @inline(__always)
    private static func errorWeight(_ x: UInt32, _ maxWeight: UInt32) -> UInt32 {
        var shift = floorLog2Nonzero(UInt64(x) &+ 1) - 5
        if shift < 0 { shift = 0 }
        let index = Int(x >> UInt32(shift))
        let product = UInt64(maxWeight) &* UInt64(divLookup[index < 64 ? index : 63])
        return 4 &+ UInt32(truncatingIfNeeded: product >> UInt64(shift))
    }

    /// Returns the prediction for `(x, y)` and stores property 15 into
    /// `property15`.
    @inline(__always)
    mutating func predict(
        x: Int, y: Int, n nIn: Int64, w wIn: Int64, ne neIn: Int64, nw nwIn: Int64, nn nnIn: Int64,
        property15: inout Int32
    ) -> Int64 {
        let odd = (y & 1) != 0
        let curRow = odd ? 0 : (xsize + 2)
        let prevRow = odd ? (xsize + 2) : 0
        let posN = prevRow + x
        let posNE = x < xsize - 1 ? posN + 1 : posN
        let posNW = x > 0 ? posN - 1 : posN

        var wt0: UInt32 = 0, wt1: UInt32 = 0, wt2: UInt32 = 0, wt3: UInt32 = 0
        predErrors.withUnsafeBufferPointer { e in
            let b0 = 0, b1 = rowPair, b2 = 2 * rowPair, b3 = 3 * rowPair
            wt0 = Self.errorWeight(e[b0 + posN] &+ e[b0 + posNE] &+ e[b0 + posNW], w0)
            wt1 = Self.errorWeight(e[b1 + posN] &+ e[b1 + posNE] &+ e[b1 + posNW], w1)
            wt2 = Self.errorWeight(e[b2 + posN] &+ e[b2 + posNE] &+ e[b2 + posNW], w2)
            wt3 = Self.errorWeight(e[b3 + posN] &+ e[b3 + posNE] &+ e[b3 + posNW], w3)
        }
        let n = nIn << 3, w = wIn << 3, ne = neIn << 3, nw = nwIn << 3, nn = nnIn << 3

        let teW: Int64, teN: Int64, teNW: Int64, teNE: Int64
        (teW, teN, teNW, teNE) = error.withUnsafeBufferPointer { e in
            (x == 0 ? 0 : Int64(e[curRow + x - 1]), Int64(e[posN]), Int64(e[posNW]), Int64(e[posNE]))
        }
        let sumWN = teN &+ teW

        var p = teW
        if abs(teN) > abs(p) { p = teN }
        if abs(teNW) > abs(p) { p = teNW }
        if abs(teNE) > abs(p) { p = teNE }
        property15 = Int32(truncatingIfNeeded: p)

        p0 = w &+ ne &- n
        p1 = n &- (((sumWN &+ teNE) &* p1C) >> 5)
        p2 = w &- (((sumWN &+ teNW) &* p2C) >> 5)
        p3 = n &- ((teNW &* p3Ca &+ teN &* p3Cb &+ teNE &* p3Cc &+ (nn &- n) &* p3Cd &+ (nw &- w) &* p3Ce) >> 5)

        // WeightedAverage
        var weightSum = wt0 &+ wt1 &+ wt2 &+ wt3
        let logWeight = UInt32(Self.floorLog2Nonzero(UInt64(weightSum))) - 4
        let s0 = wt0 >> logWeight, s1 = wt1 >> logWeight, s2 = wt2 >> logWeight, s3 = wt3 >> logWeight
        weightSum = s0 &+ s1 &+ s2 &+ s3
        var sum = Int64(weightSum >> 1) - 1
        sum &+= p0 &* Int64(s0) &+ p1 &* Int64(s1) &+ p2 &* Int64(s2) &+ p3 &* Int64(s3)
        pred = (sum &* Int64(Self.divLookup[Int(weightSum) - 1])) >> 24

        if ((teN ^ teW) | (teN ^ teNW)) > 0 {
            return (pred &+ Self.predictionRound) >> 3
        }
        let mx = max(w, max(ne, n))
        let mn = min(w, min(ne, n))
        pred = max(mn, min(mx, pred))
        return (pred &+ Self.predictionRound) >> 3
    }

    @inline(__always)
    mutating func updateErrors(actual: Int64, x: Int, y: Int) {
        let odd = (y & 1) != 0
        let curRow = odd ? 0 : (xsize + 2)
        let prevRow = odd ? (xsize + 2) : 0
        let val = actual << 3
        error[curRow + x] = Int32(truncatingIfNeeded: pred &- val)
        let e0 = UInt32(truncatingIfNeeded: (abs(p0 &- val) &+ Self.predictionRound) >> 3)
        let e1 = UInt32(truncatingIfNeeded: (abs(p1 &- val) &+ Self.predictionRound) >> 3)
        let e2 = UInt32(truncatingIfNeeded: (abs(p2 &- val) &+ Self.predictionRound) >> 3)
        let e3 = UInt32(truncatingIfNeeded: (abs(p3 &- val) &+ Self.predictionRound) >> 3)
        let rp = rowPair
        predErrors.withUnsafeMutableBufferPointer { e in
            e[curRow + x] = e0
            e[prevRow + x + 1] &+= e0
            e[rp + curRow + x] = e1
            e[rp + prevRow + x + 1] &+= e1
            e[2 * rp + curRow + x] = e2
            e[2 * rp + prevRow + x + 1] &+= e2
            e[3 * rp + curRow + x] = e3
            e[3 * rp + prevRow + x + 1] &+= e3
        }
    }
}
