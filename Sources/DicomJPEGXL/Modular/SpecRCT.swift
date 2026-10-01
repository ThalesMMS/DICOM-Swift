// SpecRCT — full 42-variant Reversible Colour Transform decoder.
//
// ISO/IEC 18181-1 §C.7.7. The spec defines `rct_type` 0..41 — the
// concatenation of:
//
//   • permutation = rct_type / 7 (0..5):
//       0 → RGB (identity output channel order)
//       1 → GBR
//       2 → BRG
//       3 → RBG
//       4 → GRB
//       5 → BGR
//   • custom = rct_type % 7:
//       0 → noop (permutation only)
//       1..5 → Second-then-Third subtract pipeline
//             (Second: 0=nop, 1=SubtractFirst, 2=SubtractAvgFirstThird;
//              Third: 0=nop, 1=SubtractFirst — encoded in the low
//              bits of `custom`)
//       6 → YCoCg-R (the full reversible chroma-luma transform)
//
// Per libjxl `lib/jxl/modular/transform/rct.cc::InvRCT`. **Inverse
// only** — decoder-side. The encoder mirror is the existing
// `RCT.forward(_:channel0:channel1:channel2:)` for the YCoCg-R
// variant; full forward-spec coverage isn't required for this
// decoder milestone.
//
// `inverse(rctType:channel0:channel1:channel2:)` mutates the three
// supplied channel buffers in place. Channels must be the same
// length (all three colour channels at the same wire-level
// resolution after metaApply).

import Foundation

package enum SpecRCTError: Error, Sendable {
    case invalidType(UInt32)
    case mismatchedChannelLengths
}

package enum SpecRCT {

    /// Apply the inverse RCT for `rctType` 0..41 to a triple of
    /// equal-length channel buffers. The buffers are mutated in
    /// place. After return, `(channel0, channel1, channel2)` carries
    /// the post-inverse pixel values in the spec-mandated output
    /// channel order (so for `rct_type` with permutation=0, channel0
    /// holds R, channel1 G, channel2 B).
    package static func inverse(
        rctType: UInt32,
        channel0: inout [Int32],
        channel1: inout [Int32],
        channel2: inout [Int32]
    ) throws {
        guard channel0.count == channel1.count,
              channel1.count == channel2.count else {
            throw SpecRCTError.mismatchedChannelLengths
        }
        guard rctType < 42 else {
            throw SpecRCTError.invalidType(rctType)
        }
        if rctType == 0 {
            return  // Identity / no-op — permutation=0 + custom=0.
        }
        let permutation = Int(rctType / 7)
        let custom = Int(rctType % 7)

        // Read one triple before writing any of its permuted outputs.
        // This keeps only the caller's three planes live.
        for i in channel0.indices {
            var first = channel0[i]
            var second = channel1[i]
            var third = channel2[i]
            if custom == 6 {
                let tmp = first &- (third &>> 1)
                let green = third &+ tmp
                let blue = tmp &- (second &>> 1)
                first = blue &+ second
                second = green
                third = blue
            } else {
                if custom & 1 != 0 { third = third &+ first }
                if custom >> 1 == 1 { second = second &+ first }
                else if custom >> 1 == 2 { second = second &+ ((first &+ third) &>> 1) }
            }
            switch permutation {
            case 0: channel0[i] = first; channel1[i] = second; channel2[i] = third
            case 1: channel0[i] = third; channel1[i] = first; channel2[i] = second
            case 2: channel0[i] = second; channel1[i] = third; channel2[i] = first
            case 3: channel0[i] = first; channel1[i] = third; channel2[i] = second
            case 4: channel0[i] = second; channel1[i] = first; channel2[i] = third
            default: channel0[i] = third; channel1[i] = second; channel2[i] = first
            }
        }
    }
}
