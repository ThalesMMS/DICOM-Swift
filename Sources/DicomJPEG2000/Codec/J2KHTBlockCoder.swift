//
// J2KHTBlockCoder.swift
// J2KSwift
//
/// # HTJ2K Block Coder
///
/// Implementation of the FBCOT (Fast Block Coder with Optimised Truncation) algorithm
/// for HTJ2K (High-Throughput JPEG 2000) as specified in ISO/IEC 15444-15.
///
/// The HT block coder replaces the traditional EBCOT Tier-1 coding with a significantly
/// faster algorithm that uses three distinct coding primitives:
/// - **MEL (Modular Embedded Length)**: Run-length coding for significance context
/// - **VLC (Variable Length Coding)**: Fixed-to-variable coding for significance/sign
/// - **MagSgn (Magnitude and Sign)**: Raw magnitude and sign bits
///
/// ## Topics
///
/// ### Coding Primitives
/// - ``HTMELCoder``
/// - ``HTVLCCoder``
/// - ``HTMagSgnCoder``
///
/// ### Block Coding
/// - ``HTBlockEncoder``
/// - ``HTBlockDecoder``

import Foundation

// MARK: - HT Coding Mode

/// Identifies whether a code-block uses legacy EBCOT or HTJ2K block coding.
///
/// ISO/IEC 15444-15 allows mixed codestreams where some code-blocks use legacy
/// JPEG 2000 coding and others use the HT block coder within the same tile.
enum HTCodingMode: Sendable, Equatable {
    /// Legacy JPEG 2000 Part 1 EBCOT block coding.
    case legacy

    /// High-Throughput JPEG 2000 (Part 15) FBCOT block coding.
    case ht
}

// MARK: - HT Coding Pass

/// The type of coding pass in HTJ2K block coding.
///
/// The HT block coder uses a different set of passes compared to legacy EBCOT.
/// The cleanup pass is the primary coding pass, while SigProp and MagRef
/// provide refinement for progressive quality.
enum HTCodingPassType: Sendable, Equatable {
    /// HT cleanup pass — the primary pass encoding significance, sign, and magnitude.
    ///
    /// Uses MEL, VLC, and MagSgn coding primitives.
    case htCleanup

    /// HT significance propagation pass.
    ///
    /// Encodes newly significant samples found during refinement.
    case htSigProp

    /// HT magnitude refinement pass.
    ///
    /// Refines the magnitude of already-significant samples.
    case htMagRef
}

// MARK: - Fast Bit Writer

/// High-throughput bit writer using a 64-bit word accumulator.
///
/// Replaces the per-bit `emitBit()` + per-byte `buffer.append()` pattern
/// with bulk word-level writes. The 64-bit accumulator can hold up to 56 bits
/// before flushing, allowing multi-bit operations without per-byte branches.
///
/// Pre-allocates the output buffer to worst-case size, eliminating dynamic
/// array growth during encoding.
///
/// Uses `UnsafeMutableRawPointer` for direct memory access, eliminating
/// Swift Array bounds-check overhead. The 32-bit flush compiles to a
/// single ARM64 `STR W` + `REV W` instead of 4 separate `STRB` stores.
struct HTFastBitWriter: @unchecked Sendable {
    // @unchecked Sendable: buffer is exclusively owned by this value type —
    // no shared mutable state. UnsafeMutableRawPointer is not Sendable but
    // the struct has value semantics (copied on assignment).

    /// Raw output buffer (unmanaged heap allocation).
    private var buffer: UnsafeMutableRawPointer

    /// Allocated capacity of the buffer in bytes.
    private var bufferCapacity: Int

    /// Current write position in the buffer.
    private var pos: Int = 0

    /// 64-bit bit accumulator — bits are packed MSB-first from bit 63 down.
    private var accum: UInt64 = 0

    /// Number of valid bits in the accumulator (0..63).
    private var bits: Int = 0

