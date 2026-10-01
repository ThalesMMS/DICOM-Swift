//
// J2KBitWriter.swift
// J2KSwift
//
/// # J2KBitWriter
///
/// Bitstream writing utilities for JPEG 2000 codestream generation.
///
/// This module provides efficient bit-level writing operations for generating
/// JPEG 2000 codestreams and marker segments.

import Foundation

/// A bit-level writer for generating binary data.
///
/// `J2KBitWriter` provides efficient bit-level writing operations for generating
/// JPEG 2000 codestreams. It supports both bit-aligned and byte-aligned writes.
///
/// > Important: This is an **internal implementation detail** of the J2KSwift library.
/// > It is exposed as `public` only for cross-module use within the package.
/// > Direct use of this type is not recommended and its API may change in future versions.
/// > Use ``J2KEncoder`` or ``J2KFileWriter`` instead for encoding JPEG 2000 data.
///
/// Example:
/// ```swift
/// var writer = J2KBitWriter()
/// writer.writeUInt16(0xFF4F) // SOC marker
/// let data = writer.data
/// ```
public struct J2KBitWriter: Sendable {
    /// The buffer to write data to.
    private var buffer: [UInt8]

    /// The current byte being built.
    private var currentByte: UInt8

    /// The current bit position within the current byte (0-7, where 0 is MSB).
    private var bitPosition: Int

    /// Whether JPEG 2000 byte stuffing is enabled (for packet headers).
    ///
    /// Per ISO/IEC 15444-1 B.10.1, after a 0xFF byte in a packet header,
    /// the next byte's MSB must be 0 (only 7 data bits available).
    private var byteStuffingEnabled: Bool

    /// Creates a new bit writer with an optional initial capacity.
    ///
    /// - Parameter capacity: The initial capacity in bytes (default: 1024).
    public init(capacity: Int = 1024) {
        self.buffer = []
        self.buffer.reserveCapacity(capacity)
        self.currentByte = 0
        self.bitPosition = 0
        self.byteStuffingEnabled = false
    }

    /// Enables or disables JPEG 2000 byte stuffing for packet headers.
    ///
    /// When enabled, after outputting a 0xFF byte, the next byte's MSB
    /// is forced to 0 and only 7 data bit positions are available.
    public mutating func setByteStuffing(_ enabled: Bool) {
        byteStuffingEnabled = enabled
    }

    /// The data written so far.
    ///
    /// - Note: This includes any partial byte that has been started.
    public var data: Data {
        var result = Data(buffer)
        if bitPosition > 0 {
            result.append(currentByte)
        }
        return result
    }

    /// The number of complete bytes written.
    public var count: Int {
        buffer.count
    }

    /// The total number of bits written.
    public var bitCount: Int {
        buffer.count * 8 + bitPosition
    }

    /// Returns `true` if the writer is at a byte boundary.
    public var isByteAligned: Bool {
        bitPosition == 0
    }

    // MARK: - Byte-Aligned Writing

    /// Writes a single byte to the stream.
    ///
    /// - Parameter value: The byte to write.
    public mutating func writeUInt8(_ value: UInt8) {
        if bitPosition == 0 {
            buffer.append(value)
        } else {
            // Need to merge with current partial byte
            let shift = 8 - bitPosition
            currentByte |= value >> bitPosition
            buffer.append(currentByte)
            currentByte = value << shift
        }
    }

    /// Writes a 16-bit big-endian unsigned integer to the stream.
    ///
    /// - Parameter value: The 16-bit value to write.
    public mutating func writeUInt16(_ value: UInt16) {
        writeUInt8(UInt8(value >> 8))
        writeUInt8(UInt8(value & 0xFF))
    }

    /// Writes a 32-bit big-endian unsigned integer to the stream.
    ///
    /// - Parameter value: The 32-bit value to write.
    public mutating func writeUInt32(_ value: UInt32) {
        writeUInt8(UInt8((value >> 24) & 0xFF))
        writeUInt8(UInt8((value >> 16) & 0xFF))
        writeUInt8(UInt8((value >> 8) & 0xFF))
        writeUInt8(UInt8(value & 0xFF))
    }

    /// Writes a 64-bit big-endian unsigned integer to the stream.
    ///
    /// - Parameter value: The 64-bit value to write.
    public mutating func writeUInt64(_ value: UInt64) {
        for i in (0..<8).reversed() {
            writeUInt8(UInt8((value >> (i * 8)) & 0xFF))
        }
    }

    /// Writes a sequence of bytes to the stream.
    ///
    /// - Parameter data: The data to write.
    ///
    /// v5.38 M3 fast path: when the writer is byte-aligned and byte
    /// stuffing is disabled, this performs a bulk `append(contentsOf:)`
    /// instead of N `writeUInt8` calls. On medical-corpus lossless
    /// encode the dominant cost was the byte-by-byte append of tile
    /// data into the codestream writer (~12M calls for a 12 MP DX);
    /// the fast path collapses that to a single buffer-grow + memcpy.
    public mutating func writeBytes(_ data: Data) {
        if bitPosition == 0 && !byteStuffingEnabled {
            data.withUnsafeBytes { src in
                buffer.append(contentsOf: src.bindMemory(to: UInt8.self))
            }
            return
        }
        for byte in data {
            writeUInt8(byte)
        }
    }

