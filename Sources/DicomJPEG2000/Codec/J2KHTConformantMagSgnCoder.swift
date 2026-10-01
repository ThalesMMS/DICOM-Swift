// J2KHTMagSgnCoderConformant.swift
// ISO/IEC 15444-15 MagSgn (magnitude-and-sign) stream coder.
//
// Ports OpenJPH 0.26's `ms_struct` encoder (`ojph_block_encoder.cpp`)
// and `frwd_struct64` decoder (`ojph_block_decoder64.cpp`). Scalar.
//
// The MagSgn stream is a forward-growing byte stream carrying the
// low-order magnitude + sign bits for every significant sample in a
// codeblock. The layout is:
//
// - bits are packed LSB-first into bytes (the first sample's bits
//   occupy the low-order bits of the first output byte);
// - after any emitted `0xFF` byte, the following byte's high bit is
//   reserved as a 0 stuff bit — so the decoder can always recognise
//   marker-segment escapes;
// - termination flushes the final partial byte padded with 1-bits;
//   if that flushed byte would be `0xFF` it is dropped instead (the
//   decoder substitutes 0xFF when it runs off the end of the stream,
//   so the trailing byte is implicit).
//
// This coder *does not* compute the neighborhood predictor itself —
// the U-value and epsilon derivations live in the cleanup-pass
// orchestrator (M5). It is purely the bit-packing transport layer
// for the magnitude/sign bits the cleanup pass has already computed.

import Foundation

// MARK: - Encoder

/// MagSgn forward bit emitter. Bits are packed LSB-first. After each
/// `0xFF` byte, the next byte reserves its high bit as a 0 stuff bit.
public struct HTMagSgnEncoderConformant {
    public private(set) var bytes: [UInt8] = []
    private var tmp: UInt32 = 0
    private var usedBits: Int = 0
    private var maxBits: Int = 8

    public init() {}

