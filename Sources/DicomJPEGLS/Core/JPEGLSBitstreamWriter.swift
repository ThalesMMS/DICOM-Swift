/// Bitstream writer for JPEG-LS encoding
///
/// Provides bit-level and byte-level writing operations with automatic
/// marker stuffing and buffer management.

import Foundation

/// Bitstream writer for JPEG-LS
///
/// Writes bytes and bits to a buffer, handling marker stuffing automatically.
///
/// Internally the writer accumulates bits in a 64-bit buffer and stores bytes
/// in a contiguous `[UInt8]`, converting to `Data` only once in `getData()`.
/// The 64-bit accumulator means a worst-case 7-bit residual plus a full 32-bit
/// `writeBits` call (39 bits, plus transient stuff bits) always fits without
/// overflow — unlike a 32-bit accumulator, which silently drops high bits when
/// `bitsInBuffer + count > 32`.
public final class JPEGLSBitstreamWriter {
    private var bytes: [UInt8]
    private var bitBuffer: UInt64
    private var bitsInBuffer: Int

    /// Initialize writer with optional initial capacity
    ///
    /// - Parameter capacity: Initial buffer capacity in bytes
    public init(capacity: Int = 4096) {
        self.bytes = []
        self.bytes.reserveCapacity(capacity)
        self.bitBuffer = 0
        self.bitsInBuffer = 0
    }

    /// Get the written data
    ///
    /// - Returns: The complete bitstream data
    /// - Throws: `JPEGLSError` if bit buffer is not flushed
    public func getData() throws -> Data {
        guard bitsInBuffer == 0 else {
            throw JPEGLSError.internalError(
                reason: "Bit buffer not flushed, \(bitsInBuffer) bits remaining"
            )
        }
        return Data(bytes)
    }

