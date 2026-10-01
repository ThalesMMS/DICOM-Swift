// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Bit-level writer for constructing JPEG entropy-coded data.
///
/// Accumulates bits MSB-first into bytes, handling JPEG byte stuffing
/// (`0xFF` is followed by `0x00` in the entropy-coded segment). For a noisy
/// 512×512 encode the writer emits ~500k bytes; the previous `.append`-per-byte
/// implementation was the single hottest cost in that case. This rewrite
/// preallocates the buffer to an upper bound (caller can size it tightly via
/// the initializer) and writes via direct subscript, avoiding both bounds-check
/// growth and Array's copy-on-write checks in the inner loop.
struct BitWriter {
    /// Backing storage; only the first `byteCount` bytes are meaningful. Sized
    /// to the caller's estimated upper bound and doubled on the rare overflow.
    private var buffer: [UInt8]
    /// Number of bytes actually written to `buffer`.
    private var byteCount: Int = 0
    /// Bit accumulator: the low `nbits` bits hold pending output, MSB-first.
    /// A 64-bit register lets us coalesce byte emission instead of flushing one
    /// byte (through a closure) per 8 bits — the Huffman/bit-writing path is the
    /// hottest cost in a noisy encode, so batching here is the main lever.
    /// Kept below 8 after every `writeBits`, so it never overflows for the
    /// ≤16-bit writes JPEG entropy coding issues.
    private var acc: UInt64 = 0
    private var nbits: Int = 0

    /// 64 KB is enough for a typical 256×256 photo; the encoder passes a tighter
    /// upper bound derived from the image dimensions.
    init(estimatedMaxSize: Int = 65536) {
        buffer = [UInt8](repeating: 0, count: max(estimatedMaxSize, 64))
    }

    /// The bytes written so far. Computed — slices `buffer` down to actual length.
    var data: [UInt8] {
        Array(buffer[0..<byteCount])
    }

    /// Writes `count` bits from `value` (MSB-first).
    mutating func writeBits(_ value: UInt32, count: Int) {
        guard count > 0 else { return }
        acc = (acc << UInt64(count)) | UInt64(value & ((1 << count) - 1))
        nbits += count
        if nbits < 8 { return }   // no whole byte pending — skip the buffer access
        // Each pending whole byte can expand to two with stuffing; +2 slack for
        // the in-loop stuffing byte.
        if byteCount + (nbits >> 3) * 2 + 2 > buffer.count { grow() }
        buffer.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            var bc = byteCount
            while nbits >= 8 {
                nbits -= 8
                let byte = UInt8((acc >> UInt64(nbits)) & 0xFF)
                p[bc] = byte; bc += 1
                if byte == 0xFF { p[bc] = 0; bc += 1 }   // byte stuffing
            }
            byteCount = bc
        }
    }

    /// Writes a single bit.
    mutating func writeBit(_ bit: Bool) {
        writeBits(bit ? 1 : 0, count: 1)
    }

    /// Flushes any remaining bits, padding with 1-bits as per JPEG spec.
    mutating func flush() {
        guard nbits > 0 else { return }   // nbits is always 0–7 here
        let pad = 8 - nbits
        let byte = UInt8(((acc << UInt64(pad)) | UInt64((1 << pad) - 1)) & 0xFF)
        if byteCount + 2 > buffer.count { grow() }
        buffer.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            p[byteCount] = byte
            if byte == 0xFF { p[byteCount + 1] = 0 }
        }
        byteCount += (byte == 0xFF) ? 2 : 1
        acc = 0
        nbits = 0
    }

    /// Pads to a byte boundary (1-bits, per spec) and writes a restart marker
    /// `0xFF 0xD0…0xD7` (`index` cycles 0–7). The marker bytes are written raw —
    /// the `0xFF` here is a real marker prefix, not stuffed data.
    mutating func emitRestartMarker(_ index: Int) {
        flush()                       // align to byte boundary (no-op if already aligned)
        if byteCount + 2 > buffer.count { grow() }
        buffer.withUnsafeMutableBufferPointer { buf in
            buf[byteCount] = 0xFF
            buf[byteCount + 1] = 0xD0 + UInt8(index & 7)
        }
        byteCount += 2
    }

    /// Doubles the backing buffer when the initial estimate was too small.
    /// Allocating in chunks keeps the amortized cost ~O(1) per byte.
    private mutating func grow() {
        buffer.append(contentsOf: repeatElement(0, count: buffer.count))
    }
}

