// J2KHTBlockLayoutConformant.swift
// ISO/IEC 15444-15 codeblock layout assembler + parser.
//
// Ports the block-assembly code from `ojph_block_encoder.cpp` and
// the scup-parsing logic from `ojph_block_decoder64.cpp`. The
// Part-15 codeblock layout is:
//
//     [MagSgn forward bytes]
//     [MEL forward bytes]
//     [VLC bytes written in reverse order, ending with 0xFF sentinel]
//
// The final 12 bits of the block are overwritten with the Scup
// "interface locator word":
//
// - `block[lcup-1]` holds Scup's high 8 bits = `scup >> 4`
// - `block[lcup-2]` low nibble holds Scup's low 4 bits = `scup & 0xF`
// - `block[lcup-2]` high nibble is preserved from the VLC stream
//
// where `scup = len(MEL) + len(VLC)` and `lcup = len(block)`.
//
// This clobbers the VLC sentinel `0xFF` (the whole last byte) and
// the low nibble of the preceding byte — by design, those bit
// positions are framing, not real VLC data: the reverse VLC bit
// writer seeded the stream with a 4-bit pad after a 0xFF sentinel,
// so the decoder will skip the last byte and only consume the high
// nibble of `block[lcup-2]`.

import Foundation

public enum HTBlockLayoutConformant {

    /// Assemble a Part-15 codeblock from the three pre-terminated
    /// streams. `vlc` must be the forward on-wire order returned by
    /// `HTReverseBitEmitterConformant.finish()` (last element is the
    /// 0xFF sentinel).
    ///
    /// Returns the full block including the 12-bit Scup interface
    /// locator word written into its last two bytes. Throws an
    /// error if the combined MEL+VLC length exceeds Scup's 12-bit
    /// capacity (`> 4079` per ITU T.814) or the block is too short
    /// to hold the Scup itself.
    public static func assemble(
        magsgn: [UInt8],
        mel: [UInt8],
        vlc: [UInt8]
    ) throws -> [UInt8] {
        let scup = mel.count + vlc.count
        if scup < 2 || scup > 4079 {
            throw HTBlockLayoutConformantError.scupOutOfRange(scup)
        }
        var block = [UInt8]()
        block.reserveCapacity(magsgn.count + scup)
        block.append(contentsOf: magsgn)
        block.append(contentsOf: mel)
        block.append(contentsOf: vlc)
        let lcup = block.count
        // Overwrite last 12 bits with Scup. High 8 bits go into
        // block[lcup-1]; low 4 bits replace the low nibble of
        // block[lcup-2].
        block[lcup - 1] = UInt8(scup >> 4)
        block[lcup - 2] = (block[lcup - 2] & 0xF0) | UInt8(scup & 0x0F)
        return block
    }

    /// v9.2 Path B Phase 3 — assemble directly into a `Data`, skipping
    /// the `[UInt8]` intermediate that the legacy `assemble(...) -> [UInt8]`
    /// produces. Used by the hot per-block path in J2KEncoderPipeline,
    /// which previously did `Data(blockBytes)` and paid one extra heap
    /// allocation + one memcpy per block (~1584 blocks for DX). Bit-exact
    /// equivalent of `assemble(magsgn:mel:vlc:)` wrapped in `Data(_:)`.
    public static func assembleData(
        magsgn: [UInt8],
        mel: [UInt8],
        vlc: [UInt8]
    ) throws -> Data {
        let scup = mel.count + vlc.count
        if scup < 2 || scup > 4079 {
            throw HTBlockLayoutConformantError.scupOutOfRange(scup)
        }
        let total = magsgn.count + scup
        var data = Data(count: total)
        data.withUnsafeMutableBytes { rawBuf in
            let dst = rawBuf.bindMemory(to: UInt8.self).baseAddress!
            magsgn.withUnsafeBufferPointer { src in
                if let s = src.baseAddress, src.count > 0 {
                    dst.update(from: s, count: src.count)
                }
            }
            var off = magsgn.count
            mel.withUnsafeBufferPointer { src in
                if let s = src.baseAddress, src.count > 0 {
                    (dst + off).update(from: s, count: src.count)
                }
            }
            off += mel.count
            vlc.withUnsafeBufferPointer { src in
                if let s = src.baseAddress, src.count > 0 {
                    (dst + off).update(from: s, count: src.count)
                }
            }
            // Overwrite last 12 bits with Scup. Same logic as `assemble(...)`.
            dst[total - 1] = UInt8(scup >> 4)
            dst[total - 2] = (dst[total - 2] & 0xF0) | UInt8(scup & 0x0F)
        }
        return data
    }

