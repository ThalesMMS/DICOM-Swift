//
//  JPEGLosslessPredictionTests.swift
//  DicomCoreTests
//
//  Checks the initial lossless JPEG predictor under the declared point transform.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class JPEGLosslessPredictionTests: XCTestCase {

    // MARK: - First-Order Prediction Tests

    func testFirstOrderPrediction() throws {
        // Test the first-order predictor (Selection Value 1)
        // This tests the computePredictor method with left neighbor prediction

        let decoder = JPEGLosslessDecoder()

        // Test parameters
        let width = 4
        let height = 3
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)  // 2^15 = 32768 for 16-bit

        // Sample pixel buffer (partially filled for testing)
        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 32000  // First pixel, intentionally different from the default predictor
        pixels[1] = 30000  // Second pixel in row 0
        pixels[2] = 28000  // Third pixel in row 0
        pixels[3] = 26000  // Fourth pixel in row 0
        pixels[4] = 35000  // First pixel in row 1

        // Test case 1: First pixel of first row (x=0, y=0)
        // Expected: default predictor (2^15 = 32768)
        let pred1 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 1)
        XCTAssertEqual(pred1, defaultPredictor, "First pixel should use default predictor 2^(P-1)")

        // Test case 2: Second pixel of first row (x=1, y=0)
        // Expected: left neighbor (pixels[0] = 32000)
        let pred2 = decoder.computePredictor(x: 1, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 1)
        XCTAssertEqual(pred2, Int(pixels[0]), "Second pixel should use left neighbor as predictor")

        // Test case 3: Third pixel of first row (x=2, y=0)
        // Expected: left neighbor (pixels[1] = 30000)
        let pred3 = decoder.computePredictor(x: 2, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 1)
        XCTAssertEqual(pred3, 30000, "Third pixel should use left neighbor as predictor")

        // Test case 4: First pixel of second row (x=0, y=1)
        // Expected: above-row predictor (pixels[0] = 32000)
        let pred4 = decoder.computePredictor(x: 0, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 1)
        XCTAssertEqual(pred4, Int(pixels[0]), "Row starts after the first row should use the pixel above")

        // Test case 5: Second pixel of second row (x=1, y=1)
        // Expected: left neighbor (pixels[4] = 35000)
        let pred5 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 1)
        XCTAssertEqual(pred5, 35000, "Second pixel of row should use left neighbor as predictor")

        // Test with different precision (12-bit)
        let precision12 = 12
        let defaultPredictor12 = 1 << (precision12 - 1)  // 2^11 = 2048 for 12-bit

        let pred6 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision12, selectionValue: 1)
        XCTAssertEqual(pred6, defaultPredictor12, "12-bit precision should use 2^11 = 2048 as default predictor")

        // Test with different precision (8-bit)
        let precision8 = 8
        let defaultPredictor8 = 1 << (precision8 - 1)  // 2^7 = 128 for 8-bit

        let pred7 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision8, selectionValue: 1)
        XCTAssertEqual(pred7, defaultPredictor8, "8-bit precision should use 2^7 = 128 as default predictor")
    }

    func testFirstOrderPredictionEdgeCases() throws {
        // Test edge cases for first-order prediction

        let decoder = JPEGLosslessDecoder()

        // Test with minimum width (1 pixel)
        let width1 = 1
        let height1 = 3
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        var pixels1 = [UInt16](repeating: 0, count: width1 * height1)
        pixels1[0] = 32768

        // The first sample uses the default predictor; later row starts use the pixel above.
        for y in 0..<height1 {
            let pred = decoder.computePredictor(x: 0, y: y, pixels: pixels1, width: width1, precision: precision, selectionValue: 1)
            let expected = y == 0 ? defaultPredictor : Int(pixels1[y - 1])
            XCTAssertEqual(pred, expected, "Single-column row starts should use the default predictor only for the first sample")
        }

        // Test with maximum precision values
        let pixels16bit = [UInt16](repeating: 65535, count: 10)
        let pred16 = decoder.computePredictor(x: 1, y: 0, pixels: pixels16bit, width: 5, precision: 16, selectionValue: 1)
        XCTAssertEqual(pred16, 65535, "Should handle maximum 16-bit value")

        // Test with minimum precision values
        let pixels16bitMin = [UInt16](repeating: 0, count: 10)
        let predMin = decoder.computePredictor(x: 1, y: 0, pixels: pixels16bitMin, width: 5, precision: 16, selectionValue: 1)
        XCTAssertEqual(predMin, 0, "Should handle minimum value (0)")
    }

    func testInitialPredictorHonorsPointTransform() throws {
        let decoder = JPEGLosslessDecoder()
        let pixels = [UInt16](repeating: 0, count: 1)

        let predictor = decoder.computePredictor(
            x: 0,
            y: 0,
            pixels: pixels,
            width: 1,
            precision: 16,
            selectionValue: 1,
            pointTransform: 3,
            isFirstSampleInScan: true
        )

        XCTAssertEqual(predictor, 1 << 12, "Initial predictor should use 2^(P - Pt - 1)")
    }

    // MARK: - Selection Value Tests

    func testSelectionValue0NoPrediction() throws {
        // Test selection value 0: No prediction (direct coding)
        // Expected: predictor = 0 (no prediction)

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 3
        let precision = 16
        var pixels = [UInt16](repeating: 0, count: width * height)

        // Populate some test pixels
        pixels[0] = 32768
        pixels[1] = 30000
        pixels[4] = 35000

        // Test various positions - all should return 0 (no prediction)
        let pred1 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 0)
        XCTAssertEqual(pred1, 0, "Selection value 0 should always return 0 (no prediction)")

        let pred2 = decoder.computePredictor(x: 1, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 0)
        XCTAssertEqual(pred2, 0, "Selection value 0 should always return 0 (no prediction)")

        let pred3 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 0)
        XCTAssertEqual(pred3, 0, "Selection value 0 should always return 0 (no prediction)")
    }

    func testSelectionValue1PredictorA() throws {
        // Test selection value 1: Prediction from pixel A (left neighbor)
        // This is already tested in testFirstOrderPrediction, but included here for completeness

        let decoder = JPEGLosslessDecoder()

        let width = 4
        let height = 2
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 32768
        pixels[1] = 30000
        pixels[4] = 35000

        // First pixel: default predictor
        let pred1 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 1)
        XCTAssertEqual(pred1, defaultPredictor, "First pixel should use default predictor 2^(P-1)")

        // Second pixel: left neighbor (A)
        let pred2 = decoder.computePredictor(x: 1, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 1)
        XCTAssertEqual(pred2, 32768, "Should use left neighbor (A) as predictor")

        // First pixel of second row: default predictor
        let pred3 = decoder.computePredictor(x: 0, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 1)
        XCTAssertEqual(pred3, defaultPredictor, "First pixel of row should use default predictor")
    }

    func testSelectionValue2PredictorB() throws {
        // Test selection value 2: Prediction from pixel B (above neighbor)

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 3
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 32000  // Row 0, col 0, intentionally different from defaultPredictor
        pixels[1] = 30000  // Row 0, col 1
        pixels[2] = 28000  // Row 0, col 2
        pixels[3] = 35000  // Row 1, col 0

        // First row: default predictor
        let pred1 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 2)
        XCTAssertEqual(pred1, defaultPredictor, "First row should use default predictor")

        let pred2 = decoder.computePredictor(x: 1, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 2)
        XCTAssertEqual(pred2, defaultPredictor, "First row should use default predictor")

        // Second row: should use pixel above (B)
        let pred3 = decoder.computePredictor(x: 0, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 2)
        XCTAssertEqual(pred3, Int(pixels[0]), "Should use pixel above (B) as predictor")

        let pred4 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 2)
        XCTAssertEqual(pred4, 30000, "Should use pixel above (B) as predictor")
    }

    func testSelectionValue3PredictorC() throws {
        // Test selection value 3: Prediction from pixel C (diagonal upper-left)

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 3
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 32000  // Row 0, col 0, intentionally different from defaultPredictor
        pixels[1] = 30000  // Row 0, col 1
        pixels[2] = 28000  // Row 0, col 2

        // First row: default predictor
        let pred1 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 3)
        XCTAssertEqual(pred1, defaultPredictor, "First row should use default predictor")

        let pred2 = decoder.computePredictor(x: 1, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 3)
        XCTAssertEqual(pred2, defaultPredictor, "First row should use default predictor")

        // First column of second row: row-start predictor uses the pixel above
        let pred3 = decoder.computePredictor(x: 0, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 3)
        let expectedPred3 = Int(pixels[0])
        XCTAssertEqual(pred3, expectedPred3, "First column should use the pixel above as predictor")

        // Interior pixel: should use diagonal upper-left (C)
        let pred4 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 3)
        XCTAssertEqual(pred4, expectedPred3, "Should use diagonal upper-left (C) as predictor")

        let pred5 = decoder.computePredictor(x: 2, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 3)
        XCTAssertEqual(pred5, 30000, "Should use diagonal upper-left (C) as predictor")
    }

    func testSelectionValue4PredictorAPlusBMinusC() throws {
        // Test selection value 4: Prediction = A + B - C

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 3
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 100   // C (row 0, col 0)
        pixels[1] = 200   // B for (1,1) (row 0, col 1)
        pixels[3] = 150   // A for (1,1) (row 1, col 0)

        // First row, first column: default predictor
        let pred1 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 4)
        XCTAssertEqual(pred1, defaultPredictor, "First pixel should use default predictor")

        // First row: default predictor
        let pred2 = decoder.computePredictor(x: 1, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 4)
        XCTAssertEqual(pred2, defaultPredictor, "First row should use default predictor")

        // First column: row-start predictor uses the pixel above
        let pred3 = decoder.computePredictor(x: 0, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 4)
        XCTAssertEqual(pred3, 100, "First column should use the pixel above as predictor")

        // Interior pixel: A + B - C = 150 + 200 - 100 = 250
        let pred4 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 4)
        XCTAssertEqual(pred4, 250, "Should compute A + B - C = 150 + 200 - 100 = 250")
    }

    func testSelectionValue5PredictorAPlusHalfBMinusC() throws {
        // Test selection value 5: Prediction = A + ((B - C) >> 1)

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 3
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 100   // C (row 0, col 0)
        pixels[1] = 200   // B for (1,1) (row 0, col 1)
        pixels[3] = 150   // A for (1,1) (row 1, col 0)

        // First row, first column: default predictor
        let pred1 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 5)
        XCTAssertEqual(pred1, defaultPredictor, "First pixel should use default predictor")

        // Interior pixel: A + ((B - C) >> 1) = 150 + ((200 - 100) >> 1) = 150 + 50 = 200
        let pred2 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 5)
        XCTAssertEqual(pred2, 200, "Should compute A + ((B - C) >> 1) = 150 + ((200 - 100) >> 1) = 200")

        // Test with odd difference
        pixels[0] = 100   // C
        pixels[1] = 201   // B (B - C = 101, >> 1 = 50)
        pixels[3] = 150   // A

        let pred3 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 5)
        XCTAssertEqual(pred3, 200, "Should compute A + ((B - C) >> 1) = 150 + ((201 - 100) >> 1) = 200")
    }

    func testSelectionValue6PredictorBPlusHalfAMinusC() throws {
        // Test selection value 6: Prediction = B + ((A - C) >> 1)

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 3
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 100   // C (row 0, col 0)
        pixels[1] = 200   // B for (1,1) (row 0, col 1)
        pixels[3] = 150   // A for (1,1) (row 1, col 0)

        // First row, first column: default predictor
        let pred1 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 6)
        XCTAssertEqual(pred1, defaultPredictor, "First pixel should use default predictor")

        // Interior pixel: B + ((A - C) >> 1) = 200 + ((150 - 100) >> 1) = 200 + 25 = 225
        let pred2 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 6)
        XCTAssertEqual(pred2, 225, "Should compute B + ((A - C) >> 1) = 200 + ((150 - 100) >> 1) = 225")

        // Test with odd difference
        pixels[0] = 100   // C
        pixels[1] = 200   // B
        pixels[3] = 151   // A (A - C = 51, >> 1 = 25)

        let pred3 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 6)
        XCTAssertEqual(pred3, 225, "Should compute B + ((A - C) >> 1) = 200 + ((151 - 100) >> 1) = 225")
    }

    func testSelectionValue7PredictorAveragePlusB() throws {
        // Test selection value 7: Prediction = (A + B) / 2

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 3
        let precision = 16
        let defaultPredictor = 1 << (precision - 1)

        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 100   // C (row 0, col 0)
        pixels[1] = 200   // B for (1,1) (row 0, col 1)
        pixels[3] = 150   // A for (1,1) (row 1, col 0)

        // First row, first column: default predictor
        let pred1 = decoder.computePredictor(x: 0, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 7)
        XCTAssertEqual(pred1, defaultPredictor, "First pixel should use default predictor")

        // First row (y=0): default predictor (implementation behavior)
        let pred2 = decoder.computePredictor(x: 1, y: 0, pixels: pixels, width: width, precision: precision, selectionValue: 7)
        XCTAssertEqual(pred2, defaultPredictor, "First row should use default predictor")

        // First column (x=0): row-start predictor uses the pixel above
        let pred3 = decoder.computePredictor(x: 0, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 7)
        XCTAssertEqual(pred3, 100, "First column should use the pixel above as predictor")

        // Interior pixel: (A + B) / 2 = (150 + 200) / 2 = 175
        let pred4 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 7)
        XCTAssertEqual(pred4, 175, "Should compute (A + B) / 2 = (150 + 200) / 2 = 175")

        // Test with odd sum
        pixels[1] = 201   // B (A + B = 351, / 2 = 175)
        let pred5 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 7)
        XCTAssertEqual(pred5, 175, "Should compute (A + B) / 2 = (150 + 201) / 2 = 175")
    }

    func testSelectionValueInvalidValue() throws {
        // Test that invalid selection values (> 7) are handled gracefully

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 3
        let precision = 16
        var pixels = [UInt16](repeating: 0, count: width * height)
        pixels[0] = 1
        pixels[width + 0] = 5

        var pred1 = -1
        XCTAssertNoThrow(
            pred1 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 8)
        )
        XCTAssertEqual(pred1, 5, "Invalid selection value should fall back to Selection Value 1 left-neighbor behavior")

        // Selection value 15 (invalid)
        var pred2 = -1
        XCTAssertNoThrow(
            pred2 = decoder.computePredictor(x: 1, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 15)
        )
        XCTAssertEqual(pred2, 5, "Invalid selection value should fall back to Selection Value 1 left-neighbor behavior")

        var leftEdgePredictor = -1
        XCTAssertNoThrow(
            leftEdgePredictor = decoder.computePredictor(x: 0, y: 1, pixels: pixels, width: width, precision: precision, selectionValue: 8)
        )
        XCTAssertEqual(leftEdgePredictor, 1, "Invalid selection value at the left edge should use the pixel above")
    }

    func testAllSelectionValuesWithEdgeCases() throws {
        // Test all selection values with edge case pixel values

        let decoder = JPEGLosslessDecoder()

        let width = 3
        let height = 3
        let precision = 16

        // Test with maximum pixel values
        let pixelsMax = [UInt16](repeating: 65535, count: width * height)

        for selectionValue in 0...7 {
            let pred = decoder.computePredictor(x: 2, y: 2, pixels: pixelsMax, width: width, precision: precision, selectionValue: selectionValue)
            // Should not crash and produce a value
            XCTAssertGreaterThanOrEqual(pred, 0, "Selection value \(selectionValue) should produce valid predictor")
        }

        // Test with minimum pixel values
        let pixelsMin = [UInt16](repeating: 0, count: width * height)

        for selectionValue in 0...7 {
            let pred = decoder.computePredictor(x: 2, y: 2, pixels: pixelsMin, width: width, precision: precision, selectionValue: selectionValue)
            // Should not crash and produce a value
            XCTAssertGreaterThanOrEqual(pred, 0, "Selection value \(selectionValue) should produce valid predictor")
        }

        // Test with mixed pixel values
        var pixelsMixed = [UInt16](repeating: 0, count: width * height)
        pixelsMixed[0] = 10000  // C
        pixelsMixed[1] = 20000  // B
        pixelsMixed[3] = 30000  // A

        for selectionValue in 0...7 {
            let pred = decoder.computePredictor(x: 1, y: 1, pixels: pixelsMixed, width: width, precision: precision, selectionValue: selectionValue)
            // Should not crash and produce a value
            XCTAssertGreaterThanOrEqual(pred, 0, "Selection value \(selectionValue) should produce valid predictor")
        }
    }
}
