// J2KHTConformantRawPointerEngines.swift
//
// v9.1 Path B Phase 2c — production raw-pointer engine variants.
//
// Mirror the Array-backed engines (HTMagSgnEncoderConformant,
// HTMELEncoderConformant, HTReverseBitEmitterConformant) but write
// bytes into a caller-owned `UnsafeMutableBufferPointer<UInt8>` instead
// of a Swift `[UInt8]`. Eliminates per-byte `Array.append` ARC and
// capacity-grow tax that contends across concurrent TaskGroup workers
// (measured: 5× per-block wall inflation at 6+ workers on M2; raw
// variant scales near-linearly).
//
// Bit-exact equivalent of the Array engines — verified by 200-trial
// random sweep in V91Phase2aRawPointerPrototype and 100-trial sweep
// in V91Phase2bAllEnginesRawPrototype. Codestream byte-identical.
//
// Buffer ownership: the caller (typically J2KEncoderPipeline) allocates
// one buffer per worker, passes a pointer in. The engine writes via
// `buf[idx]` and increments `idx`. `finishCount()` returns the byte
// count; caller copies to its final destination.
//
// Sizing: HT block output is bounded by codestream-spec block-size
// limits. For 64×64 blocks at 30-bit precision, max MagSgn output is
// ~12 KB, MEL ~512 B, VLC ~12 KB. 16 KB buffers per engine are safe.

import Foundation

// MARK: - Protocols (shared by Array + Raw variants)

/// The MagSgn encoder operations used inside HTBlockEncoderConformant's
/// loop body. Both Array-backed (HTMagSgnEncoderConformant) and
/// raw-pointer-backed (HTMagSgnEncoderRawConformant) types conform,
/// so the encode-loop body can be made generic over the storage strategy.
///
/// The protocol intentionally does NOT include `finish()` — Array and
/// Raw variants have asymmetric finalization semantics (Array allocates
/// + returns `[UInt8]`, Raw returns an `Int` count and the caller owns
/// the buffer). Forcing them into a unified `finish() -> [UInt8]`
/// signature would defeat the purpose of the raw-pointer variant
/// (it would allocate an Array on every block). The encode-loop core
/// is generic; the outer encode wrappers call each variant's
/// type-specific finalization API explicitly.
public protocol HTMagSgnEmitting {
    mutating func reset()
    mutating func encode(codeword: UInt32, count: Int)
    /// v9.3 Path B Phase 3 — batched 64-bit emit for the per-quad
    /// `emitQuadMagSgn` packed-codeword path. Both Array and Raw
    /// variants implement bit-exact equivalents.
    mutating func encode64(codeword: UInt64, count: Int)
}

/// The MEL encoder operations used inside HTBlockEncoderConformant's
/// loop body. (See HTMagSgnEmitting docs for the finalization rationale.)
public protocol HTMELEmitting {
    mutating func reset()
    mutating func encode(eventIsOne: Bool)
}

/// The reverse-VLC encoder operations used inside HTBlockEncoderConformant's
/// loop body. (See HTMagSgnEmitting docs for the finalization rationale.)
public protocol HTVLCEmitting {
    mutating func reset()
    mutating func encode(codeword: Int, count: Int)
}

// Array-backed engines already implement these methods — conform via
// empty extension declarations.
extension HTMagSgnEncoderConformant: HTMagSgnEmitting {}
extension HTMELEncoderConformant: HTMELEmitting {}
extension HTReverseBitEmitterConformant: HTVLCEmitting {}

// Raw-pointer engines conform inline below.

// MARK: - MagSgn raw-pointer encoder

/// MagSgn forward bit emitter using a caller-owned raw buffer. Bit-
/// exact mirror of `HTMagSgnEncoderConformant`.
public struct HTMagSgnEncoderRawConformant: HTMagSgnEmitting {
    @usableFromInline let buf: UnsafeMutablePointer<UInt8>
    @usableFromInline let capacity: Int
    @usableFromInline var idx: Int = 0
    @usableFromInline var tmp: UInt32 = 0
    @usableFromInline var usedBits: Int = 0
    @usableFromInline var maxBits: Int = 8

    public init(buf: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.buf = buf
        self.capacity = capacity
    }

    public mutating func reset() {
        idx = 0
        tmp = 0
        usedBits = 0
        maxBits = 8
    }