    /// v9.2 Path B Phase 3 — raw-pointer-input variant. Avoids the
    /// per-block `Array(UnsafeBufferPointer(...))` extraction allocations
    /// that the v9.1 Phase 2c raw-engine path was forced into. The VLC
    /// raw-engine buffer holds bytes in `emittedReversed` order (sentinel
    /// at index 0); pass `vlcReversed: true` to reverse during copy.
    /// Bit-exact equivalent of `assemble(magsgn:mel:vlc:)`.
    public static func assembleDataFromRaw(
        magsgnPtr: UnsafePointer<UInt8>, magsgnCount: Int,
        melPtr: UnsafePointer<UInt8>, melCount: Int,
        vlcPtr: UnsafePointer<UInt8>, vlcCount: Int,
        vlcReversed: Bool
    ) throws -> Data {
        let scup = melCount + vlcCount
        if scup < 2 || scup > 4079 {
            throw HTBlockLayoutConformantError.scupOutOfRange(scup)
        }
        let total = magsgnCount + scup
        var data = Data(count: total)
        data.withUnsafeMutableBytes { rawBuf in
            let dst = rawBuf.bindMemory(to: UInt8.self).baseAddress!
            if magsgnCount > 0 {
                dst.update(from: magsgnPtr, count: magsgnCount)
            }
            var off = magsgnCount
            if melCount > 0 {
                (dst + off).update(from: melPtr, count: melCount)
            }
            off += melCount
            if vlcCount > 0 {
                if vlcReversed {
                    // Reverse-copy: vlcPtr[vlcCount-1] → dst[off],
                    // vlcPtr[0] → dst[off+vlcCount-1].
                    var dstPos = off
                    var srcPos = vlcCount - 1
                    while srcPos >= 0 {
                        dst[dstPos] = vlcPtr[srcPos]
                        dstPos &+= 1
                        srcPos &-= 1
                    }
                } else {
                    (dst + off).update(from: vlcPtr, count: vlcCount)
                }
            }
            dst[total - 1] = UInt8(scup >> 4)
            dst[total - 2] = (dst[total - 2] & 0xF0) | UInt8(scup & 0x0F)
        }
        return data
    }

    /// Parse a Part-15 codeblock. Returns the MagSgn region (read
    /// forward from offset 0) and the combined MEL+VLC region (MEL
    /// read forward from its start, VLC read in reverse from the end
    /// of the block); Scup gives the length of the combined region.
    ///
    /// Returns `nil` for malformed blocks (length < 2, Scup out of
    /// range, or Scup larger than the block itself).
    public static func parse(block: [UInt8])
        -> (magsgn: ArraySlice<UInt8>, melVlc: ArraySlice<UInt8>, scup: Int)?
    {
        let lcup = block.count
        guard lcup >= 2 else { return nil }
        let scup =
            (Int(block[lcup - 1]) << 4) + Int(block[lcup - 2] & 0x0F)
        guard scup >= 2, scup <= lcup, scup <= 4079 else { return nil }
        let split = lcup - scup
        return (
            magsgn: block[0..<split],
            melVlc: block[split..<lcup],
            scup: scup
        )
    }
}

public enum HTBlockLayoutConformantError: Error, Equatable {
    /// Total MEL + VLC byte count falls outside the 12-bit Scup
    /// representable range (valid range: [2, 4079] per T.814).
    case scupOutOfRange(Int)
}
