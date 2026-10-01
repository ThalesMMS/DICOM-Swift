// J2KHTBitStreamConformant.swift
// ISO/IEC 15444-15 (HTJ2K) bit-stream emitters.
//
// Ports OpenJPH 0.26's `mel_struct` / `vlc_struct` byte emitters from
// `ojph_block_encoder.cpp`. Scalar-only; SIMD variants are post-v5.0.0.
//
// Two emitters, both byte-aligned on termination:
//
// - `HTForwardBitEmitterConformant` writes bits MSB-first into a forward
//   buffer, FF-stuffing (one reserved high bit after any 0xFF byte so
//   no 0xFF can appear followed by another byte starting with `1`).
//   Used for MEL and MagSgn streams.
//
// - `HTReverseBitEmitterConformant` writes bits from the buffer END
//   backwards, with reverse FF-stuffing (one reserved low bit after any
//   `> 0x8F` byte). Used for the VLC stream which Part-15 stores at the
//   end of the block, read backwards by the decoder.

import Foundation

/// Forward (MEL / MagSgn) bit emitter. Bits are packed MSB-first into
/// bytes. When a `0xFF` byte is emitted, the next byte reserves its
/// high bit as `0` (the stuffed bit), so a Part-15 decoder can tell
/// `0xFF` codeword data apart from marker segments.
public struct HTForwardBitEmitterConformant {
    /// Emitted bytes, in order.
    public private(set) var bytes: [UInt8] = []

    /// Partially-filled byte under construction, MSB-aligned on the
    /// high-order bits as they are shifted in.
    private var tmp: Int = 0

    /// Bits still free in `tmp`. Starts at 8; becomes 7 after the
    /// previous emitted byte was `0xFF` (FF-stuff reserves the high
    /// bit of the next byte).
    private var remainingBits: Int = 8

    public init() {}

    /// v5.38 M8: reset to post-`init()` state, keeping `bytes`'s
    /// existing capacity for buffer reuse across blocks.
    public mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        tmp = 0
        remainingBits = 8
    }

    /// Appends one bit to the stream. Only the LSB of `bit` is used.
    public mutating func emit(bit: Int) {
        tmp = (tmp << 1) | (bit & 1)
        remainingBits -= 1
        if remainingBits == 0 {
            let byte = UInt8(tmp & 0xFF)
            bytes.append(byte)
            // FF-stuff: the byte we just emitted is 0xFF, so the next
            // byte must have its high bit forced to 0. Start with one
            // bit already consumed (value 0), so shift-left won't put
            // a 1 in the high position.
            remainingBits = (byte == 0xFF) ? 7 : 8
            tmp = 0
        }
    }

    /// Appends `count` LSB-first bits of `value`, starting from the
    /// high-order bit of the interesting range (so bits are emitted
    /// MSB-first in the usual ISO-document sense).
    ///
    /// Example: `emit(bits: 0b101, count: 3)` emits `1, 0, 1` in that
    /// order.
    public mutating func emit(bits value: Int, count: Int) {
        var c = count
        while c > 0 {
            c -= 1
            emit(bit: (value >> c) & 1)
        }
    }

    /// Flushes any partially-filled byte. Zero-pads on the LSB side
    /// (bits shift left from the top). Returns the accumulated buffer.
    ///
    /// After `finish()` the emitter is in an indeterminate state; do
    /// not emit further bits into it.
    public mutating func finish() -> [UInt8] {
        if remainingBits != 8 {
            // Left-justify the partial byte: the packed bits sit in
            // the high positions of the high-order nibble already
            // (because each emit shifts tmp left). We need to pad out
            // by remainingBits on the low side.
            tmp <<= remainingBits
            bytes.append(UInt8(tmp & 0xFF))
            tmp = 0
            remainingBits = 8
        }
        return bytes
    }
}