/// Bit-level reader for parsing JPEG entropy-coded data.
///
/// Reads bits MSB-first from a byte buffer, handling JPEG byte stuffing. The
/// accumulator is 64-bit and refills in bulk: when the next 8 source bytes
/// contain no `0xFF` (checked with one SWAR test), they are spliced in with a
/// single unaligned load instead of up to 8 branchy byte loads. Lossless decode
/// reads one Huffman symbol plus up to 15 magnitude bits per *sample*, so
/// refill cost dominates that path — this is its main lever.
///
/// Invariant the bulk path preserves: whole unconsumed bytes ever buffered
/// across operations come only from bulk loads of `0xFF`-free runs, each
/// mapping 1:1 to the source bytes immediately before `byteOffset` (the
/// stuffing-aware byte loads are only triggered to complete a read/symbol that
/// then consumes them below 8 remaining bits). `alignToByte` relies on this to
/// rewind `byteOffset` over buffered whole bytes exactly.
struct BitReader {
    private let data: [UInt8]
    /// Current byte position in the data buffer.
    private(set) var byteOffset: Int = 0
    /// Bit accumulator (MSB-first in the low `bitsAvailable` bits).
    private var bitBuffer: UInt64 = 0
    /// Number of valid bits in the bit buffer.
    private var bitsAvailable: Int = 0

    init(data: [UInt8]) {
        self.data = data
    }

    /// Starts reading at `offset` — used by segment-parallel lossless decode,
    /// where each restart segment's reader begins just past its RST marker.
    init(data: [UInt8], startingAt offset: Int) {
        self.data = data
        self.byteOffset = min(max(0, offset), data.count)
    }

    /// Whether there is more data to read.
    var hasMore: Bool {
        byteOffset < data.count || bitsAvailable > 0
    }

    /// Reads a single bit.
    mutating func readBit() throws -> UInt32 {
        return try readBits(1)
    }

    /// True when any byte of `x` equals `0xFF` (SWAR zero-byte test on `~x`).
    @inline(__always)
    private static func hasFFByte(_ x: UInt64) -> Bool {
        let y = ~x
        return ((y &- 0x0101_0101_0101_0101) & ~y & 0x8080_8080_8080_8080) != 0
    }

    /// Bulk-splices up to 8 source bytes into the accumulator with one load when
    /// the next 8 bytes are plain data (no `0xFF` anywhere — conservatively
    /// covering stuffing *and* markers, so the byte-wise path keeps sole
    /// ownership of both). Returns `false` when the bulk path doesn't apply.
    @inline(__always)
    private mutating func bulkRefill() -> Bool {
        guard byteOffset + 8 <= data.count else { return false }
        let word = data.withUnsafeBufferPointer { buf in
            UInt64(bigEndian: UnsafeRawPointer(buf.baseAddress! + byteOffset)
                .loadUnaligned(as: UInt64.self))
        }
        guard !Self.hasFFByte(word) else { return false }
        let k = (64 - bitsAvailable) >> 3          // whole bytes that fit (≥ 6 here)
        bitBuffer = (bitBuffer << (8 * k)) | (word >> (64 - 8 * k))
        bitsAvailable += 8 * k
        byteOffset += k
        return true
    }

    /// Reads `count` bits and returns them as an unsigned integer.
    mutating func readBits(_ count: Int) throws -> UInt32 {
        // Every legitimate JPEG bit-read is ≤ 16 bits (magnitude categories ≤ 15,
        // EOBRUN appendages ≤ 14). A larger width only arises from a malformed or
        // forged Huffman table (whose decoded "category" can be any byte) — throw.
        guard count >= 0, count <= 16 else {
            throw JLIError.decodingFailed("invalid bit-read width \(count)")
        }
        while bitsAvailable < count {
            if bulkRefill() { break }
            try loadByte()
        }
        bitsAvailable -= count
        let value = (bitBuffer >> UInt64(bitsAvailable)) & ((1 << UInt64(count)) - 1)
        return UInt32(truncatingIfNeeded: value)
    }

    /// Table-driven fast path for short (≤8-bit) Huffman codes.
    ///
    /// Best-effort fills the buffer to 8 bits (without throwing), peeks the top
    /// byte, and — if it resolves to a complete ≤8-bit code in `table` — consumes
    /// exactly that code's bits and returns its symbol. Returns `nil` (consuming
    /// nothing) when the code is longer than 8 bits or when 8 bits can't be
    /// safely buffered (a marker or end-of-data is within reach). In every
    /// `nil` case the caller falls back to the throwing bit-by-bit reader, which
    /// is the sole owner of long-code, marker, EOF, and malformed-table handling.
    /// Because the lookahead table is derived from the same canonical codes and
    /// the prefix-free property holds, a non-`nil` result is bit-for-bit what the
    /// bit-by-bit walk would have produced.
    mutating func fastDecodeSymbol(_ table: HuffmanTable) -> UInt8? {
        if bitsAvailable < 8 { fillBuffer(upTo: 8) }
        guard bitsAvailable >= 8 else { return nil }
        let peek = Int((bitBuffer >> (bitsAvailable - 8)) & 0xFF)
        let len = table.lookaheadLength[peek]
        guard len != 0 else { return nil }
        bitsAvailable -= Int(len)
        return table.lookaheadSymbol[peek]
    }