    /// v5.38 M8: reset to the post-`init()` state, **keeping** the
    /// `bytes` array's existing capacity. Used by the per-chunk
    /// reusable-buffer path in `applyEntropyCodingHTJ2KFused` so the
    /// 2300+ blocks of a DX 12 MP encode don't each allocate fresh
    /// internal buffers. Bit-exact equivalent of `var enc = HTMagSgnEncoderConformant()`.
    public mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        tmp = 0
        usedBits = 0
        maxBits = 8
    }

    /// Emit the low-order `count` bits of `codeword`, LSB-first.
    /// v9.2 Path B Phase 1 — `@inline(__always)` so the optimizer inlines
    /// this at the encodeLoopGeneric call site (~1.5M calls per DX encode;
    /// the raw-pointer mirror in `HTMagSgnEncoderRawConformant.encode` has
    /// been annotated since Phase 2c).
    @inline(__always)
    public mutating func encode(codeword: UInt32, count: Int) {
        J2KHTEntropyEncoderProfile.bumpMagsgnEncode(count)
        // v9.2 Path B Phase 2 — fast path for the common case where the
        // whole codeword fits in the remaining bits of the current byte
        // (no flush needed). Roughly half of MagSgn calls on a typical
        // DX encode have `count ≤ maxBits - usedBits`. The fast path
        // skips the while-loop + `min` + flush-check entirely. Bit-exact
        // equivalent of the loop's first iteration when no flush would
        // happen.
        let avail = maxBits - usedBits
        if count > 0 && count < avail {
            let mask: UInt32 = (UInt32(1) << count) - 1
            tmp |= (codeword & mask) << usedBits
            usedBits += count
            return
        }
        var cwd = codeword
        encodeInternal(cwd: &cwd, len: count)
    }

    /// v9.3 Path B Phase 3 — wide-codeword MagSgn emit. Packs up to 64
    /// bits in one call, bit-exact equivalent of an equivalent number of
    /// sequential 1-bit-to-32-bit `encode(codeword:count:)` calls whose
    /// low-bit-first concatenation equals `codeword`'s low `count` bits.
    ///
    /// Use case: the per-quad `emitQuadMagSgn` packs up to 4 sample
    /// payloads into one combined codeword to reduce the 1.5M
    /// emit-call count on a DX encode by ~4× (one batched call per
    /// significant quad instead of one call per significant sample).
    /// Per-call fixed-overhead (function preamble, counter bump, fast-path
    /// check) amortizes across the 4 sub-emissions, ~50-70% reduction
    /// in MagSgn call overhead.
    ///
    /// `count` must be in `[0, 64]`. Bit-exact equivalent (per byte) of
    /// `encode(codeword: UInt32(codeword & 0xFFFFFFFF), count: min(count, 32))`
    /// followed by `encode(codeword: UInt32(codeword >> 32), count: max(0, count-32))`
    /// when count > 32. Verified by HTMagSgnEncode64ParityTests sweep.
    @inline(__always)
    public mutating func encode64(codeword: UInt64, count: Int) {
        J2KHTEntropyEncoderProfile.bumpMagsgnEncode(count)
        if count == 0 { return }
        let avail = maxBits - usedBits
        if count < avail {
            // Whole codeword fits in current byte. No flush, no loop.
            let mask: UInt64 = (UInt64(1) << count) - 1
            tmp |= UInt32(codeword & mask) << usedBits
            usedBits += count
            return
        }
        var cwd64 = codeword
        var len = count
        // Process 8 bits at a time (one byte) until len <= 32, then
        // fall through to the 32-bit-codeword loop body for the tail.
        // Each byte goes through the byte-stuffing path identically to
        // sequential single-byte writes.
        while len > 32 {
            let take = maxBits - usedBits  // 1-8 bits available in current byte
            let mask: UInt64 = (UInt64(1) << take) - 1
            tmp |= UInt32(cwd64 & mask) << usedBits
            usedBits += take
            cwd64 >>= take
            len -= take
            if usedBits >= maxBits {
                let byte = UInt8(tmp & 0xFF)
                bytes.append(byte)
                maxBits = (byte == 0xFF) ? 7 : 8
                tmp = 0
                usedBits = 0
            }
        }
        // Tail: len ≤ 32, can fit in a UInt32 codeword.
        var cwd = UInt32(cwd64 & 0xFFFFFFFF)
        encodeInternal(cwd: &cwd, len: len)
    }

    /// v9.3 — shared body for the encode and encode64 paths once the
    /// codeword has been narrowed to UInt32 and the fast-path miss has
    /// been determined. Pre-Phase-3, this was inlined inside `encode`.
    @inline(__always)
    private mutating func encodeInternal(cwd: inout UInt32, len: Int) {
        var lenLocal = len
        while lenLocal > 0 {
            let take = min(maxBits - usedBits, lenLocal)
            let mask: UInt32 = (take >= 32) ? ~UInt32(0) : ((UInt32(1) << take) - 1)
            tmp |= (cwd & mask) << usedBits
            usedBits += take
            cwd >>= take
            lenLocal -= take
            if usedBits >= maxBits {
                let byte = UInt8(tmp & 0xFF)
                bytes.append(byte)
                maxBits = (byte == 0xFF) ? 7 : 8
                tmp = 0
                usedBits = 0
            }
        }
    }

    /// Flush the final partial byte. Pads with 1-bits; if the padded
    /// byte is `0xFF` it is dropped (decoder feeds 0xFF when
    /// exhausted, so the trailing byte is implicit). Also handles the
    /// edge case where termination leaves a reserved-stuff-bit slot
    /// empty: the `pos--` rollback from `ms_terminate`.
    public mutating func finish() -> [UInt8] {
        if usedBits != 0 {
            let padBits = maxBits - usedBits
            let padMask: UInt32 = (padBits >= 32) ? ~UInt32(0)
                                                  : ((UInt32(1) << padBits) - 1)
            tmp |= padMask << usedBits
            let byte = UInt8(tmp & 0xFF)
            if byte != 0xFF {
                bytes.append(byte)
            }
            tmp = 0
            usedBits = 0
            maxBits = 8
        } else if maxBits == 7 {
            // ms_terminate: a pending reserved stuff-bit slot with no
            // real bits to follow means we over-committed one byte
            // position; roll it back.
            bytes.removeLast()
            maxBits = 8
        }
        return bytes
    }
}