    @inline(__always)
    public mutating func encode(codeword: UInt32, count: Int) {
        J2KHTEntropyEncoderProfile.bumpMagsgnEncode(count)
        // v9.2 Phase 2a fast path (mirrors Array variant).
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

    /// v9.3 Path B Phase 3 — wide-codeword MagSgn emit; mirrors
    /// `HTMagSgnEncoderConformant.encode64` for the raw-pointer path.
    /// Bit-exact equivalent.
    @inline(__always)
    public mutating func encode64(codeword: UInt64, count: Int) {
        J2KHTEntropyEncoderProfile.bumpMagsgnEncode(count)
        if count == 0 { return }
        let avail = maxBits - usedBits
        if count < avail {
            let mask: UInt64 = (UInt64(1) << count) - 1
            tmp |= UInt32(codeword & mask) << usedBits
            usedBits += count
            return
        }
        var cwd64 = codeword
        var len = count
        while len > 32 {
            let take = maxBits - usedBits
            let mask: UInt64 = (UInt64(1) << take) - 1
            tmp |= UInt32(cwd64 & mask) << usedBits
            usedBits += take
            cwd64 >>= take
            len -= take
            if usedBits >= maxBits {
                let byte = UInt8(tmp & 0xFF)
                buf[idx] = byte
                idx &+= 1
                maxBits = (byte == 0xFF) ? 7 : 8
                tmp = 0
                usedBits = 0
            }
        }
        var cwd = UInt32(cwd64 & 0xFFFFFFFF)
        encodeInternal(cwd: &cwd, len: len)
    }

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
                buf[idx] = byte
                idx &+= 1
                maxBits = (byte == 0xFF) ? 7 : 8
                tmp = 0
                usedBits = 0
            }
        }
    }

    /// Flush final partial byte. Mirrors `HTMagSgnEncoderConformant.finish()`.
    /// Returns the count of valid bytes in `buf[0..<count]`.
    public mutating func finishCount() -> Int {
        if usedBits != 0 {
            let padBits = maxBits - usedBits
            let padMask: UInt32 = (padBits >= 32) ? ~UInt32(0)
                                                  : ((UInt32(1) << padBits) - 1)
            tmp |= padMask << usedBits
            let byte = UInt8(tmp & 0xFF)
            if byte != 0xFF {
                buf[idx] = byte
                idx &+= 1
            }
            tmp = 0
            usedBits = 0
            maxBits = 8
        } else if maxBits == 7 {
            // ms_terminate: rollback over-committed byte slot.
            idx &-= 1
            maxBits = 8
        }
        return idx
    }
}

// MARK: - Forward bit emitter (MEL underlying)

/// Forward bit emitter using a caller-owned raw buffer. Bit-exact
/// mirror of `HTForwardBitEmitterConformant`.
public struct HTForwardBitEmitterRawConformant {
    @usableFromInline let buf: UnsafeMutablePointer<UInt8>
    @usableFromInline let capacity: Int
    @usableFromInline var idx: Int = 0
    @usableFromInline var tmp: Int = 0
    @usableFromInline var remainingBits: Int = 8

    public init(buf: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.buf = buf
        self.capacity = capacity
    }

    public mutating func reset() {
        idx = 0
        tmp = 0
        remainingBits = 8
    }

    @inline(__always)
    public mutating func emit(bit: Int) {
        tmp = (tmp << 1) | (bit & 1)
        remainingBits -= 1
        if remainingBits == 0 {
            let byte = UInt8(tmp & 0xFF)
            buf[idx] = byte
            idx &+= 1
            remainingBits = (byte == 0xFF) ? 7 : 8
            tmp = 0
        }
    }

    public mutating func finishCount() -> Int {
        if remainingBits != 8 {
            tmp <<= remainingBits
            buf[idx] = UInt8(tmp & 0xFF)
            idx &+= 1
            tmp = 0
            remainingBits = 8
        }
        return idx
    }
}

// MARK: - MEL encoder using raw-pointer forward emitter

/// MEL encoder using a caller-owned raw buffer. Bit-exact mirror of
/// `HTMELEncoderConformant`.
public struct HTMELEncoderRawConformant: HTMELEmitting {
    @usableFromInline var emitter: HTForwardBitEmitterRawConformant
    @usableFromInline var state: Int = 0
    @usableFromInline var run: Int = 0
    @usableFromInline var threshold: Int = 1

    public init(buf: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.emitter = HTForwardBitEmitterRawConformant(buf: buf, capacity: capacity)
    }

    public mutating func reset() {
        emitter.reset()
        state = 0
        run = 0
        threshold = 1
    }

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

    public mutating func finishCount() -> Int {
        if run > 0 {
            emitter.emit(bit: 1)
        }
        return emitter.finishCount()
    }
}

// MARK: - Reverse bit emitter (VLC)

/// Reverse bit emitter using a caller-owned raw buffer. Bit-exact
/// mirror of `HTReverseBitEmitterConformant`. The buffer holds bytes
/// in the same `emittedReversed` order as the Array variant; the
/// caller is responsible for reversing to forward on-wire byte order
/// via `Array(UnsafeBufferPointer(start: buf, count: idx)).reversed()`.
public struct HTReverseBitEmitterRawConformant: HTVLCEmitting {
    @usableFromInline let buf: UnsafeMutablePointer<UInt8>
    @usableFromInline let capacity: Int
    @usableFromInline var idx: Int = 1  // [0]=0xFF sentinel
    @usableFromInline var tmp: Int = 0x0F
    @usableFromInline var usedBits: Int = 4
    @usableFromInline var lastGreaterThan8F: Bool = true

    public init(buf: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.buf = buf
        self.capacity = capacity
        buf[0] = 0xFF
    }

    public mutating func reset() {
        idx = 1
        buf[0] = 0xFF
        tmp = 0x0F
        usedBits = 4
        lastGreaterThan8F = true
    }

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
            let remainingAfter = availBits - take
            if remainingAfter == 0 {
                if lastGreaterThan8F && tmp != 0x7F {
                    lastGreaterThan8F = false
                    continue
                }
                buf[idx] = UInt8(tmp & 0xFF)
                idx &+= 1
                lastGreaterThan8F = tmp > 0x8F
                tmp = 0
                usedBits = 0
            }
        }
    }

    /// Returns the byte count in `emittedReversed` order (sentinel-first).
    /// Caller reverses to get the forward on-wire byte order.
    public mutating func finishCount() -> Int {
        if usedBits > 0 {
            buf[idx] = UInt8(tmp & 0xFF)
            idx &+= 1
            tmp = 0
            usedBits = 0
        }
        return idx
    }
}
