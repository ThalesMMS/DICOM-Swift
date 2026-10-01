//
// J2KBitReader.swift
// J2KSwift
//
/// # J2KBitReader
///
/// Bitstream reading utilities for JPEG 2000 codestream parsing.
///
/// This module provides efficient bit-level reading operations for parsing
/// JPEG 2000 codestreams and marker segments.

import Foundation

/// A bit-level reader for parsing binary data.
///
/// `J2KBitReader` provides efficient bit-level reading operations for parsing
/// JPEG 2000 codestreams. It supports both bit-aligned and byte-aligned reads.
///
/// > Important: This is an **internal implementation detail** of the J2KSwift library.
/// > It is exposed as `public` only for cross-module use within the package.
/// > Direct use of this type is not recommended and its API may change in future versions.
/// > Use ``J2KDecoder`` or ``J2KFileReader`` instead for decoding JPEG 2000 data.
///
/// Example:
/// ```swift
/// let data = Data([0xFF, 0x4F, 0x00, 0x01])
/// let reader = J2KBitReader(data: data)
/// let marker = try reader.readUInt16()
/// ```
public struct J2KBitReader: Sendable {
    /// The underlying data being read.
    private let data: Data

    /// The current byte position in the data.
    private var bytePosition: Int

    /// The current bit position within the current byte (0-7, where 0 is MSB).
    private var bitPosition: Int

    /// Whether JPEG 2000 byte stuffing is enabled (for packet headers).
    ///
    /// Per ISO/IEC 15444-1 B.10.1, after a 0xFF byte in a packet header,
    /// the next byte's MSB is a stuffed 0 bit (only 7 data bits).
    private var byteStuffingEnabled: Bool

    /// Creates a new bit reader from the specified data.
    ///
    /// Data slices with non-zero `startIndex` are normalized to zero-based
    /// indexing so that internal `data[bytePosition]` accesses remain valid.
    ///
    /// - Parameter data: The data to read from.
    public init(data: Data) {
        // Normalize to zero-based indexing to avoid slice offset issues.
        // Data subscript uses absolute indices, so a slice like data[6..<10]
        // would trap on data[0]. Copying restores startIndex == 0.
        self.data = data.startIndex == 0 ? data : Data(data)
        self.bytePosition = 0
        self.bitPosition = 0
        self.byteStuffingEnabled = false
    }

    /// Enables or disables JPEG 2000 byte stuffing for packet headers.
    public mutating func setByteStuffing(_ enabled: Bool) {
        byteStuffingEnabled = enabled
    }

    /// The total number of bytes in the data.
    public var count: Int {
        data.count
    }

    /// The current byte position in the data.
    public var position: Int {
        bytePosition
    }

    /// The current bit offset within the current byte (0-7).
    public var bitOffset: Int {
        bitPosition
    }

    /// Returns `true` if the reader is at a byte boundary.
    public var isByteAligned: Bool {
        bitPosition == 0
    }

    /// Returns `true` if there is no more data to read.
    public var isAtEnd: Bool {
        bytePosition >= data.count
    }

    /// The number of bytes remaining to be read.
    public var bytesRemaining: Int {
        max(0, data.count - bytePosition)
    }

    /// The number of bits remaining to be read.
    public var bitsRemaining: Int {
        guard bytePosition < data.count else { return 0 }
        return (data.count - bytePosition) * 8 - bitPosition
    }

    // MARK: - Byte-Aligned Reading

    /// Reads a single byte from the stream.
    ///
    /// - Returns: The byte value.
    /// - Throws: ``J2KError/invalidData(_:)`` if there is insufficient data.
    public mutating func readUInt8() throws -> UInt8 {
        try alignToByte()
        guard bytePosition < data.count else {
            throw J2KError.invalidData("Unexpected end of data at position \(bytePosition)")
        }
        let value = data[bytePosition]
        bytePosition += 1
        return value
    }