// MARK: - Decoder

/// MagSgn forward bit reader. Bits are consumed LSB-first. Every
/// byte that follows a `0xFF` byte contributes only 7 bits (its high
/// bit is a reserved stuff bit). When the byte stream is exhausted,
/// `0xFF` is fed — matching OpenJPH's `frwd_read<X=0xFF>` convention.
public struct HTMagSgnDecoderConformant {
    /// **v7.4 batched refill gate.** Default `true` — rigorous A/B
    /// benchmarking measured **+3.70 ms (5.9 %) DX 2800×2288 in-
    /// process decode improvement** for the SWAR-batched 4-byte
    /// refill vs the scalar byte-by-byte reference, clearing v7.4's
    /// 3 ms threshold for default-on enablement
    /// (`V740NeonRefillDXWallBenchmark`). Bit-exact-equivalent to
    /// scalar per `V740NeonRefillParityTests` (11/11 sweeps pass:
    /// all-zero, all-FF, alternating, FF at every batch position,
    /// 32 random seeds, stream-exhaust padding from FF-end, empty,
    /// tiny, sub-batch-size streams).
    ///
    /// Mechanism: 4-byte unaligned UInt32 load + SWAR
    /// (SIMD-within-a-register) 0xFF-detect. The common case (no
    /// 0xFF in the batch + no carried unstuff — ~99 % of batches at
    /// the corpus-typical FF-density of ~0.4 %) reduces to one
    /// 32-bit load and one OR-into-accumulator with no per-byte
    /// conditional. The slow fallback handles 0xFF-bearing batches
    /// scalar-byte-by-byte, identical to the scalar reference.
    ///
    /// Per-call microbench gain (V740NeonRefillMicrobench, median
    /// of 5):
    ///
    ///     width      | scalar ns | batched ns | speedup
    ///      3 bits    |   3.54    |   3.38     | 1.05×
    ///      7 bits    |   3.90    |   3.80     | 1.03×
    ///     14 bits    |   5.70    |   4.96     | 1.15×
    ///     32 bits    |  10.09    |   6.77     | 1.49×
    ///
    /// Tests can flip to `false` to verify the scalar path or
    /// reproduce A/B numbers.
    nonisolated(unsafe) public static var neonRefillEnabled: Bool = true

    /// **v8.1 Phase 1B 8-byte SWAR + 128-bit accumulator refill
    /// gate.** Default `false` while the prototype graduates to a
    /// production default. When `true`, `refill()` dispatches to
    /// `refillBatched8` — an 8-byte unaligned `UInt64` load with
    /// SWAR FF-detect, folding 8 bytes (= 64 bits) per fast-path
    /// iteration into a 128-bit accumulator (`tmp` + `tmpHi`).
    ///
    /// Phase 1A microbench (V8_1_PrefixScanPhase1ABench) measured
    /// 1.21×–1.40× speedup vs the v7.4 4-byte path across the FF-
    /// density range 0 %–25 %. At corpus density 0.4 %, the gain is
    /// 1.37× (4.96 → 3.61 ns/call), saving ~1.35 ns per `read()`.
    ///
    /// Bit-exact-equivalent to the scalar and v7.4 4-byte paths
    /// across 16,520 parity cells (V8_1_Phase1B_ParityTests +
    /// V8_1_PrefixScanPhase1ABench parity sweeps).
    ///
    /// Default flips to `true` in Phase 3 if the end-to-end DX A/B
    /// (Phase 2) clears v7.4's ≥ 3 ms acceptance threshold.
    nonisolated(unsafe) public static var swarRefill8Enabled: Bool = false

