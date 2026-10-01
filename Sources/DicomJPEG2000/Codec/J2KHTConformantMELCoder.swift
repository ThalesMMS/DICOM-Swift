// J2KHTMELCoderConformant.swift
// ISO/IEC 15444-15 (HTJ2K) MEL coder.
//
// Ports OpenJPH 0.26's `mel_struct` encoder (`ojph_block_encoder.cpp`)
// and `dec_mel_st` decoder (`ojph_block_decoder64.cpp`). Scalar only.
//
// The MEL coder compresses a stream of binary events where `0`s are
// far more likely than `1`s. It uses 13 states with the exponent table
// `{0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5}` that controls the current
// threshold `1 << mel_exp[state]`:
//
// - When an event of `0` arrives, the run counter increments; on
//   reaching `threshold`, a `1` bit is emitted (the run was consumed
//   with no terminator) and the state advances (up to 12).
// - When an event of `1` arrives, a `0` bit is emitted followed by
//   `mel_exp[state]` raw bits giving the current zero-count; the run
//   resets and the state rolls back (down to 0).
//
// Output bytes are FF-stuffed: after a `0xFF` byte, the next byte
// reserves its high bit as `0`.

import Foundation

/// Shared MEL exponent table: threshold at state `k` is `1 << melExp[k]`.
/// State 12 caps out at exponent 5 (threshold 32).
@usableFromInline
internal let melExpConformant: [Int] = [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5]

// MARK: - Encoder

/// MEL-stream encoder producing FF-stuffed output bytes. Feed binary
/// events via `encode(eventIsOne:)`; call `finish()` to flush.
public struct HTMELEncoderConformant {
    private var emitter = HTForwardBitEmitterConformant()
    private var state: Int = 0
    private var run: Int = 0
    private var threshold: Int = 1  // 1 << melExpConformant[0]

    public init() {}

    /// v5.38 M8: reset to post-`init()` state, keeping the inner
    /// emitter's `bytes` capacity for buffer reuse across blocks.
    public mutating func reset() {
        emitter.reset()
        state = 0
        run = 0
        threshold = 1
    }

    /// Encode a single MEL event. `eventIsOne == true` means a `1`
    /// event (the rare case that terminates a zero run).
    /// v9.2 Path B Phase 1 — `@inline(__always)` to match the raw-pointer
    /// mirror (HTMELEncoderRawConformant.encode); called per-quad-pair
    /// when c_q == 0, totalling ~33K calls per DX encode.
    @inline(__always)
    public mutating func encode(eventIsOne: Bool) {
        J2KHTEntropyEncoderProfile.bumpMelEncode()
        if !eventIsOne {
            run += 1
            if run >= threshold {
                emitter.emit(bit: 1)
                run = 0
                state = min(12, state + 1)
                threshold = 1 << melExpConformant[state]
            }
        } else {
            emitter.emit(bit: 0)
            var t = melExpConformant[state]
            while t > 0 {
                t -= 1
                emitter.emit(bit: (run >> t) & 1)
            }
            run = 0
            state = max(0, state - 1)
            threshold = 1 << melExpConformant[state]
        }
    }

    /// Flush any in-flight run. If a non-terminated zero run is still
    /// open, emit a final `1` bit so the decoder sees a complete
    /// codeword (mirrors OpenJPH's `terminate_mel_vlc` convention at
    /// block end, minus the MEL/VLC byte-fuse step which lives in the
    /// block-level orchestrator).
    public mutating func finish() -> [UInt8] {
        if run > 0 {
            emitter.emit(bit: 1)
        }
        return emitter.finish()
    }
}

// MARK: - Decoder

/// MEL-stream decoder. Mirrors OpenJPH's `dec_mel_st` + `mel_get_run`:
/// successive calls to `nextRun()` return packed run values where the
/// low bit is a terminator flag and the upper bits hold the event
/// count. Callers consume events by subtracting 2 per event and
/// checking `run == -1` for the terminator — see `HTMELCoderConformant`.
public struct HTMELDecoderConformant {
    private let bytes: ArraySlice<UInt8>
    private let bytesStart: Int
    private let bytesEnd: Int
    private var readIndex: Int = 0       // position relative to bytesStart
    private var tmp: UInt64 = 0          // bit buffer, MSB-first consumption
    private var bits: Int = 0            // valid bits in `tmp`, top-aligned
    private var unstuff: Bool = false    // next byte's high bit is reserved
    private var state: Int = 0