    /// Best-effort buffer fill used only by ``fastDecodeSymbol(_:)``. Tries the
    /// bulk splice first, then loads whole bytes (resolving `0xFF 0x00` stuffing
    /// exactly as ``loadByte()`` does) until at least `target` bits are buffered,
    /// but **stops without throwing** when it reaches a marker (`0xFF` not
    /// followed by `0x00`) or the end of the data — it never advances past a
    /// marker.
    private mutating func fillBuffer(upTo target: Int) {
        if bitsAvailable < target, bulkRefill() { return }
        while bitsAvailable < target {
            guard byteOffset < data.count else { return }
            let byte = data[byteOffset]
            if byte == 0xFF {
                guard byteOffset + 1 < data.count else { return }
                if data[byteOffset + 1] != 0x00 { return }  // marker — leave for slow path
                byteOffset += 2                               // consume the stuffed 0xFF 0x00
            } else {
                byteOffset += 1
            }
            bitBuffer = (bitBuffer << 8) | UInt64(byte)
            bitsAvailable += 8
        }
    }

    /// Loads the next byte from the data, handling byte stuffing.
    private mutating func loadByte() throws {
        guard byteOffset < data.count else {
            throw JLIError.decodingFailed("Unexpected end of entropy-coded data")
        }
        let byte = data[byteOffset]
        byteOffset += 1

        if byte == 0xFF {
            guard byteOffset < data.count else {
                throw JLIError.decodingFailed("Unexpected end of data after 0xFF")
            }
            let next = data[byteOffset]
            if next == 0x00 {
                // Byte stuffing — the 0xFF is a data byte
                byteOffset += 1
            } else {
                // This is a marker, not data — should not happen in entropy segment
                throw JLIError.decodingFailed("Unexpected marker 0xFF\(String(format: "%02X", next)) in entropy data")
            }
        }

        bitBuffer = (bitBuffer << 8) | UInt64(byte)
        bitsAvailable += 8
    }

    /// Aligns the reader to the next byte boundary by discarding the partial
    /// byte's remaining bits. Whole unconsumed buffered bytes (which exist only
    /// via the bulk path's 1:1, `0xFF`-free loads — see the type doc) are
    /// returned to the source by rewinding `byteOffset`, so marker scanning
    /// resumes at the true byte position.
    mutating func alignToByte() {
        byteOffset -= bitsAvailable >> 3
        bitsAvailable = 0
        bitBuffer = 0
    }

    /// Consumes a restart marker (`FF D<expectedIndex>`) at the current byte position.
    ///
    /// Called by the decoder after every `restartInterval` MCUs when the JPEG carries
    /// DRI + RST markers. Discards any partial bits first (restart markers always sit
    /// on byte boundaries), then advances past the two-byte marker. The marker index
    /// cycles 0–7 (`RST0`–`RST7`), so the caller passes `mcuCount / restartInterval & 7`.
    ///
    /// JPEG allows fill bytes (`0xFF 0xFF…`) before any marker; we tolerate them here.
    mutating func skipRestartMarker(expectedIndex: Int) throws {
        alignToByte()
        // Skip any 0xFF fill bytes that precede the marker.
        while byteOffset < data.count - 1, data[byteOffset] == 0xFF,
              data[byteOffset + 1] == 0xFF {
            byteOffset += 1
        }
        guard byteOffset + 1 < data.count else {
            throw JLIError.decodingFailed("Unexpected end of data expecting RST marker")
        }
        guard data[byteOffset] == 0xFF else {
            throw JLIError.decodingFailed(
                "Expected RST marker at offset \(byteOffset), got 0x\(String(format: "%02X", data[byteOffset]))"
            )
        }
        let expected = UInt8(0xD0 + (expectedIndex & 7))
        let got = data[byteOffset + 1]
        guard got >= 0xD0 && got <= 0xD7 else {
            throw JLIError.decodingFailed(
                "Expected RST\(expectedIndex & 7) (0xFF D\(expectedIndex & 7)), got 0xFF \(String(format: "%02X", got))"
            )
        }
        // Some encoders emit RSTs out of strict cyclic order on damaged streams,
        // but ImageIO/libjpeg always cycle 0–7. Accept what we got but warn via
        // throwing if it diverges — for now we accept any RST byte for robustness.
        _ = expected
        byteOffset += 2
    }
}