/// Reverse (VLC) bit emitter. Bits are packed into bytes LSB-first;
/// bytes are written to the END of the buffer first, progressing
/// toward the front. Reverse FF-stuffing reserves one low bit of the
/// next byte whenever the last emitted byte was `> 0x8F`, so bit 7
/// of any reversed codeword stays predictable for the decoder.
///
/// Output is produced by `finish()` as a `[UInt8]` in the natural
/// **forward** byte order — i.e. the first element of the returned
/// array is the byte the Part-15 decoder reads *last* (adjacent to
/// the MagSgn stream). The first byte of the buffer is always `0xFF`
/// (end-of-stream sentinel) as required by the standard.
public struct HTReverseBitEmitterConformant {
    /// Bytes already written to the "reversed" tail of the stream,
    /// **in the order they were emitted** (i.e. reversed relative to
    /// the final on-wire stream). The first element is the 0xFF
    /// sentinel, then each subsequent element is the next byte toward
    /// the front of the block.
    private var emittedReversed: [UInt8] = [0xFF]

    /// Partially-filled byte, LSB-aligned.
    private var tmp: Int = 0x0F

    /// Number of bits already occupied in `tmp`. Starts at 4 because
    /// the 0xFF sentinel byte already consumed 4 implicit bits of the
    /// downstream adjacency.
    private var usedBits: Int = 4

    /// Tracks whether the most recently emitted byte was `> 0x8F`,
    /// which forces the next byte's low bit to be `0` (reverse
    /// FF-stuff).
    private var lastGreaterThan8F: Bool = true

    public init() {}

    /// v5.38 M8: reset to post-`init()` state, keeping
    /// `emittedReversed`'s existing capacity for buffer reuse across
    /// blocks. The `[0xFF]` sentinel is restored.
    public mutating func reset() {
        emittedReversed.removeAll(keepingCapacity: true)
        emittedReversed.append(0xFF)
        tmp = 0x0F
        usedBits = 4
        lastGreaterThan8F = true
    }

    /// Append a codeword of `count` bits, LSB-first.
    /// v9.2 Path B Phase 1 — `@inline(__always)` to match the raw-pointer
    /// mirror (HTReverseBitEmitterRawConformant.encode); called for VLC
    /// tuples + UVLC u-values, totalling ~1.3M calls per DX encode.
    @inline(__always)
    public mutating func encode(codeword: Int, count: Int) {
        J2KHTEntropyEncoderProfile.bumpVlcEncode()
        var cwd = codeword
        var len = count
        while len > 0 {
            let stuffPenalty = lastGreaterThan8F ? 1 : 0
            let availBits = 8 - stuffPenalty - usedBits
            let take = min(availBits, len)
            if take > 0 {
                let mask = (1 << take) - 1
                tmp |= (cwd & mask) << usedBits
                usedBits += take
                cwd >>= take
                len -= take
            }
            // `availBits` after `take` describes remaining room in
            // this byte before we flush.
            let remainingAfter = availBits - take
            if remainingAfter == 0 {
                // Byte is full (modulo the stuff-bit). Check whether a
                // stuff byte or a real emission is next.
                if lastGreaterThan8F && tmp != 0x7F {
                    // One empty stuff-bit required; we've already
                    // consumed 7 bits, flipping `lastGreaterThan8F`
                    // off so the next iteration gets 8 real bits.
                    lastGreaterThan8F = false
                    continue
                }
                emittedReversed.append(UInt8(tmp & 0xFF))
                lastGreaterThan8F = tmp > 0x8F
                tmp = 0
                usedBits = 0
            }
        }
    }

    /// Flush the final partial byte and return the forward-ordered
    /// byte sequence. The returned array begins with the byte adjacent
    /// to the MagSgn stream (the byte that the decoder reads **last**
    /// when unwinding the reverse stream) and ends with the `0xFF`
    /// sentinel.
    public mutating func finish() -> [UInt8] {
        if usedBits > 0 {
            emittedReversed.append(UInt8(tmp & 0xFF))
            tmp = 0
            usedBits = 0
        }
        // Reverse so the consumer gets bytes in forward on-wire order.
        return emittedReversed.reversed()
    }
}
