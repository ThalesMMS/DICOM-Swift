/// Bitstream reader for JPEG-LS decoding
///
/// Provides bit-level and byte-level reading operations on a data buffer
/// with marker detection and error handling.

import Foundation

/// Bitstream reader for JPEG-LS
///
/// Reads bytes and bits from a buffer, handling marker stuffing and
/// detecting premature end of stream.
///
/// Bit-level reads run over a 64-bit window refilled several bytes at a
/// time (applying the ISO 14495-1 §9.1 stuff-bit rule per refilled byte),
/// so per-bit work is a shift and a counter update instead of a byte fetch.
/// Unary prefixes are decoded with `leadingZeroBitCount` over the window.
///
/// - Important: The eager refill advances the byte position ahead of bit
///   consumption. After any bit-level read, call `resetBitBuffer()` before
///   using the byte-level API (`readByte`, `peekByte`, `readBytes`,
///   `readUInt16`, `readMarker`, `currentPosition`, `bytesRemaining`) —
///   it realigns the position to the byte boundary after the last consumed
///   bit. Mixing the two modes without a reset reads ahead of the logical
///   position.
public final class JPEGLSBitstreamReader {
    private let bytes: [UInt8]
    /// Index of the next byte to load (bit reads) or read directly (byte reads).
    /// Bit-level refill advances this eagerly; the unconsumed bits live in
    /// `bitBuffer`/`bitsInBuffer`.
    private var position: Int
    /// Bit accumulator. The low `bitsInBuffer` bits below previously-consumed
    /// garbage are valid; consumption only decrements `bitsInBuffer` (matching
    /// the historical extract-by-shift-and-mask behaviour).
    private var bitBuffer: UInt64
    private var bitsInBuffer: Int
    /// Byte index where the current buffered bit region began, and the number
    /// of bits consumed from it. `resetBitBuffer` replays the stuffing rules
    /// over the region to land `position` on the byte boundary following the
    /// last consumed bit (the eager refill advances `position` further ahead).
    private var bitRegionStart: Int
    private var bitsConsumedInRegion: Int

    /// Initialize reader with data buffer
    ///
    /// - Parameter data: Input data to read from
    public init(data: Data) {
        self.bytes = [UInt8](data)
        self.position = 0
        self.bitBuffer = 0
        self.bitsInBuffer = 0
        self.bitRegionStart = 0
        self.bitsConsumedInRegion = 0
    }

    /// Current read position in bytes
    public var currentPosition: Int {
        return position
    }

    /// Number of bytes remaining in buffer
    public var bytesRemaining: Int {
        return bytes.count - position
    }

    /// Returns true if end of data reached
    public var isAtEnd: Bool {
        return position >= bytes.count && bitsInBuffer == 0
    }

    /// Read a single byte from the stream
    ///
    /// - Returns: The byte value
    /// - Throws: `JPEGLSError.prematureEndOfStream` if no data available
    public func readByte() throws -> UInt8 {
        guard position < bytes.count else {
            throw JPEGLSError.prematureEndOfStream
        }
        let byte = bytes[position]
        position += 1
        return byte
    }