    private let bytes: ArraySlice<UInt8>
    private let bytesStart: Int
    private let bytesEnd: Int
    private var readIndex: Int   // position relative to bytesStart
    private var tmp: UInt64 = 0
    /// **v8.1 Phase 1B** — high 64 bits of the 128-bit bit
    /// accumulator. Written only by `refillBatched8`; on every
    /// other refill path (`refillBatched`, `refillScalar`) this
    /// stays zero across the decoder's lifetime.
    private var tmpHi: UInt64 = 0
    private var bits: Int = 0
    private var unstuff: Bool = false

    /// **v8.1 Phase 1B** — refill-path selector cached at init.
    /// Reading the static `swarRefill8Enabled` / `neonRefillEnabled`
    /// flags from a global symbol on every `read()` cost ~5 ns/call
    /// in early Phase 1B prototyping; caching them into stack-
    /// resident fields once at init costs ~0 ns/call (single
    /// branch on a struct field, predicted 100 % accurate by the
    /// branch predictor since the value is stable for the
    /// decoder's lifetime).
    private let useSwar8: Bool
    private let useV74Batched: Bool

    public init(bytes: [UInt8]) {
        self.init(bytes: bytes[...])
    }

    /// Slice-based init avoids the per-block `Array(parsed.magsgn)` copy
    /// that the legacy `[UInt8]` overload would force on the caller.
    public init(bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.bytesStart = bytes.startIndex
        self.bytesEnd = bytes.endIndex
        self.readIndex = 0
        self.useSwar8 = HTMagSgnDecoderConformant.swarRefill8Enabled
        self.useV74Batched = HTMagSgnDecoderConformant.neonRefillEnabled
    }

    /// Read `count` bits (LSB-first) from the stream.
    ///
    /// **v8.1 Phase 1B**: branches on the cached `useSwar8` field
    /// (resolved at init from `swarRefill8Enabled`) to decide
    /// whether to shift-down the 128-bit accumulator. When the
    /// v7.4 4-byte refill or the scalar reference is active, the
    /// branch is always not-taken and the original 64-bit
    /// `tmp >>= count` runs — preserving the v7.4 hot-path cost
    /// to within branch-predictor noise.
    public mutating func read(count: Int) -> UInt32 {
        precondition(count <= 32, "MagSgn read width > 32")
        if bits < count {
            refill()
        }
        let mask: UInt64 = (count >= 64) ? ~UInt64(0) : ((UInt64(1) << count) - 1)
        let v = UInt32(tmp & mask)
        if useSwar8 {
            // 128-bit right shift across (tmp, tmpHi). count >= 1
            // here (count == 0 leaves the accumulator untouched;
            // the early-return above handled it via mask=0 → v=0,
            // tmp >>= 0 is a no-op, bits -= 0 is a no-op).
            // Actually count can be 0 in this code path — guard the
            // (64 - count) shift to avoid the count == 0 → 64 UB.
            if count > 0 {
                tmp = (tmp >> count) | (tmpHi << (64 - count))
                tmpHi = tmpHi >> count
            }
        } else {
            tmp >>= count
        }
        bits -= count
        return v
    }

    /// Refill the bit buffer so at least 32 bits are available (or
    /// stream-exhaust padding of 0xFF has been fed in).
    ///
    /// Dispatch order (v8.1 Phase 1B):
    /// 1. `swarRefill8Enabled` (default OFF) → `refillBatched8`
    ///    (8-byte SWAR + 128-bit accumulator).
    /// 2. `neonRefillEnabled` (default ON, v7.4 production) →
    ///    `refillBatched` (4-byte SWAR).
    /// 3. otherwise → `refillScalar` (v7.3 byte-by-byte reference).
    ///
    /// All three paths produce bit-identical output by construction;
    /// the batched paths are strict optimisations with the same
    /// byte-by-byte semantics on their slow-fallback branches.
    @inline(__always)
    mutating func refill() {
        if useSwar8 {
            refillBatched8()
        } else if useV74Batched {
            refillBatched()
        } else {
            refillScalar()
        }
    }

