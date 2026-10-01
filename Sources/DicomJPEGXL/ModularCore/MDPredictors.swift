// MDPredictors — the fourteen Modular predictors and the neighbourhood
// rules of ISO/IEC 18181-1 C.7.3, with the integer semantics of the
// reference decoder (`PredictOne` / `Predict` / `ClampedGradient` in
// libjxl `context_predict.h`): 64-bit arithmetic, C truncating division
// for the average predictors, a 32-bit clamped gradient and the edge
// substitutions for missing neighbours. Issue #2332.

import Foundation

/// The neighbourhood of one pixel as the reference decoder samples it.
struct MDNeighbourhood {
    var left: Int64
    var top: Int64
    var topLeft: Int64
    var topRight: Int64
    var leftLeft: Int64
    var topTop: Int64
    var topRightRight: Int64

    /// Samples `row` (current row) and `prevRow` / `prevPrevRow` with the
    /// reference edge rules. `prevRow` / `prevPrevRow` are `nil` when
    /// `y == 0` / `y <= 1`.
    @inline(__always)
    init(
        x: Int, y: Int, width: Int,
        row: UnsafePointer<Int32>, prevRow: UnsafePointer<Int32>?, prevPrevRow: UnsafePointer<Int32>?
    ) {
        let l: Int64
        if x > 0 {
            l = Int64(row[x - 1])
        } else if let p = prevRow {
            l = Int64(p[x])
        } else {
            l = 0
        }
        left = l
        if let p = prevRow {
            top = Int64(p[x])
            topLeft = x > 0 ? Int64(p[x - 1]) : l
            topRight = x + 1 < width ? Int64(p[x + 1]) : top
            topRightRight = x + 2 < width ? Int64(p[x + 2]) : topRight
        } else {
            top = l
            topLeft = l
            topRight = l
            topRightRight = l
        }
        leftLeft = x > 1 ? Int64(row[x - 2]) : l
        topTop = prevPrevRow.map { Int64($0[x]) } ?? top
    }
}

/// `ClampedGradient` of the reference decoder: 32-bit inputs, wrapping
/// intermediate, clamp to `[min(n, w), max(n, w)]`.
@inline(__always)
func mdClampedGradient(_ nIn: Int64, _ wIn: Int64, _ lIn: Int64) -> Int64 {
    let n = Int32(truncatingIfNeeded: nIn)
    let w = Int32(truncatingIfNeeded: wIn)
    let l = Int32(truncatingIfNeeded: lIn)
    let m = min(n, w)
    let M = max(n, w)
    let grad = n &+ w &- l
    if l > M { return Int64(m) }
    if l < m { return Int64(M) }
    return Int64(grad)
}

@inline(__always)
func mdSelect(_ a: Int64, _ b: Int64, _ c: Int64) -> Int64 {
    let p = a &+ b &- c
    let pa = abs(p &- a)
    let pb = abs(p &- b)
    return pa < pb ? a : b
}

/// `PredictOne` of the reference decoder for predictor index `0...13`.
@inline(__always)
func mdPredictOne(_ predictor: UInt32, _ n: MDNeighbourhood, weighted: Int64) -> Int64 {
    switch predictor {
    case 0: return 0
    case 1: return n.left
    case 2: return n.top
    case 3: return (n.left &+ n.top) / 2
    case 4: return mdSelect(n.left, n.top, n.topLeft)
    case 5: return mdClampedGradient(n.left, n.top, n.topLeft)
    case 6: return weighted
    case 7: return n.topRight
    case 8: return n.topLeft
    case 9: return n.leftLeft
    case 10: return (n.left &+ n.topLeft) / 2
    case 11: return (n.topLeft &+ n.top) / 2
    case 12: return (n.top &+ n.topRight) / 2
    case 13:
        return (6 &* n.top &- 2 &* n.topTop &+ 7 &* n.left &+ n.leftLeft
            &+ n.topRightRight &+ 3 &* n.topRight &+ 8) / 16
    default: return 0
    }
}

/// `UnpackSigned` of the reference decoder.
@inline(__always)
func mdUnpackSigned(_ value: UInt32) -> Int64 {
    Int64(Int32(bitPattern: (value >> 1) ^ (0 &- (value & 1))))
}
