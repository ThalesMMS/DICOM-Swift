//
//  JPEGLosslessDecoderTests.swift
//  DicomCoreTests
//
//  Checks lossless JPEG decoding at first-row, first-column, and single-pixel boundaries.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class JPEGLosslessDecoderTests: XCTestCase {

    // MARK: - Edge Case Tests

    func testEdgeCaseFirstRow() throws {
        // Test that first row (y=0) correctly handles missing pixels above
        // All predictors that need pixel B should use default predictor

        let decoder = JPEGLosslessDecoder()

        let width = 5
        let height = 3
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 1000
        pixels[1] = 2000
        pixels[2] = 3000
        pixels[3] = 4000
        pixels[4] = 5000

        // Test all selection values for first row
        for x in 0..<width {
            // Selection value 0: No prediction (always 0)
            let pred0 = decoder.computePredictor(x: x, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 0)
            XCTAssertEqual(pred0, 0, "Selection value 0 should return 0 for first row at x=\(x)")

            // Selection value 1: Predictor A (left)
            // First column uses default, others use left pixel
            if x == 0 {
                let pred1 = decoder.computePredictor(x: x, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 1)
                XCTAssertEqual(pred1, defaultPredictor, "Selection value 1 should use default predictor for first pixel")
            } else {
                let pred1 = decoder.computePredictor(x: x, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 1)
                XCTAssertEqual(pred1, Int(pixels[x - 1]), "Selection value 1 should use left pixel for first row at x=\(x)")
            }

            // Selection value 2: Predictor B (above) - should use default for first row
            let pred2 = decoder.computePredictor(x: x, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 2)
            XCTAssertEqual(pred2, defaultPredictor, "Selection value 2 should use default predictor for first row at x=\(x)")

            // Selection value 3: Predictor C (diagonal) - should use default for first row
            let pred3 = decoder.computePredictor(x: x, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 3)
            XCTAssertEqual(pred3, defaultPredictor, "Selection value 3 should use default predictor for first row at x=\(x)")

            // Selection value 4: A + B - C - should use default for first row
            let pred4 = decoder.computePredictor(x: x, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 4)
            XCTAssertEqual(pred4, defaultPredictor, "Selection value 4 should use default predictor for first row at x=\(x)")

            // Selection value 5: A + ((B - C) >> 1) - should use default for first row
            let pred5 = decoder.computePredictor(x: x, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 5)
            XCTAssertEqual(pred5, defaultPredictor, "Selection value 5 should use default predictor for first row at x=\(x)")

            // Selection value 6: B + ((A - C) >> 1) - should use default for first row
            let pred6 = decoder.computePredictor(x: x, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 6)
            XCTAssertEqual(pred6, defaultPredictor, "Selection value 6 should use default predictor for first row at x=\(x)")

            // Selection value 7: (A + B) / 2 - should use default for first row
            let pred7 = decoder.computePredictor(x: x, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 7)
            XCTAssertEqual(pred7, defaultPredictor, "Selection value 7 should use default predictor for first row at x=\(x)")
        }
    }

    func testEdgeCaseFirstColumn() throws {
        // Test that first column (x=0) uses the pixel above after the first sample

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 5
        let precision = 16

        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 1000  // Row 0, col 0
        pixels[3] = 2000  // Row 1, col 0
        pixels[6] = 3000  // Row 2, col 0
        pixels[9] = 4000  // Row 3, col 0
        pixels[12] = 5000  // Row 4, col 0

        // Test all selection values for first column (excluding first pixel which is tested separately)
        for y in 1..<height {
            // Selection value 0: No prediction (always 0)
            let pred0 = decoder.computePredictor(x: 0, y: y, pixels: pixels, width: width, precision: precision, selectionValue: 0)
            XCTAssertEqual(pred0, 0, "Selection value 0 should return 0 for first column at y=\(y)")

            let expectedAbove = Int(pixels[(y - 1) * width])

            // Selection value 1: row-start predictor uses pixel above
            let pred1 = decoder.computePredictor(x: 0, y: y, pixels: pixels, width: width, precision: precision, selectionValue: 1)
            XCTAssertEqual(pred1, expectedAbove, "Selection value 1 should use pixel above for first column at y=\(y)")

            // Selection value 2: Predictor B (above) - should use pixel above
            let pred2 = decoder.computePredictor(x: 0, y: y, pixels: pixels, width: width, precision: precision, selectionValue: 2)
            XCTAssertEqual(pred2, expectedAbove, "Selection value 2 should use pixel above for first column at y=\(y)")

            // Selection value 3: row-start predictor uses pixel above
            let pred3 = decoder.computePredictor(x: 0, y: y, pixels: pixels, width: width, precision: precision, selectionValue: 3)
            XCTAssertEqual(pred3, expectedAbove, "Selection value 3 should use pixel above for first column at y=\(y)")

            // Selection value 4: row-start predictor uses pixel above
            let pred4 = decoder.computePredictor(x: 0, y: y, pixels: pixels, width: width, precision: precision, selectionValue: 4)
            XCTAssertEqual(pred4, expectedAbove, "Selection value 4 should use pixel above for first column at y=\(y)")

            // Selection value 5: row-start predictor uses pixel above
            let pred5 = decoder.computePredictor(x: 0, y: y, pixels: pixels, width: width, precision: precision, selectionValue: 5)
            XCTAssertEqual(pred5, expectedAbove, "Selection value 5 should use pixel above for first column at y=\(y)")

            // Selection value 6: row-start predictor uses pixel above
            let pred6 = decoder.computePredictor(x: 0, y: y, pixels: pixels, width: width, precision: precision, selectionValue: 6)
            XCTAssertEqual(pred6, expectedAbove, "Selection value 6 should use pixel above for first column at y=\(y)")

            // Selection value 7: row-start predictor uses pixel above
            let pred7 = decoder.computePredictor(x: 0, y: y, pixels: pixels, width: width, precision: precision, selectionValue: 7)
            XCTAssertEqual(pred7, expectedAbove, "Selection value 7 should use pixel above for first column at y=\(y)")
        }
    }

    func testEdgeCaseSinglePixel() throws {
        // Test that a 1x1 image correctly handles all selection values
        // All should use the default predictor since there are no neighbors

        let decoder = JPEGLosslessDecoder()

        let width = 1
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        let pixels = [UInt16](repeating: 0, count: 1)

        // Test all selection values for single pixel image
        for selectionValue in 0...7 {
            let pred = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: selectionValue)

            if selectionValue == 0 {
                // Selection value 0 always returns 0 (no prediction)
                XCTAssertEqual(pred, 0, "Selection value 0 should return 0 for single pixel")
            } else {
                // All other selection values should use default predictor
                XCTAssertEqual(pred, defaultPredictor, "Selection value \(selectionValue) should use default predictor for single pixel")
            }
        }
    }

    // MARK: - Decode Result Tests

    func testDecodeResultStructure() throws {
        // Test that decode result has correct structure

        let jpegData = makeMinimalJPEGLosslessData(width: 2, height: 2)
        let decoder = JPEGLosslessDecoder()
        let result = try decoder.decode(data: jpegData)

        // Verify result structure
        XCTAssertEqual(result.width, 2, "Width should match SOF3")
        XCTAssertEqual(result.height, 2, "Height should match SOF3")
        XCTAssertEqual(result.bitDepth, 16, "Bit depth should match SOF3")
        XCTAssertEqual(result.pixels.count, 4, "Pixel count should be width × height")

        // Verify pixels are non-nil and reasonable
        for pixel in result.pixels {
            XCTAssertTrue(pixel <= 65535, "16-bit pixel should be in valid range")
        }
    }

    func testDecodeResultPixelCount() throws {
        // Test that pixel count matches dimensions for various sizes

        let testCases: [(width: Int, height: Int)] = [
            (1, 1),
            (2, 2),
            (3, 3),
            (10, 10),
            (16, 8)
        ]

        for testCase in testCases {
            let jpegData = makeMinimalJPEGLosslessData(width: testCase.width, height: testCase.height)
            let decoder = JPEGLosslessDecoder()
            let result = try decoder.decode(data: jpegData)
            let pixelCount = testCase.width * testCase.height

            XCTAssertEqual(result.pixels.count, pixelCount,
                           "Pixel count should match width(\(testCase.width)) × height(\(testCase.height))")
        }
    }

    // MARK: - Edge Case Tests

    func testDecodeWithByteStuffing() throws {
        // Test that byte stuffing (0xFF 0x00) is correctly handled
        // Note: This test verifies the BitStreamReader correctly handles byte stuffing
        // by not throwing errors when encountering 0xFF 0x00 sequences in compressed data

        var jpegData = Data()

        // SOI
        jpegData.append(contentsOf: [0xFF, 0xD8])

        // DHT - simple table with 1-bit codes
        jpegData.append(contentsOf: [0xFF, 0xC4])
        let symbolCounts: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let symbolValues: [UInt8] = [0]
        let dhtLength: UInt16 = 2 + 1 + 16 + UInt16(symbolValues.count)
        jpegData.append(UInt8(dhtLength >> 8))
        jpegData.append(UInt8(dhtLength & 0xFF))
        jpegData.append(0x00)
        jpegData.append(contentsOf: symbolCounts)
        jpegData.append(contentsOf: symbolValues)

        // SOF3 (2x2)
        jpegData.append(contentsOf: [0xFF, 0xC3])
        let sof3Length: UInt16 = 11
        jpegData.append(UInt8(sof3Length >> 8))
        jpegData.append(UInt8(sof3Length & 0xFF))
        jpegData.append(16)
        jpegData.append(0)
        jpegData.append(2)
        jpegData.append(0)
        jpegData.append(2)
        jpegData.append(1)
        jpegData.append(1)
        jpegData.append(0x11)
        jpegData.append(0)

        // SOS
        jpegData.append(contentsOf: [0xFF, 0xDA])
        let sosLength: UInt16 = 8
        jpegData.append(UInt8(sosLength >> 8))
        jpegData.append(UInt8(sosLength & 0xFF))
        jpegData.append(1)
        jpegData.append(1)
        jpegData.append(0x00)
        jpegData.append(1)
        jpegData.append(0)
        jpegData.append(0)

        // Compressed data: 4 pixels with SSSS=0 (1 bit each = 4 bits = 0b0000)
        // Add a 0xFF byte (which should trigger byte stuffing handling)
        // Pattern: 0b0000_0000 (4 pixels) then 0xFF 0x00 (byte stuffing)
        // followed by padding
        jpegData.append(0x00)  // First 4 pixels (bits 0000)
        jpegData.append(0xFF)  // Data byte that needs stuffing
        jpegData.append(0x00)  // Stuffing byte (BitStreamReader should handle this)

        // EOI
        jpegData.append(contentsOf: [0xFF, 0xD9])

        let decoder = JPEGLosslessDecoder()

        // Should decode without error (byte stuffing handled correctly)
        // The BitStreamReader will see 0xFF 0x00 and correctly interpret it as a single 0xFF data byte
        do {
            let result = try decoder.decode(data: jpegData)
            XCTAssertEqual(result.pixels.count, 4, "Should decode 2x2 image = 4 pixels")
        } catch {
            XCTFail("Failed to handle byte stuffing: \(error)")
        }
    }

    func testDecodeWithMinimalImage() throws {
        // Test decoding 1x1 pixel image (minimal possible)

        let jpegData = makeMinimalJPEGLosslessData(width: 1, height: 1)
        let decoder = JPEGLosslessDecoder()
        let result = try decoder.decode(data: jpegData)

        XCTAssertEqual(result.width, 1, "Width should be 1")
        XCTAssertEqual(result.height, 1, "Height should be 1")
        XCTAssertEqual(result.pixels.count, 1, "Should have exactly 1 pixel")
    }

    func testDecodeConsistency() throws {
        // Test that decoding the same data multiple times produces consistent results

        let jpegData = makeMinimalJPEGLosslessData(width: 3, height: 3)
        let decoder = JPEGLosslessDecoder()

        // Decode multiple times
        let result1 = try decoder.decode(data: jpegData)
        let result2 = try decoder.decode(data: jpegData)
        let result3 = try decoder.decode(data: jpegData)

        // Verify all results are identical
        XCTAssertEqual(result1.width, result2.width, "Width should be consistent")
        XCTAssertEqual(result2.width, result3.width, "Width should be consistent")

        XCTAssertEqual(result1.height, result2.height, "Height should be consistent")
        XCTAssertEqual(result2.height, result3.height, "Height should be consistent")

        XCTAssertEqual(result1.pixels, result2.pixels, "Pixels should be consistent")
        XCTAssertEqual(result2.pixels, result3.pixels, "Pixels should be consistent")
    }
}