    /// Read multiple bytes from the stream
    ///
    /// - Parameter count: Number of bytes to read
    /// - Returns: Data containing the bytes
    /// - Throws: `JPEGLSError.prematureEndOfStream` if not enough data
    public func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, position + count <= bytes.count else {
            throw JPEGLSError.prematureEndOfStream
        }
        let result = Data(bytes[position..<position + count])
        position += count
        return result
    }

    /// Read a 16-bit big-endian value
    ///
    /// - Returns: The 16-bit value
    /// - Throws: `JPEGLSError.prematureEndOfStream` if not enough data
    public func readUInt16() throws -> UInt16 {
        let byte1 = try readByte()
        let byte2 = try readByte()
        return (UInt16(byte1) << 8) | UInt16(byte2)
    }

    /// Peek at the next byte without advancing position
    ///
    /// - Returns: The next byte, or nil if at end
    public func peekByte() -> UInt8? {
        guard position < bytes.count else {
            return nil
        }
        return bytes[position]
    }

    /// Read a marker (2-byte sequence starting with 0xFF)
    ///
    /// - Returns: The marker
    /// - Throws: `JPEGLSError` if marker is invalid or not found
    public func readMarker() throws -> JPEGLSMarker {
        let byte1 = try readByte()
        guard byte1 == JPEGLSMarker.markerPrefix else {
            throw JPEGLSError.invalidMarker(byte1: byte1, byte2: 0)
        }

        var byte2 = try readByte()
        // T.81 B.1.1.2: any number of 0xFF fill bytes may precede a marker, as in `JPEGLSParser.parse`.
        while byte2 == JPEGLSMarker.markerPrefix { byte2 = try readByte() }
        guard let marker = JPEGLSMarker(rawValue: byte2) else {
            throw JPEGLSError.invalidMarker(byte1: byte1, byte2: byte2)
        }

        return marker
    }

    // MARK: - Bit-level reading

    /// Top up the 64-bit window while at least 16 bits of headroom remain,
    /// applying the §9.1 stuffing rule per refilled byte:
    /// - 0xFF followed by a byte < 0x80: stuffed pair contributes 8 + 7 bits
    ///   (the follower's MSB is the discarded stuff bit).
    /// - 0xFF followed by a byte ≥ 0x80 (marker) or at end of data:
    ///   the 0xFF alone contributes 8 bits.
    @inline(__always)
    private func refill() {
        if bitsInBuffer == 0 && bitsConsumedInRegion == 0 {
            bitRegionStart = position
        }
        let count = bytes.count
        while bitsInBuffer <= 48 && position < count {
            let byte = bytes[position]
            if byte == 0xFF && position + 1 < count {
                let next = bytes[position + 1]
                if next < 0x80 {
                    // Stuffed pair: 0xFF (8 bits) + stuff bit dropped + 7 data bits.
                    position += 2
                    bitBuffer = (bitBuffer << 15) | (0xFF << 7) | UInt64(next & 0x7F)
                    bitsInBuffer += 15
                    continue
                }
                // next >= 0x80: marker follows. The FF is added below; decoding
                // should finish before any marker bytes are consumed.
            }
            position += 1
            bitBuffer = (bitBuffer << 8) | UInt64(byte)
            bitsInBuffer += 8
        }
    }

    /// The valid bits left-aligned at the top of a 64-bit word.
    /// Only call with `bitsInBuffer > 0`.
    @inline(__always)
    private func alignedWindow() -> UInt64 {
        let mask: UInt64 = (1 << UInt64(bitsInBuffer)) &- 1
        return (bitBuffer & mask) << UInt64(64 - bitsInBuffer)
    }

    /// Read bits from the bitstream
    ///
    /// Implements JPEG-LS bit-level byte stuffing per ISO 14495-1 §9.1:
    /// When a byte of 0xFF is read, the following byte is examined:
    /// - If its MSB (bit 7) is 0: it is a stuffed byte. Bit 7 is the stuff bit (discarded);
    ///   bits 6–0 are real data bits. Total contribution: 8 bits (0xFF) + 7 data bits = 15 bits.
    /// - If its MSB (bit 7) is 1: it is the start of a marker. The 0xFF byte alone is added
    ///   to the buffer; the following byte is not consumed. Decoding should terminate before
    ///   consuming any marker bytes.
    ///
    /// All JPEG-LS markers have their second byte with MSB = 1 (values 0x80–0xFF).
    /// All stuffed bytes have their second byte with MSB = 0 (values 0x00–0x7F).
    ///
    /// - Parameter count: Number of bits to read (1-32)
    /// - Returns: The bits as a UInt32
    /// - Throws: `JPEGLSError.prematureEndOfStream` if not enough data
    public func readBits(_ count: Int) throws -> UInt32 {
        guard count > 0 && count <= 32 else {
            throw JPEGLSError.internalError(reason: "Invalid bit count: \(count)")
        }

        if bitsInBuffer < count {
            refill()
            guard bitsInBuffer >= count else {
                throw JPEGLSError.prematureEndOfStream
            }
        }

        // Extract bits from the most-significant valid position.
        let shift = bitsInBuffer - count
        let mask: UInt32 = count < 32 ? ((1 << count) - 1) : UInt32.max
        let bits = UInt32(truncatingIfNeeded: bitBuffer >> UInt64(shift)) & mask

        bitsInBuffer -= count
        bitsConsumedInRegion += count

        return bits
    }

    /// Read a unary prefix: zero or more '0' bits terminated by a single '1'
    /// bit, returning the number of zeros. Equivalent to calling
    /// `readBits(1)` in a loop until a 1 appears, but counts the zeros with
    /// `leadingZeroBitCount` over the buffered window instead of one call
    /// per bit.
    ///
    /// - Returns: The number of '0' bits before the terminating '1'
    /// - Throws: `JPEGLSError.prematureEndOfStream` if the stream ends
    ///   before a '1' bit is found
    public func readUnaryCount() throws -> Int {
        var count = 0
        while true {
            if bitsInBuffer == 0 {
                refill()
                guard bitsInBuffer > 0 else {
                    throw JPEGLSError.prematureEndOfStream
                }
            }
            let window = alignedWindow()
            let zeros = min(window.leadingZeroBitCount, bitsInBuffer)
            if zeros < bitsInBuffer {
                // Found the terminating '1': consume the zeros and the 1.
                bitsInBuffer -= zeros + 1
                bitsConsumedInRegion += zeros + 1
                return count + zeros
            }
            // Every buffered bit is 0 — consume them all and keep scanning.
            count += bitsInBuffer
            bitsConsumedInRegion += bitsInBuffer
            bitsInBuffer = 0
        }
    }

    /// Reset the bit buffer (typically called at scan boundaries)
    ///
    /// Discards any unconsumed buffered bits and aligns the byte position to
    /// the boundary following the last consumed bit, replaying the §9.1
    /// stuffing rule over the buffered region (a stuffed 0xFF pair counts as
    /// two bytes carrying 15 bits).
    public func resetBitBuffer() {
        if bitsConsumedInRegion > 0 {
            var pos = bitRegionStart
            var remaining = bitsConsumedInRegion
            let count = bytes.count
            while remaining > 0 && pos < count {
                let byte = bytes[pos]
                if byte == 0xFF && pos + 1 < count && bytes[pos + 1] < 0x80 {
                    pos += 2
                    remaining -= 15
                } else {
                    pos += 1
                    remaining -= 8
                }
            }
            position = pos
        }
        bitBuffer = 0
        bitsInBuffer = 0
        bitRegionStart = position
        bitsConsumedInRegion = 0
    }

    /// Seek to a specific position in the stream
    ///
    /// - Parameter position: Target position in bytes
    /// - Throws: `JPEGLSError` if position is invalid
    public func seek(to position: Int) throws {
        guard position >= 0 && position <= bytes.count else {
            throw JPEGLSError.internalError(reason: "Invalid seek position: \(position)")
        }
        bitBuffer = 0
        bitsInBuffer = 0
        bitsConsumedInRegion = 0
        self.position = position
        bitRegionStart = position
    }
}