    /// Creates a fast bit writer with a pre-allocated buffer.
    ///
    /// - Parameter capacity: Maximum number of bytes the output can contain.
    ///   Four extra bytes are allocated to allow safe 32-bit word writes
    ///   near the end of the buffer without bounds-check overhead.
    init(capacity: Int) {
        bufferCapacity = capacity + 4
        buffer = .allocate(byteCount: bufferCapacity, alignment: 4)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bufferCapacity)
    }

    /// Emits 1 to 32 bits from the MSB side of `value`.
    ///
    /// - Parameters:
    ///   - value: The bits to emit (right-aligned, MSB first).
    ///   - count: Number of bits to emit (1..32).
    @inline(__always)
    mutating func emitBits(_ value: Int, count: Int) {
        // Shift value into the top of accum, just below existing bits
        accum |= UInt64(value & ((1 << count) - 1)) << (64 - bits - count)
        bits += count
        // Flush 4 bytes at once when accumulator has ≥ 32 bits.
        // Buffer is allocated with +4 padding so this is always safe.
        if bits >= 32 {
            // Single 32-bit big-endian store (ARM64: REV W + STR W)
            buffer.storeBytes(
                of: UInt32(accum >> 32).bigEndian,
                toByteOffset: pos, as: UInt32.self
            )
            pos += 4
            accum <<= 32
            bits -= 32
        }
    }

    /// Emits a single bit.
    @inline(__always)
    mutating func emitBit(_ bit: Int) {
        emitBits(bit, count: 1)
    }

    /// Flushes any remaining bits (zero-padded) and returns the output as Data.
    mutating func flush() -> Data {
        // Drain all complete and partial bytes from the accumulator.
        // With 32-bit flush in emitBits, up to 31 bits may remain.
        let ptr = buffer.assumingMemoryBound(to: UInt8.self)
        while bits > 0 {
            ptr[pos] = UInt8((accum >> 56) & 0xFF)
            pos += 1
            accum <<= 8
            bits -= 8
        }
        bits = 0
        accum = 0
        return Data(bytes: buffer, count: pos)
    }

    /// Returns the number of bytes written so far (including partial bytes in accumulator).
    var byteCount: Int { pos + (bits > 0 ? (bits + 7) / 8 : 0) }

    /// Resets the writer for reuse without reallocating the buffer.
    ///
    /// The existing buffer is kept if large enough; only the write position
    /// and accumulator are cleared. If `capacity` exceeds the current buffer
    /// size, the buffer is grown.
    ///
    /// - Parameter capacity: The minimum buffer capacity needed.
    @inline(__always)
    mutating func reset(capacity: Int) {
        let needed = capacity + 4
        if bufferCapacity < needed {
            buffer.deallocate()
            bufferCapacity = needed
            buffer = .allocate(byteCount: needed, alignment: 4)
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: needed)
        }
        pos = 0
        accum = 0
        bits = 0
    }

    /// Flushes remaining bits and copies output directly to a destination pointer.
    ///
    /// Avoids creating an intermediate `Data` object — the output bytes are
    /// written directly to `dest`, which must have room for at least `byteCount`
    /// bytes.
    ///
    /// - Parameter dest: Destination pointer with room for at least `byteCount` bytes.
    /// - Returns: The number of bytes written.
    @inline(__always)
    @discardableResult
    mutating func flushTo(_ dest: UnsafeMutablePointer<UInt8>) -> Int {
        let ptr = buffer.assumingMemoryBound(to: UInt8.self)
        while bits > 0 {
            ptr[pos] = UInt8((accum >> 56) & 0xFF)
            pos += 1
            accum <<= 8
            bits -= 8
        }
        bits = 0
        accum = 0
        dest.update(from: buffer.assumingMemoryBound(to: UInt8.self), count: pos)
        return pos
    }

    /// Flushes remaining bits and copies output in reversed order to a destination.
    ///
    /// Used for VLC data which is stored reversed in the HT coded data format.
    ///
    /// - Parameter dest: Destination pointer with room for at least `byteCount` bytes.
    /// - Returns: The number of bytes written.
    @inline(__always)
    @discardableResult
    mutating func flushToReversed(_ dest: UnsafeMutablePointer<UInt8>) -> Int {
        let ptr = buffer.assumingMemoryBound(to: UInt8.self)
        while bits > 0 {
            ptr[pos] = UInt8((accum >> 56) & 0xFF)
            pos += 1
            accum <<= 8
            bits -= 8
        }
        bits = 0
        accum = 0
        let base = buffer.assumingMemoryBound(to: UInt8.self)
        for i in 0..<pos {
            dest[i] = base[pos - 1 - i]
        }
        return pos
    }

    /// Flushes remaining bits and appends the output directly to a Data buffer.
    ///
    /// More efficient than `flush()` when combining multiple writers into a larger
    /// buffer — avoids creating an intermediate Data object per writer.
    ///
    /// - Parameter data: The Data buffer to append output bytes to.
    /// - Returns: The number of bytes appended.
    @inline(__always)
    @discardableResult
    mutating func flushAppending(to data: inout Data) -> Int {
        let ptr = buffer.assumingMemoryBound(to: UInt8.self)
        while bits > 0 {
            ptr[pos] = UInt8((accum >> 56) & 0xFF)
            pos += 1
            accum <<= 8
            bits -= 8
        }
        bits = 0
        accum = 0
        data.append(buffer.assumingMemoryBound(to: UInt8.self), count: pos)
        return pos
    }
}