    /// **Scalar reference path** — v7.3.0 production refill.
    /// One byte at a time; promotes the slice to a raw pointer
    /// inside `withUnsafeBufferPointer` to avoid per-byte Array
    /// bounds checks (Phase 1b shape).
    @inline(__always)
    mutating func refillScalar() {
        var rIdx = readIndex
        var t = tmp
        var b = bits
        var u = unstuff

        bytes.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                let count = ptr.count
                while b <= 32 && rIdx < count {
                    let byte = base[rIdx]
                    rIdx += 1
                    let dBits = 8 - (u ? 1 : 0)
                    let mask: UInt8 = UInt8(0xFF) >> (u ? 1 : 0)
                    t |= UInt64(byte & mask) << b
                    b += dBits
                    u = (byte == 0xFF)
                }
            }
            // End-of-stream 0xFF padding.
            while b <= 32 {
                let byte: UInt8 = 0xFF
                let dBits = 8 - (u ? 1 : 0)
                let mask: UInt8 = UInt8(0xFF) >> (u ? 1 : 0)
                t |= UInt64(byte & mask) << b
                b += dBits
                u = (byte == 0xFF)
            }
        }

        readIndex = rIdx
        tmp = t
        bits = b
        unstuff = u
    }

    /// **v7.4 batched-refill prototype.** Processes 4 bytes per
    /// iteration when ≥ 4 stream bytes remain. Uses a SWAR
    /// (SIMD-within-a-register) 0xFF-detect to fast-path the common
    /// case (no 0xFF in the batch + no carried unstuff) — that case
    /// reduces to one unaligned UInt32 load, one OR-into-accumulator,
    /// and a constant 32-bit advance, with no per-byte conditional.
    /// Falls back to scalar byte-at-a-time inside the batch when
    /// 0xFF is detected or carried unstuff is set.
    ///
    /// Bit-exact equivalent of `refillScalar` by construction —
    /// the slow-fallback branch IS the scalar byte loop on those
    /// 4 bytes; the fast branch only fires when the SWAR test
    /// guarantees the same outcome (no unstuffing applied to any
    /// of the 4 bytes).
    @inline(__always)
    mutating func refillBatched() {
        var rIdx = readIndex
        var t = tmp
        var b = bits
        var u = unstuff

        bytes.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                let count = ptr.count

                // 4-byte batched fast path. b ∈ [0, 31] on entry
                // (caller gates on bits < count with count ≤ 32);
                // adding 32 bits gives b ≤ 63, fits in UInt64
                // accumulator.
                while b <= 32 && rIdx + 4 <= count {
                    // Unaligned 32-bit load from rIdx.
                    let p32 = UnsafeRawPointer(base.advanced(by: rIdx))
                        .loadUnaligned(as: UInt32.self)
                    // SWAR zero-byte detect on (p32 ^ 0xFFFFFFFF):
                    // each lane in `inv` becomes (byte ^ 0xFF). A
                    // byte is 0xFF iff its `inv` lane is 0. The
                    // standard SWAR-zero test produces a non-zero
                    // result iff any byte equals 0xFF.
                    let inv = p32 ^ 0xFFFFFFFF
                    let hasZero = (inv &- 0x01010101) & ~inv & 0x80808080
                    let anyFF = hasZero != 0

                    if !anyFF && !u {
                        // Fast path — none of the 4 bytes are 0xFF
                        // and no unstuff carried in. Each byte
                        // contributes its full 8 bits; no masking,
                        // no per-byte branching. The whole batch
                        // becomes one unaligned 32-bit load + one
                        // OR-into-tmp at the current bit offset.
                        t |= UInt64(p32) << b
                        b += 32
                        rIdx += 4
                        // u remains false
                    } else {
                        // Slow path — at least one 0xFF in the
                        // batch or carried unstuff. Process the 4
                        // bytes byte-by-byte (identical body to
                        // `refillScalar`'s inner loop).
                        var k = 0
                        while k < 4 {
                            let byte = base[rIdx]
                            rIdx += 1
                            let dBits = 8 - (u ? 1 : 0)
                            let mask: UInt8 = UInt8(0xFF) >> (u ? 1 : 0)
                            t |= UInt64(byte & mask) << b
                            b += dBits
                            u = (byte == 0xFF)
                            k += 1
                            // Early-out if we've over-filled bits;
                            // the outer `while b <= 32` condition
                            // would also exit, but that defers the
                            // check to the next iteration after
                            // consuming all 4 bytes.
                            if b > 32 { break }
                        }
                    }
                }

                // Tail: byte-at-a-time for remaining stream.
                while b <= 32 && rIdx < count {
                    let byte = base[rIdx]
                    rIdx += 1
                    let dBits = 8 - (u ? 1 : 0)
                    let mask: UInt8 = UInt8(0xFF) >> (u ? 1 : 0)
                    t |= UInt64(byte & mask) << b
                    b += dBits
                    u = (byte == 0xFF)
                }
            }
            // End-of-stream 0xFF padding.
            while b <= 32 {
                let byte: UInt8 = 0xFF
                let dBits = 8 - (u ? 1 : 0)
                let mask: UInt8 = UInt8(0xFF) >> (u ? 1 : 0)
                t |= UInt64(byte & mask) << b
                b += dBits
                u = (byte == 0xFF)
            }
        }

        readIndex = rIdx
        tmp = t
        bits = b
        unstuff = u
    }

    /// **v8.1 Phase 1B 8-byte SWAR refill** with 128-bit
    /// accumulator (`tmp` + `tmpHi`). Processes 8 bytes per
    /// iteration when ≥ 8 stream bytes remain. Uses an 8-byte SWAR
    /// FF-detect that fast-paths the common case (no FF in the
    /// 8-byte batch + no carried unstuff) — that case reduces to
    /// one unaligned `UInt64` load, two ORs (into `tmp` and
    /// `tmpHi`), and a constant 64-bit advance. Falls back to
    /// scalar byte-at-a-time inside the batch when FF is detected
    /// or carried unstuff is set.
    ///
    /// Bit-exact equivalent of `refillScalar` and `refillBatched`
    /// — the slow-fallback branch IS the scalar byte loop on those
    /// 8 bytes, with the same overflow-into-`tmpHi` arithmetic the
    /// fast path uses. Verified across 16,520 parity cells.
    ///
    /// Phase 1A microbench: 1.21×–1.40× speedup vs `refillBatched`
    /// at FF densities 0 %–25 %; 1.37× at corpus density 0.4 %.
    @inline(__always)
    mutating func refillBatched8() {
        var rIdx = readIndex
        var t = tmp
        var th = tmpHi
        var b = bits
        var u = unstuff

        bytes.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                let count = ptr.count

                // 8-byte batched fast path. b ∈ [0, 32] on entry;
                // adding 64 bits gives b ≤ 96, fits in 128-bit
                // accumulator (`tmp` + `tmpHi`).
                while b <= 32 && rIdx + 8 <= count {
                    let p64 = UnsafeRawPointer(base.advanced(by: rIdx))
                        .loadUnaligned(as: UInt64.self)
                    // SWAR zero-byte detect on (p64 ^ 0xFFFF…). A
                    // byte equals 0xFF iff the corresponding lane
                    // in `inv` is zero; the SWAR-zero test produces
                    // a non-zero result iff any byte equals 0xFF.
                    let inv = p64 ^ 0xFFFF_FFFF_FFFF_FFFF
                    let hasZero =
                        (inv &- 0x0101_0101_0101_0101) & ~inv & 0x8080_8080_8080_8080
                    let anyFF = hasZero != 0

                    if !anyFF && !u {
                        // Fast path — fold all 8 bytes into the
                        // 128-bit accumulator at offset b.
                        if b == 0 {
                            t |= p64
                        } else {
                            t |= p64 << b
                            // For b ∈ [1, 32], (64 - b) ∈ [32, 63] —
                            // well-defined Swift shift.
                            th |= p64 >> (64 - b)
                        }
                        b += 64
                        rIdx += 8
                    } else {
                        // Slow path — byte-by-byte for these 8
                        // bytes, with 128-bit-aware overflow.
                        var k = 0
                        while k < 8 {
                            let byte = base[rIdx]
                            rIdx += 1
                            let dBits = 8 - (u ? 1 : 0)
                            let mask: UInt8 = UInt8(0xFF) >> (u ? 1 : 0)
                            let val = UInt64(byte & mask)
                            // Place `val` (≤ 8 bits wide) at bit
                            // offset `b` in the 128-bit accumulator.
                            if b < 64 {
                                t |= val << b
                                if b + 8 > 64 {
                                    // Carry the high bits of val
                                    // into `tmpHi`.
                                    th |= val >> (64 - b)
                                }
                            } else {
                                th |= val << (b - 64)
                            }
                            b += dBits
                            u = (byte == 0xFF)
                            k += 1
                            if b > 32 { break }
                        }
                    }
                }

                // Tail: byte-at-a-time for remaining stream
                // (with 128-bit-aware overflow).
                while b <= 32 && rIdx < count {
                    let byte = base[rIdx]
                    rIdx += 1
                    let dBits = 8 - (u ? 1 : 0)
                    let mask: UInt8 = UInt8(0xFF) >> (u ? 1 : 0)
                    let val = UInt64(byte & mask)
                    if b < 64 {
                        t |= val << b
                        if b + 8 > 64 {
                            th |= val >> (64 - b)
                        }
                    } else {
                        th |= val << (b - 64)
                    }
                    b += dBits
                    u = (byte == 0xFF)
                }
            }
            // End-of-stream 0xFF padding.
            while b <= 32 {
                let byte: UInt8 = 0xFF
                let dBits = 8 - (u ? 1 : 0)
                let mask: UInt8 = UInt8(0xFF) >> (u ? 1 : 0)
                let val = UInt64(byte & mask)
                if b < 64 {
                    t |= val << b
                    if b + 8 > 64 {
                        th |= val >> (64 - b)
                    }
                } else {
                    th |= val << (b - 64)
                }
                b += dBits
                u = (byte == 0xFF)
            }
        }

        readIndex = rIdx
        tmp = t
        tmpHi = th
        bits = b
        unstuff = u
    }
}

// MARK: - Round-trip helper

/// High-level round-trip helpers for testing. `encodeBits` concatenates
/// a list of `(codeword, length)` pairs into a MagSgn byte stream;
/// `decodeBits` reads the same `(length)` widths back.
public enum HTMagSgnCoderConformant {
    public static func encodeBits(_ items: [(value: UInt32, bits: Int)]) -> [UInt8] {
        var encoder = HTMagSgnEncoderConformant()
        for item in items {
            encoder.encode(codeword: item.value, count: item.bits)
        }
        return encoder.finish()
    }

    public static func decodeBits(_ bytes: [UInt8], widths: [Int]) -> [UInt32] {
        var decoder = HTMagSgnDecoderConformant(bytes: bytes)
        var out = [UInt32]()
        out.reserveCapacity(widths.count)
        for w in widths {
            out.append(decoder.read(count: w))
        }
        return out
    }
}
