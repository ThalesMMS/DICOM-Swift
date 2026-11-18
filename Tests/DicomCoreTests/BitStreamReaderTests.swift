//
//  BitStreamReaderTests.swift
//  DicomCoreTests
//
//  Checks individual-bit reads, byte stuffing, empty streams, and bitstream boundaries.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

// MARK: - BitStreamReader Tests

final class BitStreamReaderTests: XCTestCase {

    // MARK: - Basic Bit Reading Tests

    func testReadSingleBitFromSingleByte() throws {
        // Single byte 0b10110011 (0xB3)
        let data = Data([0xB3])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 1)

        // Expect bits in MSB-first order: 1,0,1,1,0,0,1,1
        XCTAssertEqual(try reader.readBit(), 1, "First bit of 0xB3 should be 1")
        XCTAssertEqual(try reader.readBit(), 0, "Second bit of 0xB3 should be 0")
        XCTAssertEqual(try reader.readBit(), 1, "Third bit of 0xB3 should be 1")
        XCTAssertEqual(try reader.readBit(), 1, "Fourth bit of 0xB3 should be 1")
        XCTAssertEqual(try reader.readBit(), 0, "Fifth bit of 0xB3 should be 0")
        XCTAssertEqual(try reader.readBit(), 0, "Sixth bit of 0xB3 should be 0")
        XCTAssertEqual(try reader.readBit(), 1, "Seventh bit of 0xB3 should be 1")
        XCTAssertEqual(try reader.readBit(), 1, "Eighth bit of 0xB3 should be 1")
    }

    func testReadBitFromAllZeroByte() throws {
        let data = Data([0x00])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 1)

        for i in 0..<8 {
            XCTAssertEqual(try reader.readBit(), 0, "Bit \(i) of 0x00 should be 0")
        }
    }

    func testReadBitFromAllOnesByte() throws {
        let data = Data([0xFF, 0x00]) // 0xFF followed by stuffing byte 0x00
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 2)

        for i in 0..<8 {
            XCTAssertEqual(try reader.readBit(), 1, "Bit \(i) of 0xFF (stuffed) should be 1")
        }
    }

    // MARK: - readBits Tests

    func testReadZeroBits() throws {
        let data = Data([0xFF, 0x00])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 2)
        let result = try reader.readBits(0)
        XCTAssertEqual(result, 0, "Reading 0 bits should return 0")
    }

    func testReadOneBit() throws {
        let data = Data([0x80]) // 1000 0000
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 1)
        let result = try reader.readBits(1)
        XCTAssertEqual(result, 1, "First bit of 0x80 should be 1")
    }

    func testReadEightBits() throws {
        let data = Data([0xA5]) // 1010 0101
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 1)
        let result = try reader.readBits(8)
        XCTAssertEqual(result, 0xA5, "Reading full byte 0xA5 should return 0xA5")
    }

    func testReadSixteenBits() throws {
        let data = Data([0x12, 0x34])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 2)
        let result = try reader.readBits(16)
        XCTAssertEqual(result, 0x1234, "Reading two bytes should yield 0x1234")
    }

    func testReadFourBits() throws {
        let data = Data([0xAB]) // 1010 1011
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 1)
        let high = try reader.readBits(4)
        let low = try reader.readBits(4)
        XCTAssertEqual(high, 0xA, "High nibble should be 0xA")
        XCTAssertEqual(low, 0xB, "Low nibble should be 0xB")
    }

    func testReadBitsAcrossMultipleBytes() throws {
        // 0b11110000 0b00001111 - should read 1111000000001111 as 16 bits
        let data = Data([0xF0, 0x0F])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 2)
        let result = try reader.readBits(16)
        XCTAssertEqual(result, 0xF00F, "Cross-byte read should work correctly")
    }

    func testReadBitsMaxValue() throws {
        let data = Data([0xFF, 0x00, 0xFF, 0x00]) // Two 0xFF bytes with stuffing
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 4)
        let result = try reader.readBits(16)
        XCTAssertEqual(result, 0xFFFF, "Reading 16 ones should give 0xFFFF")
    }

    // MARK: - Byte Stuffing Tests

    func testByteStuffingRemoval() throws {
        // 0xFF 0x00 is byte stuffing - the 0x00 is dropped, keeping 0xFF as data
        let data = Data([0xFF, 0x00, 0x42]) // 0xFF (stuffed) + 0x42
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 3)

        // Read 8 bits - should get 0xFF (the stuffing pair is treated as one 0xFF byte)
        let firstByte = try reader.readBits(8)
        XCTAssertEqual(firstByte, 0xFF, "Byte stuffing (0xFF 0x00) should produce 0xFF")

        // Next 8 bits should be 0x42
        let secondByte = try reader.readBits(8)
        XCTAssertEqual(secondByte, 0x42, "After byte stuffing, next byte 0x42 should follow")
    }

    func testByteStuffingDoesNotConsumeNonStuffingByte() throws {
        // 0xFF followed by non-0x00 is a marker, not stuffed data
        // The reader should stop before the marker
        let data = Data([0x55, 0xFF, 0xD9]) // 0x55, then EOI marker (0xFF 0xD9)
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 3)

        // Read 8 bits - should get 0x55
        let byte = try reader.readBits(8)
        XCTAssertEqual(byte, 0x55, "Should read 0x55 before the marker")
    }

    func testMultipleByteStuffedBytes() throws {
        // Sequence: 0xFF 0x00 0xFF 0x00 represents two 0xFF bytes
        let data = Data([0xFF, 0x00, 0xFF, 0x00])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 4)

        let first = try reader.readBits(8)
        let second = try reader.readBits(8)
        XCTAssertEqual(first, 0xFF, "First stuffed 0xFF should decode to 0xFF")
        XCTAssertEqual(second, 0xFF, "Second stuffed 0xFF should decode to 0xFF")
    }

    // MARK: - Error Condition Tests

    func testReadBitFromEmptyStreamThrows() {
        let data = Data()
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 0)
        XCTAssertThrowsError(try reader.readBit(), "Reading from empty stream should throw") { error in
            if case DICOMError.invalidDICOMFormat(let reason) = error {
                XCTAssertFalse(reason.isEmpty, "Error reason should not be empty")
            } else {
                XCTFail("Expected DICOMError.invalidDICOMFormat, got \(error)")
            }
        }
    }

    func testReadBitPastEndOfDataThrows() throws {
        let data = Data([0xAB])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 1)

        // Read all 8 bits
        for _ in 0..<8 {
            _ = try reader.readBit()
        }

        // Reading one more should throw
        XCTAssertThrowsError(try reader.readBit(), "Reading past end of data should throw") { error in
            if case DICOMError.invalidDICOMFormat(_) = error {
                // Expected
            } else {
                XCTFail("Expected DICOMError.invalidDICOMFormat, got \(error)")
            }
        }
    }

    func testReadBitsWithNegativeCountThrows() {
        let data = Data([0xAB])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 1)
        XCTAssertThrowsError(try reader.readBits(-1), "Negative count should throw") { error in
            if case DICOMError.invalidDICOMFormat(let reason) = error {
                XCTAssertTrue(reason.contains("Invalid bit count"), "Reason should mention invalid bit count, got: \(reason)")
            } else {
                XCTFail("Expected DICOMError.invalidDICOMFormat, got \(error)")
            }
        }
    }

    func testReadBitsWithCountAbove16Throws() {
        let data = Data([0xAB, 0xCD, 0xEF])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 3)
        XCTAssertThrowsError(try reader.readBits(17), "Count > 16 should throw") { error in
            if case DICOMError.invalidDICOMFormat(let reason) = error {
                XCTAssertTrue(reason.contains("Invalid bit count"), "Reason should mention invalid bit count, got: \(reason)")
            } else {
                XCTFail("Expected DICOMError.invalidDICOMFormat, got \(error)")
            }
        }
    }

    func testTruncatedJPEGDataThrows() {
        // 0xFF at end of stream without following byte
        let data = Data([0x42, 0xFF])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 2)
        // Reading 8 bits (the 0x42 byte) is fine
        XCTAssertNoThrow(try reader.readBits(8), "Reading 0x42 should succeed")
        // Reading next bit requires more data, encounters truncated 0xFF
        XCTAssertThrowsError(try reader.readBit(), "Truncated 0xFF should throw") { error in
            if case DICOMError.invalidDICOMFormat(let reason) = error {
                XCTAssertTrue(reason.lowercased().contains("truncated") || reason.lowercased().contains("0xFF".lowercased()),
                              "Error should mention truncation, got: \(reason)")
            } else {
                XCTFail("Expected DICOMError.invalidDICOMFormat, got \(error)")
            }
        }
    }

    // MARK: - Boundary / Range Tests

    func testStartIndexOffset() throws {
        // Data starts with a prefix that should be ignored
        let data = Data([0xDE, 0xAD, 0xAB, 0xCD])
        // Start reading at byte index 2 (0xAB)
        var reader = BitStreamReader(data: data, startIndex: 2, endIndex: 4)
        let result = try reader.readBits(16)
        XCTAssertEqual(result, 0xABCD, "Should read from startIndex, ignoring prefix bytes")
    }

    func testEndIndexBoundary() throws {
        // endIndex limits reading to a subset of data
        let data = Data([0x12, 0x34, 0x56, 0x78])
        // Only allow reading first 2 bytes
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 2)
        let result = try reader.readBits(16)
        XCTAssertEqual(result, 0x1234, "Should be able to read up to endIndex")

        // Attempting to read past endIndex should throw
        XCTAssertThrowsError(try reader.readBit(), "Reading past endIndex should throw")
    }

    func testReadMaxBits16WithValue() throws {
        // Test readBits with maximum allowed count of 16
        let data = Data([0b10101010, 0b11001100])
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 2)
        let result = try reader.readBits(16)
        XCTAssertEqual(result, 0b1010101011001100, "Reading 16 bits should pack both bytes MSB-first")
    }

    func testSequentialBitReadsConsistency() throws {
        // Read the same data in two different ways and verify consistency
        let data = Data([0xAB, 0xCD])

        // Method 1: Read 8 bits twice
        var reader1 = BitStreamReader(data: data, startIndex: 0, endIndex: 2)
        let byte1 = try reader1.readBits(8)
        let byte2 = try reader1.readBits(8)

        // Method 2: Read 4 bits four times
        var reader2 = BitStreamReader(data: data, startIndex: 0, endIndex: 2)
        let nibble1 = try reader2.readBits(4)
        let nibble2 = try reader2.readBits(4)
        let nibble3 = try reader2.readBits(4)
        let nibble4 = try reader2.readBits(4)

        XCTAssertEqual(byte1, 0xAB, "First byte read should be 0xAB")
        XCTAssertEqual(byte2, 0xCD, "Second byte read should be 0xCD")
        XCTAssertEqual(nibble1, 0xA, "First nibble should be 0xA")
        XCTAssertEqual(nibble2, 0xB, "Second nibble should be 0xB")
        XCTAssertEqual(nibble3, 0xC, "Third nibble should be 0xC")
        XCTAssertEqual(nibble4, 0xD, "Fourth nibble should be 0xD")

        XCTAssertEqual((nibble1 << 4) | nibble2, byte1, "Nibbles should compose back to first byte")
        XCTAssertEqual((nibble3 << 4) | nibble4, byte2, "Nibbles should compose back to second byte")
    }

    // MARK: - JPEGMarker Constants Tests

    func testJPEGMarkerPrefix() {
        XCTAssertEqual(JPEGMarker.prefix, 0xFF, "JPEG marker prefix should be 0xFF")
    }

    func testJPEGMarkerStuffingByte() {
        XCTAssertEqual(JPEGMarker.stuffingByte, 0x00, "JPEG stuffing byte should be 0x00")
    }

    func testJPEGMarkerSOI() {
        XCTAssertEqual(JPEGMarker.soi.rawValue, 0xD8, "SOI marker should be 0xD8")
    }

    func testJPEGMarkerEOI() {
        XCTAssertEqual(JPEGMarker.eoi.rawValue, 0xD9, "EOI marker should be 0xD9")
    }

    func testJPEGMarkerSOS() {
        XCTAssertEqual(JPEGMarker.sos.rawValue, 0xDA, "SOS marker should be 0xDA")
    }

    func testJPEGMarkerDHT() {
        XCTAssertEqual(JPEGMarker.dht.rawValue, 0xC4, "DHT marker should be 0xC4")
    }

    func testJPEGMarkerSOF3() {
        XCTAssertEqual(JPEGMarker.sof3.rawValue, 0xC3, "SOF3 marker should be 0xC3")
    }

    func testJPEGMarkerDRI() {
        XCTAssertEqual(JPEGMarker.dri.rawValue, 0xDD, "DRI marker should be 0xDD")
    }

    // MARK: - Regression / Additional Coverage Tests

    func testReadBitsMixedWithReadBit() throws {
        // Interleave readBits and readBit calls
        let data = Data([0b11001010]) // 1,1,0,0,1,0,1,0
        var reader = BitStreamReader(data: data, startIndex: 0, endIndex: 1)
        let bit1 = try reader.readBit()   // 1
        let bits2 = try reader.readBits(3) // 1,0,0 → 4
        let bit3 = try reader.readBit()   // 1
        let bits4 = try reader.readBits(3) // 0,1,0 → 2

        XCTAssertEqual(bit1, 1, "First bit should be 1")
        XCTAssertEqual(bits2, 0b100, "Next 3 bits 1,0,0 should be 4")
        XCTAssertEqual(bit3, 1, "Fifth bit should be 1")
        XCTAssertEqual(bits4, 0b010, "Last 3 bits 0,1,0 should be 2")
    }

    func testBitStreamReaderCreationWithEqualStartEnd() {
        // startIndex == endIndex means no data to read
        let data = Data([0xAB])
        var reader = BitStreamReader(data: data, startIndex: 1, endIndex: 1)
        XCTAssertThrowsError(try reader.readBit(), "Empty range should throw when reading")
    }
}
