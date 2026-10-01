import Foundation

// MARK: - Bit Stream Reader

/// Bitstream reader for JPEG Lossless entropy-coded data.
/// Handles bit-level access with automatic byte stuffing removal
/// (0xFF 0x00 → 0xFF) and marker detection (0xFF 0xXX where XX != 0x00).
///
/// The reader maintains a bit buffer for efficient bit extraction and
/// automatically handles JPEG byte stuffing according to ITU-T T.81.
internal struct BitStreamReader {
    /// Source data containing JPEG bitstream
    private let data: Data

    /// Current byte position in data
    private var byteIndex: Int

    /// End boundary (exclusive) for reading
    private let endIndex: Int

    /// Bit buffer (accumulates up to 32 bits)
    private var bitBuffer: UInt32 = 0

    /// Number of valid bits currently in buffer
    private var bitsAvailable: Int = 0

    /// Creates a bitstream reader for JPEG entropy-coded data
    /// - Parameters:
    ///   - data: Complete JPEG bitstream
    ///   - startIndex: Byte offset where entropy-coded data begins
    ///   - endIndex: Byte offset where entropy-coded data ends
    internal init(data: Data, startIndex: Int, endIndex: Int) {
        self.data = data
        self.byteIndex = startIndex
        self.endIndex = endIndex
    }

    /// Fills the internal bit buffer with bytes from `data` until at least 25 bits are available, a JPEG marker is encountered, or the end of the specified range is reached.
    ///
    /// Appends bytes (MSB-first) to `bitBuffer` and increments `bitsAvailable`. When the sequence `0xFF 0x00` is seen it treats it as JPEG byte stuffing (keeps `0xFF` and skips the `0x00`). If a `0xFF` is followed by a byte other than `0x00` the function stops and leaves `byteIndex` positioned at the `0xFF` marker byte so the caller can handle the marker.
    /// - Throws: `DICOMError.invalidDICOMFormat` if a `0xFF` byte is encountered at the end of the available data before any buffered bits can satisfy the current read.
    private mutating func fillBuffer() throws {
        while bitsAvailable <= 24 && byteIndex < endIndex {
            let byte = data[byteIndex]
            byteIndex += 1

            // Handle byte stuffing
            if byte == JPEGMarker.prefix {
                // 0xFF byte encountered - check next byte
                if byteIndex < endIndex {
                    let nextByte = data[byteIndex]
                    if nextByte == JPEGMarker.stuffingByte {
                        // 0xFF 0x00: byte stuffing - skip 0x00, keep 0xFF
                        byteIndex += 1
                        bitBuffer = (bitBuffer << 8) | UInt32(byte)
                        bitsAvailable += 8
                    } else {
                        // 0xFF 0xXX: marker detected - stop reading
                        // Back up to marker for proper marker handling
                        byteIndex -= 1
                        return
                    }
                } else {
                    // 0xFF at end of data without following byte
                    byteIndex -= 1
                    if bitsAvailable > 0 {
                        return
                    }
                    throw DICOMError.invalidDICOMFormat(reason: "Truncated JPEG data: 0xFF at end of stream")
                }
            } else {
                // Normal byte - add to buffer
                bitBuffer = (bitBuffer << 8) | UInt32(byte)
                bitsAvailable += 8
            }
        }
    }

    /// Reads the next bit from the JPEG bitstream using MSB-first order.
    /// - Returns: `1` if the next bit is one, `0` if it is zero.
    /// - Throws: `DICOMError.invalidDICOMFormat` if the JPEG bitstream is truncated or no bits are available.
    internal mutating func readBit() throws -> Int {
        // Refill buffer if empty
        if bitsAvailable == 0 {
            try fillBuffer()
        }

        guard bitsAvailable > 0 else {
            throw DICOMError.invalidDICOMFormat(reason: "Unexpected end of JPEG bitstream")
        }

        // Extract MSB from buffer
        bitsAvailable -= 1
        let bit = Int((bitBuffer >> bitsAvailable) & 1)
        return bit
    }

    /// Reads `count` bits (MSB-first) from the bitstream and returns them packed into an integer.
    /// - Parameter count: Number of bits to read; must be between 0 and 16. If `0`, the method returns `0`.
    /// - Returns: An integer containing the `count` bits read, with the first-read bit placed at the most significant position of the returned value.
    /// - Throws: `DICOMError.invalidDICOMFormat` if `count` is outside 0–16, or if the bitstream ends unexpectedly while reading.
    internal mutating func readBits(_ count: Int) throws -> Int {
        guard count >= 0 && count <= 16 else {
            throw DICOMError.invalidDICOMFormat(reason: "Invalid bit count: \(count) (must be 0-16)")
        }

        guard count > 0 else {
            return 0
        }

        var result = 0
        for _ in 0..<count {
            let bit = try readBit()
            result = (result << 1) | bit
        }
        return result
    }

    /// Byte-aligns the reader (discarding any buffered padding bits) and
    /// consumes the next restart marker (RST0...RST7), returning its index.
    /// - Throws: `DICOMError.invalidDICOMFormat` when the next marker is not
    ///   a restart marker or the entropy-coded data ends first.
    internal mutating func consumeRestartMarker() throws -> Int {
        guard bitsAvailable <= 7 else {
            throw DICOMError.invalidDICOMFormat(
                reason: "Expected JPEG restart marker (RSTn) at the restart boundary but found additional entropy data"
            )
        }
        if bitsAvailable > 0 {
            let paddingMask = UInt32((1 << bitsAvailable) - 1)
            guard bitBuffer & paddingMask == paddingMask else {
                throw DICOMError.invalidDICOMFormat(
                    reason: "Expected JPEG restart marker (RSTn) after all-ones entropy padding"
                )
            }
        }
        bitBuffer = 0
        bitsAvailable = 0

        guard byteIndex + 1 < endIndex else {
            throw DICOMError.invalidDICOMFormat(
                reason: "Entropy-coded data ended while expecting a JPEG restart marker (RSTn)"
            )
        }
        guard data[byteIndex] == JPEGMarker.prefix else {
            throw DICOMError.invalidDICOMFormat(
                reason: "Expected JPEG restart marker (RSTn) at the restart boundary but found entropy byte "
                    + "0x\(String(data[byteIndex], radix: 16, uppercase: true))"
            )
        }

        while byteIndex + 1 < endIndex, data[byteIndex + 1] == JPEGMarker.prefix {
            byteIndex += 1
        }
        guard byteIndex + 1 < endIndex else {
            throw DICOMError.invalidDICOMFormat(
                reason: "Entropy-coded data ended while expecting a JPEG restart marker (RSTn)"
            )
        }

        let marker = data[byteIndex + 1]
        guard JPEGMarker.isRestart(marker) else {
            throw DICOMError.invalidDICOMFormat(
                reason: "Expected JPEG restart marker (RSTn) in entropy-coded data but found marker "
                    + "0xFF\(String(marker, radix: 16, uppercase: true))"
            )
        }
        byteIndex += 2
        return Int(marker - 0xD0)
    }
}