    /// Reads a 16-bit big-endian unsigned integer from the stream.
    ///
    /// - Returns: The 16-bit value.
    /// - Throws: ``J2KError/invalidData(_:)`` if there is insufficient data.
    public mutating func readUInt16() throws -> UInt16 {
        try alignToByte()
        guard bytePosition + 2 <= data.count else {
            throw J2KError.invalidData("Unexpected end of data at position \(bytePosition)")
        }
        let value = UInt16(data[bytePosition]) << 8 | UInt16(data[bytePosition + 1])
        bytePosition += 2
        return value
    }

    /// Reads a 32-bit big-endian unsigned integer from the stream.
    ///
    /// - Returns: The 32-bit value.
    /// - Throws: ``J2KError/invalidData(_:)`` if there is insufficient data.
    public mutating func readUInt32() throws -> UInt32 {
        try alignToByte()
        guard bytePosition + 4 <= data.count else {
            throw J2KError.invalidData("Unexpected end of data at position \(bytePosition)")
        }
        var value: UInt32 = 0
        for i in 0..<4 {
            value = (value << 8) | UInt32(data[bytePosition + i])
        }
        bytePosition += 4
        return value
    }

    /// Reads a 64-bit big-endian unsigned integer from the stream.
    ///
    /// - Returns: The 64-bit value.
    /// - Throws: ``J2KError/invalidData(_:)`` if there is insufficient data.
    public mutating func readUInt64() throws -> UInt64 {
        try alignToByte()
        guard bytePosition + 8 <= data.count else {
            throw J2KError.invalidData("Unexpected end of data at position \(bytePosition)")
        }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(data[bytePosition + i])
        }
        bytePosition += 8
        return value
    }

    /// Reads the specified number of bytes from the stream.
    ///
    /// - Parameter count: The number of bytes to read.
    /// - Returns: The data read.
    /// - Throws: ``J2KError/invalidData(_:)`` if there is insufficient data.
    public mutating func readBytes(_ count: Int) throws -> Data {
        try alignToByte()
        guard bytePosition + count <= data.count else {
            throw J2KError.invalidData("Unexpected end of data at position \(bytePosition)")
        }
        let result = data.subdata(in: bytePosition..<(bytePosition + count))
        bytePosition += count
        return result
    }

    // MARK: - Bit-Level Reading

    /// Reads a single bit from the stream.
    ///
    /// - Returns: `true` if the bit is 1, `false` if 0.
    /// - Throws: ``J2KError/invalidData(_:)`` if there is insufficient data.
    public mutating func readBit() throws -> Bool {
        guard bytePosition < data.count else {
            throw J2KError.invalidData("Unexpected end of data at position \(bytePosition)")
        }

        let byte = data[bytePosition]
        let mask = UInt8(1 << (7 - bitPosition))
        let bit = (byte & mask) != 0

        bitPosition += 1
        if bitPosition >= 8 {
            // After 0xFF, MSB of next byte is stuffed: start at position 1
            let isFF = byteStuffingEnabled && (byte == 0xFF)
            bitPosition = isFF ? 1 : 0
            bytePosition += 1
        }

        return bit
    }

    /// Reads the specified number of bits from the stream.
    ///
    /// - Parameter count: The number of bits to read (1-32).
    /// - Returns: The bits as an unsigned integer.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if count is invalid.
    /// - Throws: ``J2KError/invalidData(_:)`` if there is insufficient data.
    public mutating func readBits(_ count: Int) throws -> UInt32 {
        guard count >= 1 && count <= 32 else {
            throw J2KError.invalidParameter("Bit count must be between 1 and 32, got \(count)")
        }

        guard bitsRemaining >= count else {
            throw J2KError.invalidData("Insufficient bits: need \(count), have \(bitsRemaining)")
        }

        var result: UInt32 = 0
        var bitsToRead = count

        while bitsToRead > 0 {
            let bitsInCurrentByte = 8 - bitPosition
            let bitsThisIteration = min(bitsToRead, bitsInCurrentByte)

            let byte = data[bytePosition]
            let shift = bitsInCurrentByte - bitsThisIteration
            let mask = UInt8((1 << bitsThisIteration) - 1)
            let bits = (byte >> shift) & mask

            result = (result << bitsThisIteration) | UInt32(bits)

            bitPosition += bitsThisIteration
            if bitPosition >= 8 {
                // After 0xFF, MSB of next byte is stuffed: start at position 1
                let isFF = byteStuffingEnabled && (byte == 0xFF)
                bitPosition = isFF ? 1 : 0
                bytePosition += 1
            }

            bitsToRead -= bitsThisIteration
        }

        return result
    }

    // MARK: - Alignment and Position

    /// Aligns the reader to the next byte boundary.
    ///
    /// If already at a byte boundary, this method does nothing.
    /// Otherwise, it skips the remaining bits in the current byte.
    /// When byte stuffing is enabled, also skips the stuffed byte after 0xFF.
    public mutating func alignToByte() throws {
        if bitPosition != 0 {
            let wasFF = byteStuffingEnabled && bytePosition < data.count && data[bytePosition] == 0xFF
            bitPosition = 0
            bytePosition += 1
            // After 0xFF, the encoder appended a stuffed 0x00 byte - skip it
            if wasFF && bytePosition < data.count {
                bytePosition += 1
            }
        }
    }

    /// Seeks to the specified byte position.
    ///
    /// - Parameter position: The byte position to seek to.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the position is out of bounds.
    public mutating func seek(to position: Int) throws {
        guard position >= 0 && position <= data.count else {
            throw J2KError.invalidParameter("Position \(position) is out of bounds (0..\(data.count))")
        }
        bytePosition = position
        bitPosition = 0
    }

    /// Skips the specified number of bytes.
    ///
    /// - Parameter count: The number of bytes to skip.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if there is insufficient data.
    public mutating func skip(_ count: Int) throws {
        try alignToByte()
        let newPosition = bytePosition + count
        guard newPosition >= 0 && newPosition <= data.count else {
            throw J2KError.invalidParameter("Cannot skip \(count) bytes from position \(bytePosition)")
        }
        bytePosition = newPosition
    }

    /// Skips the specified number of bits.
    ///
    /// - Parameter count: The number of bits to skip.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if there is insufficient data.
    public mutating func skipBits(_ count: Int) throws {
        guard count >= 0 else {
            throw J2KError.invalidParameter("Cannot skip negative number of bits: \(count)")
        }

        guard bitsRemaining >= count else {
            throw J2KError.invalidData("Insufficient bits to skip: need \(count), have \(bitsRemaining)")
        }

        let totalBits = bitPosition + count
        bytePosition += totalBits / 8
        bitPosition = totalBits % 8
    }

    // MARK: - Peek Operations

    /// Peeks at the next byte without advancing the position.
    ///
    /// - Returns: The next byte, or `nil` if at end of data.
    public func peekUInt8() -> UInt8? {
        guard bitPosition == 0 && bytePosition < data.count else {
            return nil
        }
        return data[bytePosition]
    }

    /// Peeks at the next 16-bit value without advancing the position.
    ///
    /// - Returns: The next 16-bit value, or `nil` if insufficient data.
    public func peekUInt16() -> UInt16? {
        guard bitPosition == 0 && bytePosition + 2 <= data.count else {
            return nil
        }
        return UInt16(data[bytePosition]) << 8 | UInt16(data[bytePosition + 1])
    }

    // MARK: - Marker Detection (JPEG 2000 specific)

    /// Reads the next marker from the stream.
    ///
    /// A marker is a two-byte sequence starting with 0xFF.
    ///
    /// - Returns: The marker code (including the 0xFF prefix).
    /// - Throws: ``J2KError/invalidData(_:)`` if the marker is invalid.
    public mutating func readMarker() throws -> UInt16 {
        try alignToByte()
        let marker = try readUInt16()
        guard (marker & 0xFF00) == 0xFF00 else {
            throw J2KError.invalidData("Invalid marker: expected 0xFF prefix at position \(bytePosition - 2)")
        }
        return marker
    }

    /// Checks if the next two bytes form a valid marker.
    ///
    /// - Returns: `true` if the next bytes are a valid marker.
    public func isNextMarker() -> Bool {
        guard let value = peekUInt16() else { return false }
        return (value & 0xFF00) == 0xFF00
    }
}