// MARK: - MEL Coder

/// Modular Embedded Length coder for HTJ2K.
///
/// The MEL coder is a run-length coder that compresses runs of zero-context
/// significance decisions in the HT cleanup pass. It adaptively adjusts the
/// run length threshold based on the observed data.
///
/// The MEL encoder produces a byte stream that grows from the beginning of the
/// coded data buffer, while the VLC stream grows from the end.
struct HTMELCoder: Sendable {
    /// Current run count.
    private var run: Int = 0

    /// Whether the next decode call should return 1 (significant).
    ///
    /// Set after consuming a terminated run of zeros — the significant
    /// decision that caused the run termination is delivered on the next call.
    private var pendingSignificant: Bool = false

    /// Current run-length threshold (number of zeros to emit a 0 MEL bit).
    private var threshold: Int = 0

    /// MEL state index for adaptive threshold selection.
    private var stateIndex: Int = 0

    /// High-throughput bit writer for MEL output.
    private var writer: HTFastBitWriter

    /// Bit accumulator for partial byte during decoding.
    private var bitBuffer: UInt32 = 0

    /// Number of valid bits in the bit accumulator (decode only).
    private var bitCount: Int = 0

    /// MEL threshold table for adaptive run-length selection.
    ///
    /// Each entry is a power-of-2 run threshold: 2^t[i].
    private static let thresholdTable: [Int] = [
        0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5, 6, 7, 8
    ]

    /// Creates a new MEL coder.
    ///
    /// - Parameter capacity: Pre-allocated output buffer size in bytes.
    init(capacity: Int = 256) {
        writer = HTFastBitWriter(capacity: capacity)
    }

    /// Resets the MEL coder for reuse without reallocating the buffer.
    @inline(__always)
    mutating func reset(capacity: Int) {
        run = 0
        pendingSignificant = false
        threshold = 0
        stateIndex = 0
        bitBuffer = 0
        bitCount = 0
        writer.reset(capacity: capacity)
    }

    /// Encodes a single context decision (0 = insignificant, 1 = significant).
    ///
    /// - Parameter bit: The context decision bit.
    @inline(__always)
    mutating func encode(bit: Int) {
        if bit == 0 {
            run += 1
            let limit = 1 << Self.thresholdTable[stateIndex]
            if run >= limit {
                writer.emitBit(0)
                run = 0
                if stateIndex < Self.thresholdTable.count - 1 {
                    stateIndex += 1
                }
            }
        } else {
            writer.emitBit(1)
            let remainingBits = Self.thresholdTable[stateIndex]
            // Emit the run count using `remainingBits` bits in one call
            if remainingBits > 0 {
                writer.emitBits(run, count: remainingBits)
            }
            run = 0
            if stateIndex > 0 {
                stateIndex -= 1
            }
        }
    }

    /// Encodes N consecutive insignificant (zero) context decisions.
    ///
    /// Equivalent to calling `encode(bit: 0)` N times, but avoids per-element
    /// function call overhead. Advances the run counter in bulk and only calls
    /// into the writer when a run-length threshold is crossed.
    ///
    /// For a fully sparse code-block stripe (all 2048 pairs insignificant at the
    /// top bit-plane), this replaces O(N) encode calls with O(log₂N) emitBit
    /// calls (since the threshold table grows geometrically).
    ///
    /// - Parameter n: Number of consecutive insignificant pairs to encode.
    @inline(__always)
    mutating func encodeZeroRun(_ n: Int) {
        var remaining = n
        while remaining > 0 {
            let limit = 1 << Self.thresholdTable[stateIndex]
            let roomLeft = limit &- run   // zeros remaining before threshold crossed
            if remaining < roomLeft {
                run &+= remaining
                return
            }
            // Fill run to threshold: emit a 0 MEL bit, advance state
            remaining &-= roomLeft
            writer.emitBit(0)
            run = 0
            if stateIndex < Self.thresholdTable.count - 1 {
                stateIndex &+= 1
            }
        }
    }