    public init(bytes: [UInt8]) {
        self.init(bytes: bytes[...])
    }

    /// Slice-based init avoids the per-block `Array(parsed.melVlc)` copy
    /// that the legacy `[UInt8]` overload would force on the caller.
    public init(bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.bytesStart = bytes.startIndex
        self.bytesEnd = bytes.endIndex
    }

    /// Returns the next packed run value. The format matches OpenJPH:
    ///
    /// - Even value `run` (low bit 0): `run >> 1` zero events, no
    ///   terminator (the encoder emitted a `1` bit on a threshold hit).
    /// - Odd value `run` (low bit 1): `run >> 1` zero events followed
    ///   by a `1` event (the encoder emitted a `0` bit plus run bits).
    ///
    /// Callers typically iterate:
    /// ```
    /// var run = decoder.nextRun()
    /// while needMore {
    ///     run -= 2
    ///     let isOne = (run == -1)
    ///     // emit event
    ///     if run < 0 { run = decoder.nextRun() }
    /// }
    /// ```
    public mutating func nextRun() -> Int {
        if bits < 6 {
            refill()
        }
        let eval = melExpConformant[state]
        var run: Int
        if (tmp & (UInt64(1) << 63)) != 0 {
            // 1-bit: threshold consecutive zero events, no terminator.
            run = (1 << eval) - 1
            state = min(12, state + 1)
            tmp <<= 1
            bits -= 1
            run <<= 1           // low bit 0 → "no terminator"
        } else {
            // 0-bit: next `eval` bits give the zero-count; then a `1`.
            if eval > 0 {
                run = Int((tmp >> (63 - eval)) & UInt64((1 << eval) - 1))
            } else {
                run = 0
            }
            state = max(0, state - 1)
            tmp <<= (eval + 1)
            bits -= (eval + 1)
            run = (run << 1) + 1 // low bit 1 → "terminator"
        }
        return run
    }

    /// Feed MEL bytes into the bit buffer with FF-unstuffing until at
    /// least 32 bits are available (enough for the longest MEL
    /// codeword, eval=5 → 6 bits, several times over).
    private mutating func refill() {
        while bits <= 32 {
            let byte: UInt8
            let absIdx = bytesStart + readIndex
            if absIdx < bytesEnd {
                byte = bytes[absIdx]
                readIndex += 1
            } else {
                byte = 0xFF // post-EOF pad (per OpenJPH convention)
            }
            let dBits = 8 - (unstuff ? 1 : 0)
            let value = UInt64(byte) & ((UInt64(1) << dBits) - 1)
            tmp |= value << (64 - bits - dBits)
            bits += dBits
            unstuff = (byte == 0xFF)
        }
    }
}

// MARK: - Event round-trip helper

/// High-level round-trip helper for testing. `encodeEvents` compresses
/// an explicit list of events (`false` = 0, `true` = 1) and
/// `decodeEvents` reconstructs the original list given an expected
/// event count, mirroring OpenJPH's caller-side MEL consumption.
public enum HTMELCoderConformant {
    /// Encode a list of MEL events, returning the raw byte stream.
    public static func encodeEvents(_ events: [Bool]) -> [UInt8] {
        var encoder = HTMELEncoderConformant()
        for e in events {
            encoder.encode(eventIsOne: e)
        }
        return encoder.finish()
    }

    /// Decode `count` MEL events from `bytes`.
    public static func decodeEvents(_ bytes: [UInt8], count: Int) -> [Bool] {
        var decoder = HTMELDecoderConformant(bytes: bytes)
        var events: [Bool] = []
        events.reserveCapacity(count)
        var run = decoder.nextRun()
        while events.count < count {
            run -= 2
            events.append(run == -1)
            if run < 0 {
                run = decoder.nextRun()
            }
        }
        return events
    }
}