    /// Access the accumulated data without copying via a closure.
    ///
    /// This zero-copy path lets callers read the bitstream bytes directly
    /// from the internal buffer, avoiding the allocation that `getData()` would
    /// require when the result is immediately consumed (e.g. written to a file or
    /// passed to a downstream decoder in the same process).
    ///
    /// - Important: The bit buffer must be fully flushed before calling this
    ///   method, otherwise `JPEGLSError.internalError` is thrown.
    /// - Parameter body: A closure that receives a `UnsafeRawBufferPointer` to the
    ///   internal byte buffer.  The pointer is only valid for the duration of the
    ///   closure; do not store it.
    /// - Returns: The value returned by `body`.
    /// - Throws: `JPEGLSError.internalError` if the bit buffer is not flushed.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        guard bitsInBuffer == 0 else {
            throw JPEGLSError.internalError(
                reason: "Bit buffer not flushed, \(bitsInBuffer) bits remaining"
            )
        }
        return try bytes.withUnsafeBytes(body)
    }

    /// Current write position in bytes
    public var currentPosition: Int {
        return bytes.count
    }

    /// Write a single byte to the stream (no stuffing).
    ///
    /// This method writes raw bytes for structured data (marker segments, headers).
    /// Bit-level stuffing for compressed scan data is handled automatically by `writeBits`.
    ///
    /// - Parameter byte: The byte to write
    public func writeByte(_ byte: UInt8) {
        bytes.append(byte)
    }

    /// Write multiple bytes to the stream (no stuffing).
    ///
    /// - Parameter bytes: The bytes to write
    public func writeBytes(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    /// Write bytes from a raw buffer pointer without copying, for
    /// zero-copy bulk transfer of pre-encoded data.
    ///
    /// - Parameter buffer: Raw buffer whose bytes are appended verbatim.
    ///   No JPEG-LS bit-stuffing is applied; use only for pre-encoded data.
    public func writeBytesNoCopy(_ buffer: UnsafeRawBufferPointer) {
        bytes.append(contentsOf: buffer)
    }

    /// Write a 16-bit big-endian value
    ///
    /// - Parameter value: The 16-bit value
    public func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    /// Write a marker (2-byte sequence)
    ///
    /// Does NOT perform marker stuffing for marker bytes
    ///
    /// - Parameter marker: The marker to write
    public func writeMarker(_ marker: JPEGLSMarker) {
        bytes.append(JPEGLSMarker.markerPrefix)
        bytes.append(marker.rawValue)
    }

    /// Write bits to the bitstream with JPEG-LS bit-level stuffing.
    ///
    /// Accumulates bits in a buffer and flushes complete bytes. Implements bit-level
    /// byte stuffing per ISO 14495-1 §9.1: when a byte of 0xFF is emitted, a 0 stuff bit
    /// is inserted at the next bit position, so the subsequent byte has its MSB = 0
    /// (the stuff bit) and its lower 7 bits carry real data.
    ///
    /// The decoder mirrors this: on reading 0xFF, if the next byte has MSB = 0 it is a
    /// stuffed byte and its 7 lower bits are real data; if MSB = 1 it is a marker.
    ///
    /// - Parameters:
    ///   - bits: The bits to write as UInt32
    ///   - count: Number of bits to write (1-32)
    public func writeBits(_ bits: UInt32, count: Int) {
        guard count > 0 && count <= 32 else {
            return
        }

        // Mask to get only the requested bits
        let mask: UInt32 = count < 32 ? ((1 << count) - 1) : UInt32.max
        let maskedBits = bits & mask

        // Add bits to buffer. bitsInBuffer never exceeds 7 on entry, so
        // 7 + 32 = 39 bits always fit in the 64-bit accumulator. Bits above
        // position `bitsInBuffer` are stale garbage from earlier shifts —
        // extraction below masks them out; do not assume they are zero.
        bitBuffer = (bitBuffer << UInt64(count)) | UInt64(maskedBits)
        bitsInBuffer += count

        // Write complete bytes with bit-level stuffing
        while bitsInBuffer >= 8 {
            let shift = bitsInBuffer - 8
            let byte = UInt8(truncatingIfNeeded: bitBuffer >> UInt64(shift))
            bytes.append(byte)
            bitsInBuffer -= 8

            // Bit-level stuffing per ISO 14495-1 §9.1:
            // After emitting a byte of 0xFF, insert a 0 stuff bit at the next bit position.
            // This clear is REQUIRED: the bit at position `bitsInBuffer` is the
            // just-emitted 0xFF's least-significant bit (a 1); clearing it turns
            // that position into the 0 stuff bit when bitsInBuffer grows past it.
            if byte == 0xFF {
                bitBuffer &= ~(UInt64(1) << UInt64(bitsInBuffer))
                bitsInBuffer += 1
            }
        }
    }

    /// Flush remaining bits in buffer
    ///
    /// Pads with zeros to complete the final byte. No stuffing is applied to the
    /// final flushed byte because it is immediately followed by a marker (whose
    /// MSB = 1 signals to the decoder that it is not a stuffed byte).
    public func flush() {
        if bitsInBuffer > 0 {
            let shift = 8 - bitsInBuffer
            let byte = UInt8(truncatingIfNeeded: (bitBuffer << UInt64(shift)) & 0xFF)
            bytes.append(byte)
            bitBuffer = 0
            bitsInBuffer = 0
        }
    }

    /// Reset the bit buffer (typically called at scan boundaries)
    public func resetBitBuffer() {
        flush()
    }

    /// Write a unary code: n zero bits followed by a single 1 bit.
    ///
    /// This is a performance-optimised alternative to calling `writeBits(0, count: 1)` in a loop
    /// followed by `writeBits(1, count: 1)`.  Writing in batches of up to 32 bits reduces
    /// function-call overhead significantly in the Golomb-Rice coding hot path.
    ///
    /// - Parameter n: Number of leading zero bits (must be ≥ 0)
    public func writeUnaryCode(_ n: Int) {
        var remaining = n
        while remaining >= 32 {
            writeBits(0, count: 32)
            remaining -= 32
        }
        // Write the remaining zeros and the terminating 1 in one call
        // (max count = 32 when remaining == 31).
        writeBits(1, count: remaining + 1)
    }

    /// Write n consecutive 1 bits (used for Golomb run-length continuation codes).
    ///
    /// This is a performance-optimised alternative to calling `writeBits(1, count: 1)` in a loop.
    ///
    /// - Parameter n: Number of 1 bits to write (must be ≥ 0)
    public func writeOnes(_ n: Int) {
        var remaining = n
        while remaining >= 32 {
            writeBits(UInt32.max, count: 32)
            remaining -= 32
        }
        if remaining > 0 {
            writeBits(UInt32((1 << remaining) - 1), count: remaining)
        }
    }

    /// Write a marker segment with length field
    ///
    /// - Parameters:
    ///   - marker: The marker to write
    ///   - payload: The segment payload data
    public func writeMarkerSegment(marker: JPEGLSMarker, payload: Data) {
        writeMarker(marker)

        // Length includes the 2 bytes for length field itself
        let length = UInt16(payload.count + 2)
        writeUInt16(length)

        // Write payload without stuffing (it's not compressed data)
        bytes.append(contentsOf: payload)
    }

    /// Reserve space for a marker segment and return position
    ///
    /// Useful for writing segments where length is not known upfront
    ///
    /// - Parameter marker: The marker to write
    /// - Returns: Position where length field starts
    public func beginMarkerSegment(marker: JPEGLSMarker) -> Int {
        writeMarker(marker)
        let lengthPos = bytes.count
        writeUInt16(0)  // Placeholder for length
        return lengthPos
    }

    /// Finalize a marker segment by updating its length
    ///
    /// - Parameter lengthPosition: Position returned by beginMarkerSegment
    public func endMarkerSegment(lengthPosition: Int) {
        let currentPos = bytes.count
        let length = UInt16(currentPos - lengthPosition)

        // Update length field
        bytes[lengthPosition] = UInt8((length >> 8) & 0xFF)
        bytes[lengthPosition + 1] = UInt8(length & 0xFF)
    }
}