    /// The number of output bytes (including any partial byte in the accumulator).
    var byteCount: Int { writer.byteCount }

    /// Flushes any remaining data in the MEL coder.
    ///
    /// - Returns: The MEL-encoded byte stream.
    mutating func flush() -> Data {
        // Do NOT emit a run-completion bit for a partial trailing run.
        // The decoder handles an exhausted MEL reader by falling back to VLC,
        // which correctly returns pattern 0 (neither significant) for the
        // trailing insignificant pairs.
        return writer.flush()
    }

    /// Flushes and copies output directly to a destination pointer.
    @inline(__always)
    @discardableResult
    mutating func flushTo(_ dest: UnsafeMutablePointer<UInt8>) -> Int {
        writer.flushTo(dest)
    }

    /// Decodes a single context decision from MEL-encoded data.
    ///
    /// A MEL "1" bit signals a terminated run: `runLength` insignificant pairs
    /// followed by one significant pair. The decoder delivers `runLength` zeros
    /// then one "1". The `pendingSignificant` flag tracks the deferred "1".
    ///
    /// - Parameter reader: The bit reader positioned at MEL data.
    /// - Returns: The decoded context decision (0 or 1).
    /// - Throws: ``J2KError/decodingError(_:)`` if decoding fails.
    mutating func decode(from reader: inout J2KBitReader) throws -> Int {
        // Consume remaining zeros from a run BEFORE delivering
        // the pending significant decision. A terminated MEL run
        // encodes N zeros followed by 1 significant — the run zeros
        // must all be delivered before the trailing significant.
        if run > 0 {
            run -= 1
            return 0
        }

        // Deliver the deferred significant decision after all run zeros
        if pendingSignificant {
            pendingSignificant = false
            return 1
        }

        guard reader.bytesRemaining > 0 || bitCount > 0 else {
            return 0
        }

        let bit = try readBit(from: &reader)
        if bit == 0 {
            // Complete run of `limit` insignificant pairs
            let limit = 1 << Self.thresholdTable[stateIndex]
            run = limit - 1  // this call consumes 1; remaining = limit-1
            if stateIndex < Self.thresholdTable.count - 1 {
                stateIndex += 1
            }
            return 0
        } else {
            // Terminated run: `runLength` zeros then 1 significant
            let remainingBits = Self.thresholdTable[stateIndex]
            var runLength = 0
            for _ in 0..<remainingBits {
                let b = try readBit(from: &reader)
                runLength = (runLength << 1) | b
            }
            if stateIndex > 0 {
                stateIndex -= 1
            }
            if runLength > 0 {
                run = runLength - 1  // this call consumes 1 zero
                pendingSignificant = true  // deliver "1" after the zeros
                return 0
            }
            return 1  // immediate significant (no preceding zeros)
        }
    }

    /// Reads a single bit from the reader.
    private mutating func readBit(from reader: inout J2KBitReader) throws -> Int {
        if bitCount <= 0 {
            guard reader.bytesRemaining > 0 else {
                return 0
            }
            let byte = try reader.readUInt8()
            bitBuffer = UInt32(byte) << 24
            bitCount = 8
        }
        let bit = Int((bitBuffer >> 31) & 1)
        bitBuffer <<= 1
        bitCount -= 1
        return bit
    }
}

// MARK: - VLC Coder

/// Variable Length Coder for HTJ2K.
///
/// The VLC coder uses a fixed-to-variable code mapping to encode significance
/// and sign information for pairs of samples (quad-pairs) in the HT cleanup pass.
/// The VLC stream is written from the end of the coded data buffer, growing toward
/// the beginning, while MEL data grows from the beginning.
struct HTVLCCoder: Sendable {
    /// High-throughput bit writer for VLC output.
    private var writer: HTFastBitWriter

    /// VLC table for significance pattern encoding (2 samples per entry).
    ///
    /// Maps significance patterns to (codeword, length) pairs.
    /// Pattern bits: [sig0, sig1] where sig=1 means sample is significant.
    private static let vlcTable: [(code: UInt8, length: Int)] = [
        (0b0, 1),     // pattern 0b00: neither significant
        (0b10, 2),    // pattern 0b01: second significant
        (0b110, 3),   // pattern 0b10: first significant
        (0b111, 3)    // pattern 0b11: both significant
    ]