    /// Writes a sequence of bytes to the stream.
    ///
    /// - Parameter bytes: The bytes to write.
    public mutating func writeBytes(_ bytes: [UInt8]) {
        if bitPosition == 0 && !byteStuffingEnabled {
            buffer.append(contentsOf: bytes)
            return
        }
        for byte in bytes {
            writeUInt8(byte)
        }
    }

    /// Appends raw bytes directly to the buffer without byte stuffing.
    /// The writer must be byte-aligned; the caller is responsible for disabling
    /// byte stuffing before calling this (used for code-block data after packet headers).
    public mutating func appendRawBytes(_ data: Data) {
        assert(bitPosition == 0, "Must be byte-aligned before appending raw bytes")
        data.withUnsafeBytes { src in
            buffer.append(contentsOf: src.bindMemory(to: UInt8.self))
        }
    }

    // MARK: - Bit-Level Writing

    /// Writes a single bit to the stream.
    ///
    /// - Parameter bit: `true` to write 1, `false` to write 0.
    public mutating func writeBit(_ bit: Bool) {
        if bit {
            currentByte |= UInt8(1 << (7 - bitPosition))
        }

        bitPosition += 1
        if bitPosition >= 8 {
            buffer.append(currentByte)
            // After 0xFF, MSB of next byte is stuffed as 0: start at position 1
            let isFF = byteStuffingEnabled && (currentByte == 0xFF)
            currentByte = 0
            bitPosition = isFF ? 1 : 0
        }
    }

    /// Writes the specified number of bits from a value.
    ///
    /// The bits are taken from the least significant bits of the value.
    ///
    /// - Parameters:
    ///   - value: The value containing the bits to write.
    ///   - count: The number of bits to write (1-32).
    /// - Throws: ``J2KError/invalidParameter(_:)`` if count is invalid.
    public mutating func writeBits(_ value: UInt32, count: Int) throws {
        guard count >= 1 && count <= 32 else {
            throw J2KError.invalidParameter("Bit count must be between 1 and 32, got \(count)")
        }

        var bitsToWrite = count

        while bitsToWrite > 0 {
            let bitsInCurrentByte = 8 - bitPosition
            let bitsThisIteration = min(bitsToWrite, bitsInCurrentByte)

            // Extract the bits we want to write
            let bitsFromValue = UInt8((value >> (bitsToWrite - bitsThisIteration)) & ((1 << bitsThisIteration) - 1))

            // Position the bits in the current byte
            let shift = bitsInCurrentByte - bitsThisIteration
            currentByte |= bitsFromValue << shift

            bitPosition += bitsThisIteration
            if bitPosition >= 8 {
                buffer.append(currentByte)
                // After 0xFF, MSB of next byte is stuffed as 0: start at position 1
                let isFF = byteStuffingEnabled && (currentByte == 0xFF)
                currentByte = 0
                bitPosition = isFF ? 1 : 0
            }

            bitsToWrite -= bitsThisIteration
        }
    }

    // MARK: - Alignment

    /// Aligns the writer to the next byte boundary.
    ///
    /// If already at a byte boundary, this method does nothing.
    /// Otherwise, it pads the remaining bits with zeros.
    /// When byte stuffing is enabled, ensures proper stuffing after 0xFF.
    public mutating func alignToByte() {
        if bitPosition != 0 {
            buffer.append(currentByte)
            let wasFF = byteStuffingEnabled && (currentByte == 0xFF)
            currentByte = 0
            bitPosition = 0
            // After a 0xFF byte, append a stuffed 0x00 byte per ISO 15444-1 B.10.1
            if wasFF {
                buffer.append(0x00)
            }
        }
    }

    /// Aligns the writer to the next byte boundary, filling with the specified bit.
    ///
    /// - Parameter bit: The bit value to use for padding.
    public mutating func alignToByte(filling bit: Bool) {
        while bitPosition != 0 {
            writeBit(bit)
        }
    }

    // MARK: - JPEG 2000 Specific Operations

    /// Writes a JPEG 2000 marker to the stream.
    ///
    /// - Parameter marker: The marker code (should have 0xFF prefix).
    public mutating func writeMarker(_ marker: UInt16) {
        alignToByte()
        writeUInt16(marker)
    }

    /// Writes a marker segment with the specified length and data.
    ///
    /// - Parameters:
    ///   - marker: The marker code.
    ///   - segmentData: The segment data (not including the length field).
    public mutating func writeMarkerSegment(_ marker: UInt16, segmentData: Data) {
        alignToByte()
        writeUInt16(marker)
        // Length includes the length field itself (2 bytes)
        writeUInt16(UInt16(segmentData.count + 2))
        writeBytes(segmentData)
    }

    // MARK: - Buffer Management

    /// Clears all written data.
    public mutating func clear() {
        buffer.removeAll(keepingCapacity: true)
        currentByte = 0
        bitPosition = 0
    }

    /// Reserves capacity for the specified number of additional bytes.
    ///
    /// - Parameter additionalBytes: The number of additional bytes to reserve.
    public mutating func reserveCapacity(_ additionalBytes: Int) {
        buffer.reserveCapacity(buffer.count + additionalBytes)
    }
}
