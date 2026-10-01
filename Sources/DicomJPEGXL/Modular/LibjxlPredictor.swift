// LibjxlPredictor — applies the 14 spec / libjxl Modular predictors
// (`enum Predictor` in `lib/jxl/modular/encoding/context_predict.h`).
//
// Our `Predictor` enum (in Predictors.swift) is semantically aligned
// with the spec but uses our own naming convention; for byte-identical
// pixel reconstruction against djxl we need the *exact* libjxl
// formulas, including the ones that have no direct case in our enum
// (TopRight, TopLeft, LeftLeft, Average1..4). This function is the
// source of truth for raw predictor IDs 0..13.
//
// Predictor 6 (Weighted) requires a stateful weighted-predictor
// machine that runs alongside the per-row decode. This file currently
// returns 0 for predictor 6; trees that use it produce incorrect
// pixels until the WP state is wired through. (Most cjxl-emitted
// trees DO use predictor 6, so a proper implementation is on the
// near-term roadmap.)
//
// **Predictor formulas** (a=Top/N, b=Left/W, c=TopLeft/NW,
// d=TopRight/NE; NN=TopTop, WW=LeftLeft, NEE=TopRightRight):
//
//   0  Zero       0
//   1  Left       W
//   2  Top        N
//   3  Average0   (W + N) / 2              (truncated toward zero)
//   4  Select     closest of W / N to W+N-NW; N on a tie
//   5  Gradient   clamp(W+N-NW, min(W,N), max(W,N))
//   6  Weighted   wpResult                  (caller-supplied)
//   7  TopRight   NE                       (with edge fall-back to N)
//   8  TopLeft    NW
//   9  LeftLeft   WW                       (with edge fall-back to W)
//   10 Average1   (W + NW) / 2
//   11 Average2   (NW + N) / 2
//   12 Average3   (N + NE) / 2
//   13 Average4   (6N - 2NN + 7W + WW + NEE + 3NE + 8) / 16
//
// All values stay in `Int32` — wide enough for any 16-bit channel.

import Foundation

/// Apply a libjxl predictor with raw index `raw` to the surrounding
/// neighbourhood. `wpResult` is the weighted-predictor output for
/// predictor 6; pass `0` when not yet implemented.
package func applyLibjxlPredictor(
    raw: UInt32, neighbourhood nbh: Neighbourhood, wpResult: Int32 = 0
) -> Int32 {
    switch raw {
    case 0:
        return 0
    case 1:
        return nbh.w
    case 2:
        return nbh.n
    case 3:
        return Int32((Int64(nbh.w) + Int64(nbh.n)) / 2)
    case 4:
        // Select(left, top, topLeft), including the top-on-tie rule.
        let pa = abs(Int64(nbh.n) - Int64(nbh.nw))
        let pb = abs(Int64(nbh.w) - Int64(nbh.nw))
        return pa < pb ? nbh.w : nbh.n
    case 5:
        // ClampedGradient.
        let g = nbh.w &+ nbh.n &- nbh.nw
        let mn = min(nbh.w, nbh.n)
        let mx = max(nbh.w, nbh.n)
        return min(max(g, mn), mx)
    case 6:
        return wpResult
    case 7:
        return nbh.ne
    case 8:
        return nbh.nw
    case 9:
        return nbh.ww
    case 10:
        return Int32((Int64(nbh.w) + Int64(nbh.nw)) / 2)
    case 11:
        return Int32((Int64(nbh.nw) + Int64(nbh.n)) / 2)
    case 12:
        return Int32((Int64(nbh.n) + Int64(nbh.ne)) / 2)
    case 13:
        let sum = 6 * Int64(nbh.n) - 2 * Int64(nbh.nn) + 7 * Int64(nbh.w)
            + Int64(nbh.ww) + Int64(nbh.nrr) + 3 * Int64(nbh.ne) + 8
        return Int32(truncatingIfNeeded: sum / 16)
    default:
        // Out-of-range — caller should reject before reaching here;
        // return 0 as a safe default.
        return 0
    }
}