    /// Creates a new VLC coder.
    ///
    /// - Parameter capacity: Pre-allocated output buffer size in bytes.
    init(capacity: Int = 256) {
        writer = HTFastBitWriter(capacity: capacity)
    }

    /// Resets the VLC coder for reuse without reallocating the buffer.
    @inline(__always)
    mutating func reset(capacity: Int) {
        writer.reset(capacity: capacity)
    }

    /// Encodes a significance pattern for a pair of samples.
    ///
    /// - Parameter pattern: A 2-bit significance pattern (0-3).
    @inline(__always)
    mutating func encodeSignificance(pattern: Int) {
        let clampedPattern = pattern & 0x03
        let entry = Self.vlcTable[clampedPattern]
        writer.emitBits(Int(entry.code), count: entry.length)
    }

    /// Encodes a sign bit (0 = positive, 1 = negative).
    ///
    /// - Parameter sign: The sign bit.
    @inline(__always)
    mutating func encodeSign(_ sign: Int) {
        writer.emitBit(sign & 1)
    }

    /// The number of output bytes (including any partial byte in the accumulator).
    var byteCount: Int { writer.byteCount }

    /// Flushes the VLC coder and returns the encoded data.
    ///
    /// - Returns: The VLC-encoded byte stream.
    mutating func flush() -> Data {
        return writer.flush()
    }

    /// Flushes and copies output in reversed order directly to a destination.
    @inline(__always)
    @discardableResult
    mutating func flushToReversed(_ dest: UnsafeMutablePointer<UInt8>) -> Int {
        writer.flushToReversed(dest)
    }

    /// Decodes a significance pattern from VLC-encoded data.
    ///
    /// - Parameter reader: The bit reader positioned at VLC data.
    /// - Returns: A 2-bit significance pattern.
    /// - Throws: ``J2KError/decodingError(_:)`` if decoding fails.
    func decodeSignificance(from reader: inout J2KBitReader) throws -> Int {
        guard reader.bytesRemaining > 0 || reader.position > 0 else {
            return 0
        }
        let firstBit = try readVLCBit(from: &reader)
        if firstBit == 0 {
            return 0  // Neither significant
        }
        let secondBit = try readVLCBit(from: &reader)
        if secondBit == 0 {
            return 1  // Second significant only
        }
        let thirdBit = try readVLCBit(from: &reader)
        if thirdBit == 0 {
            return 2  // First significant only
        }
        return 3  // Both significant
    }

    /// Reads a single VLC bit.
    private func readVLCBit(from reader: inout J2KBitReader) throws -> Int {
        guard reader.bytesRemaining > 0 else {
            return 0
        }
        return try reader.readBit() ? 1 : 0
    }
}

// MARK: - MagSgn Coder

/// Magnitude and Sign coder for HTJ2K.
///
/// The MagSgn coder encodes the magnitude and sign of significant wavelet
/// coefficients in the HT cleanup pass. It writes raw (uncompressed) bits
/// for the magnitude values and sign bits of samples identified as significant.
///
/// The magnitude is encoded as `|coefficient| - 1` using the number of bits
/// determined by the most significant bit position.
struct HTMagSgnCoder: Sendable {
    /// High-throughput bit writer for MagSgn output.
    private var writer: HTFastBitWriter

    /// Creates a new MagSgn coder.
    ///
    /// - Parameter capacity: Pre-allocated output buffer size in bytes.
    init(capacity: Int = 1024) {
        writer = HTFastBitWriter(capacity: capacity)
    }

    /// Resets the MagSgn coder for reuse without reallocating the buffer.
    @inline(__always)
    mutating func reset(capacity: Int) {
        writer.reset(capacity: capacity)
    }

    /// Encodes the magnitude and sign of a significant coefficient.
    ///
    /// Uses bulk bit emission: packs sign + lower magnitude bits into a single
    /// value and emits them in one emitBits call, avoiding per-bit overhead.
    @inline(__always)
    mutating func encode(magnitude: Int, sign: Int, bitPlane: Int) {
        guard magnitude > 0 else { return }

        let lowerBits = magnitude - (1 << bitPlane)
        let totalBits = 1 + bitPlane
        let packed = ((sign & 1) << bitPlane) | lowerBits
        writer.emitBits(packed, count: totalBits)
    }

    /// The number of output bytes (including any partial byte in the accumulator).
    var byteCount: Int { writer.byteCount }

