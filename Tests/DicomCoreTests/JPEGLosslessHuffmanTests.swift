//
//  JPEGLosslessHuffmanTests.swift
//  DicomCoreTests
//
//  Checks lossless JPEG Huffman table parsing with multiple tables and malformed table data.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class JPEGLosslessHuffmanTests: XCTestCase {

    // MARK: - Huffman Table Parsing Tests

    func testHuffmanTableParsing() throws {
        // Test Huffman table construction with a simple example
        // This tests the buildHuffmanDecodingTables method

        // Create a synthetic JPEG Lossless bitstream with DHT marker
        var jpegData = Data()

        // SOI marker (Start of Image)
        jpegData.append(contentsOf: [0xFF, 0xD8])

        // DHT marker (Define Huffman Table)
        jpegData.append(contentsOf: [0xFF, 0xC4])

        // Simple Huffman table:
        // - Table class 0 (DC), table ID 0
        // - Symbol counts: 2 symbols of length 2, 3 symbols of length 3
        // - Symbol values: 0, 1, 2, 3, 4
        let symbolCounts: [UInt8] = [
            0,  // Length 1: 0 symbols
            2,  // Length 2: 2 symbols
            3,  // Length 3: 3 symbols
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  // Lengths 4-16: 0 symbols (13 more zeros)
        ]
        let symbolValues: [UInt8] = [0, 1, 2, 3, 4]

        // DHT length includes: 2 (length field itself) + 1 (table info) + 16 (counts) + 5 (values) = 24
        let dhtLength: UInt16 = 2 + 1 + 16 + UInt16(symbolValues.count)
        jpegData.append(UInt8(dhtLength >> 8))
        jpegData.append(UInt8(dhtLength & 0xFF))

        // Table class (0) and ID (0)
        jpegData.append(0x00)

        // Symbol counts (16 bytes)
        jpegData.append(contentsOf: symbolCounts)

        // Symbol values
        jpegData.append(contentsOf: symbolValues)

        // SOF3 marker (Start of Frame - Lossless)
        jpegData.append(contentsOf: [0xFF, 0xC3])
        let sof3Length: UInt16 = 11  // 2 + 1 + 2 + 2 + 1 + 3
        jpegData.append(UInt8(sof3Length >> 8))
        jpegData.append(UInt8(sof3Length & 0xFF))
        jpegData.append(16)  // Precision: 16-bit
        jpegData.append(0)   // Height high byte
        jpegData.append(2)   // Height low byte (2 pixels)
        jpegData.append(0)   // Width high byte
        jpegData.append(2)   // Width low byte (2 pixels)
        jpegData.append(1)   // 1 component
        jpegData.append(1)   // Component ID
        jpegData.append(0x11) // Sampling factors (1x1)
        jpegData.append(0)   // Quantization table selector

        // SOS marker (Start of Scan)
        jpegData.append(contentsOf: [0xFF, 0xDA])
        let sosLength: UInt16 = 8  // 2 + 1 + 2 + 3
        jpegData.append(UInt8(sosLength >> 8))
        jpegData.append(UInt8(sosLength & 0xFF))
        jpegData.append(1)   // 1 component
        jpegData.append(1)   // Component ID
        jpegData.append(0x00) // DC table 0, AC table 0
        jpegData.append(1)   // Selection value (predictor ID)
        jpegData.append(0)   // End spectral (must be 0)
        jpegData.append(0)   // Successive approximation (must be 0)

        // Compressed pixel data for 2x2 image (4 pixels)
        // Using symbol 0 (SSSS=0, difference=0) for all pixels
        // Symbol 0 has 2-bit code "00" based on the Huffman table above
        // 4 pixels × 2 bits = 8 bits = 1 byte: 00 00 00 00 = 0x00
        jpegData.append(0x00)

        // EOI marker (End of Image)
        jpegData.append(0xFF)
        jpegData.append(0xD9)

        // Create decoder and parse the data
        let decoder = JPEGLosslessDecoder()

        // The decode method should parse markers, build Huffman tables, and decode pixels.
        do {
            let result = try decoder.decode(data: jpegData)
            XCTAssertEqual(result.width, 2)
            XCTAssertEqual(result.height, 2)
            XCTAssertEqual(result.bitDepth, 16)
            XCTAssertEqual(result.pixels, [32768, 32768, 32768, 32768])
        } catch {
            XCTFail("Huffman table parsing or pixel decoding failed with error: \(error)")
        }
    }

    func testHuffmanTableParsingWithMultipleTables() throws {
        // Test parsing multiple Huffman tables in a single DHT marker

        var jpegData = Data()

        // SOI marker
        jpegData.append(contentsOf: [0xFF, 0xD8])

        // DHT marker with two tables
        jpegData.append(contentsOf: [0xFF, 0xC4])

        // First table: class 0, ID 0
        let symbolCounts1: [UInt8] = [
            1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ]
        let symbolValues1: [UInt8] = [0, 1, 2]

        // Second table: class 0, ID 1
        let symbolCounts2: [UInt8] = [
            0, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ]
        let symbolValues2: [UInt8] = [5, 6, 7]

        // Total DHT payload length (length field includes itself)
        let table1Size = 1 + 16 + symbolValues1.count
        let table2Size = 1 + 16 + symbolValues2.count
        let dhtLength: UInt16 = 2 + UInt16(table1Size + table2Size)
        jpegData.append(UInt8(dhtLength >> 8))
        jpegData.append(UInt8(dhtLength & 0xFF))

        // First table
        jpegData.append(0x00)  // Class 0, ID 0
        jpegData.append(contentsOf: symbolCounts1)
        jpegData.append(contentsOf: symbolValues1)

        // Second table
        jpegData.append(0x01)  // Class 0, ID 1
        jpegData.append(contentsOf: symbolCounts2)
        jpegData.append(contentsOf: symbolValues2)

        // SOF3 marker
        jpegData.append(contentsOf: [0xFF, 0xC3])
        let sof3Length: UInt16 = 11
        jpegData.append(UInt8(sof3Length >> 8))
        jpegData.append(UInt8(sof3Length & 0xFF))
        jpegData.append(16)  // Precision
        jpegData.append(0)   // Height high
        jpegData.append(2)   // Height low
        jpegData.append(0)   // Width high
        jpegData.append(2)   // Width low
        jpegData.append(1)   // 1 component
        jpegData.append(1)   // Component ID
        jpegData.append(0x11) // Sampling factors
        jpegData.append(0)   // Quantization table

        // SOS marker
        jpegData.append(contentsOf: [0xFF, 0xDA])
        let sosLength: UInt16 = 8
        jpegData.append(UInt8(sosLength >> 8))
        jpegData.append(UInt8(sosLength & 0xFF))
        jpegData.append(1)   // 1 component
        jpegData.append(1)   // Component ID
        jpegData.append(0x00) // DC table 0, AC table 0
        jpegData.append(1)   // Selection value
        jpegData.append(0)   // End spectral
        jpegData.append(0)   // Successive approximation

        // Compressed pixel data for 2x2 image (4 pixels)
        // Using symbol 0 from table 0 (SSSS=0, difference=0) for all pixels
        // Symbol 0 has 1-bit code "0" based on symbolCounts1 (1 symbol of length 1)
        // 4 pixels × 1 bit = 4 bits, padded to byte: 0000 0000 = 0x00
        jpegData.append(0x00)

        // EOI marker (End of Image)
        jpegData.append(contentsOf: [0xFF, 0xD9])

        // Decode should successfully parse both tables
        let decoder = JPEGLosslessDecoder()

        do {
            _ = try decoder.decode(data: jpegData)
        } catch {
            XCTFail("Failed to parse multiple Huffman tables: \(error)")
        }
    }

    func testHuffmanTableParsingInvalidTable() throws {
        // Test that invalid Huffman table (too many symbols) is rejected

        var jpegData = Data()

        // SOI marker
        jpegData.append(contentsOf: [0xFF, 0xD8])

        // DHT marker with invalid symbol count (> 256)
        jpegData.append(contentsOf: [0xFF, 0xC4])

        // Symbol counts that add up to > 256 (invalid)
        let symbolCounts: [UInt8] = [
            255, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ]

        let dhtLength: UInt16 = 2 + 1 + 16 + 257
        jpegData.append(UInt8(dhtLength >> 8))
        jpegData.append(UInt8(dhtLength & 0xFF))
        jpegData.append(0x00)
        jpegData.append(contentsOf: symbolCounts)

        // Add 257 dummy symbol values so parsing reaches the symbol-count guard.
        for _ in 0..<257 {
            jpegData.append(0)
        }

        let decoder = JPEGLosslessDecoder()

        // Should throw error due to invalid table
        XCTAssertThrowsError(try decoder.decode(data: jpegData)) { error in
            guard case DICOMError.invalidDICOMFormat = error else {
                XCTFail("Expected invalidDICOMFormat error, got \(error)")
                return
            }
        }
    }
}