    /// Flushes the MagSgn coder and returns the encoded data.
    mutating func flush() -> Data {
        writer.flush()
    }

    /// Flushes and copies output directly to a destination pointer.
    @inline(__always)
    @discardableResult
    mutating func flushTo(_ dest: UnsafeMutablePointer<UInt8>) -> Int {
        writer.flushTo(dest)
    }

    /// Decodes a magnitude and sign from the MagSgn stream.
    mutating func decode(from reader: inout J2KBitReader, bitPlane: Int) throws -> Int {
        let sign = try reader.readBit() ? 1 : 0

        var lowerBits = 0
        for _ in 0..<max(0, bitPlane) {
            let bit = try reader.readBit() ? 1 : 0
            lowerBits = (lowerBits << 1) | bit
        }

        let magnitude = (1 << bitPlane) + lowerBits
        return sign == 1 ? -magnitude : magnitude
    }
}

// MARK: - HT Block Encoder

/// HTJ2K block encoder implementing the FBCOT algorithm.
///
/// The HT block encoder encodes wavelet coefficients in a code-block using
/// the Fast Block Coder with Optimised Truncation. It produces coded data
/// consisting of interleaved MEL, VLC, and MagSgn streams.
///
/// The encoder processes coefficients in stripe-based order (4 rows at a time)
/// and produces a single cleanup pass, optionally followed by fused
/// SigProp+MagRef refinement passes.
///
/// Performance optimizations:
/// - 64-bit word-level bit accumulators in all coding primitives
/// - Pre-allocated output buffers (no dynamic array growth)
/// - Bulk MagSgn emission (sign + magnitude in one `emitBits` call)
/// - VLC data reversed in-place (no `Data(reversed())` copy)
/// - Fused SigProp + MagRef into single scan per bit-plane
/// - UInt64-packed significance bitfield (8× denser than `[Bool]`)
///
/// Example:
/// ```swift
/// let encoder = HTBlockEncoder(width: 32, height: 32, subband: .hh)
/// let result = try encoder.encode(coefficients: coeffs, bitPlane: 7)
/// ```
@inline(__always)
func htRefinementStripeGroupSpan(forHeight height: Int) -> Int {
    let numStripes = max(1, (height + 3) / 4)
    if numStripes >= 16 { return 8 }
    if numStripes >= 12 { return 6 }
    return numStripes
}

@inline(__always)
func htMagRefCheckpointStripeGroupSpan(forHeight height: Int) -> Int {
    let numStripes = max(1, (height + 3) / 4)
    if numStripes >= 16 { return 8 }
    if numStripes >= 8 { return 4 }
    return numStripes
}

struct HTBlockEncoder: Sendable {
    /// The width of the code-block.
    let width: Int

    /// The height of the code-block.
    let height: Int

    /// The subband this code-block belongs to.
    let subband: J2KSubband
}

// MARK: - HT Block Decoder

/// HTJ2K block decoder implementing the FBCOT decoding algorithm.
///
/// The HT block decoder decodes wavelet coefficients from coded data produced
/// by the HT block encoder. It reverses the MEL, VLC, and MagSgn coding to
/// reconstruct the original wavelet coefficients.
///
/// Example:
/// ```swift
/// let decoder = HTBlockDecoder(width: 32, height: 32, subband: .hh)
/// let coefficients = try decoder.decodeCleanupConformant(rawBytes: bytes, missingMSBs: 0)
/// ```
struct HTBlockDecoder: Sendable {
    /// The width of the code-block.
    let width: Int

    /// The height of the code-block.
    let height: Int

    /// The subband this code-block belongs to.
    let subband: J2KSubband
}

// MARK: - Encoded Block

/// Represents an HTJ2K-encoded code-block.
///
/// Contains the coded data and metadata from an HT block encoding operation,
/// including the lengths of the individual coding primitive streams.
struct HTEncodedBlock: Sendable {
    /// The combined coded data (MEL + MagSgn + reversed VLC).
    let codedData: Data

    /// The type of coding pass that produced this data.
    let passType: HTCodingPassType

    /// The length of the MEL stream in bytes.
    let melLength: Int

    /// The length of the VLC stream in bytes.
    let vlcLength: Int

    /// The length of the MagSgn stream in bytes.
    let magsgnLength: Int

    /// The bit-plane at which encoding was performed.
    let bitPlane: Int

    /// The code-block width.
    let width: Int

    /// The code-block height.
    let height: Int

}
