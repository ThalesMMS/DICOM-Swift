//
//  DCMWindowingProcessorTests.swift
//  DicomCoreTests
//
//  Unit tests for DCMWindowingProcessor with processing mode selection. These tests verify vDSP,
//  Metal, and Auto mode functionality, backward compatibility, numerical consistency, and edge case
//  handling.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

class DCMWindowingProcessorTests: XCTestCase {

    // MARK: - Processing Mode Tests

    func testProcessingModeVDSP() {
        // Verify explicit vDSP mode produces expected output
        let pixels16: [UInt16] = [0, 1000, 2000, 3000, 4000]
        let center = 2000.0
        let width = 2000.0

        // Apply windowing with explicit vDSP mode
        let result = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .vdsp
        )

        XCTAssertNotNil(result, "vDSP mode should produce output")
        XCTAssertEqual(result?.count, pixels16.count, "Output should have same length as input")

        // Verify windowing transformation
        // Window: center=2000, width=2000 → range [1000, 3000]
        let bytes = [UInt8](result!)
        XCTAssertEqual(bytes[0], 0, "Pixel below window minimum should be 0")
        XCTAssertEqual(bytes[1], 0, "Pixel at window minimum should be 0")
        XCTAssertTrue(bytes[2] >= 125 && bytes[2] <= 130, "Center pixel should be ~127")
        XCTAssertEqual(bytes[3], 255, "Pixel at window maximum should be 255")
        XCTAssertEqual(bytes[4], 255, "Pixel above window maximum should be 255")
    }

    func testProcessingModeMetal() {
        // Verify explicit Metal mode works (or falls back to vDSP if unavailable)
        let pixels16: [UInt16] = [0, 1000, 2000, 3000, 4000]
        let center = 2000.0
        let width = 2000.0

        // Apply windowing with explicit Metal mode
        let result = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .metal
        )

        XCTAssertNotNil(result, "Metal mode should produce output (or fallback to vDSP)")
        XCTAssertEqual(result?.count, pixels16.count, "Output should have same length as input")

        // Verify windowing transformation produces expected range
        let bytes = [UInt8](result!)
        XCTAssertEqual(bytes[0], 0, "Pixel below window minimum should be 0")
        XCTAssertEqual(bytes[3], 255, "Pixel at window maximum should be 255")
    }

    func testProcessingModeAuto() {
        // Test auto mode selection based on image size

        // Small image (512×512 = 262,144 pixels) should use vDSP
        let smallPixels = [UInt16](repeating: 2000, count: 512 * 512)
        let smallResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: smallPixels,
            center: 2000.0,
            width: 2000.0,
            processingMode: .auto
        )
        XCTAssertNotNil(smallResult, "Auto mode should work for small images")
        XCTAssertEqual(smallResult?.count, smallPixels.count, "Output size should match input")

        // Large image (1024×1024 = 1,048,576 pixels) should use Metal if available
        let largePixels = [UInt16](repeating: 2000, count: 1024 * 1024)
        let largeResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: largePixels,
            center: 2000.0,
            width: 2000.0,
            processingMode: .auto
        )
        XCTAssertNotNil(largeResult, "Auto mode should work for large images")
        XCTAssertEqual(largeResult?.count, largePixels.count, "Output size should match input")
    }

    func testAutoSelectionThreshold() {
        // Verify auto-selection threshold at exactly 800×800 pixels (640,000 pixels)
        let center = 2000.0
        let width = 2000.0

        // Just below threshold: 799×799 = 638,401 pixels → should use vDSP
        let belowThresholdPixels = [UInt16](repeating: 2000, count: 799 * 799)
        let belowResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: belowThresholdPixels,
            center: center,
            width: width,
            processingMode: .auto
        )
        XCTAssertNotNil(belowResult, "Auto mode should work for below-threshold images")
        XCTAssertEqual(belowResult?.count, belowThresholdPixels.count)

        // At threshold: 800×800 = 640,000 pixels → should use Metal if available
        let atThresholdPixels = [UInt16](repeating: 2000, count: 800 * 800)
        let atResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: atThresholdPixels,
            center: center,
            width: width,
            processingMode: .auto
        )
        XCTAssertNotNil(atResult, "Auto mode should work for at-threshold images")
        XCTAssertEqual(atResult?.count, atThresholdPixels.count)

        // Above threshold: 801×801 = 641,601 pixels → should use Metal if available
        let aboveThresholdPixels = [UInt16](repeating: 2000, count: 801 * 801)
        let aboveResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: aboveThresholdPixels,
            center: center,
            width: width,
            processingMode: .auto
        )
        XCTAssertNotNil(aboveResult, "Auto mode should work for above-threshold images")
        XCTAssertEqual(aboveResult?.count, aboveThresholdPixels.count)
    }

    func testNumericalConsistency() {
        // Verify vDSP and Metal produce consistent results within ±1 UInt8 tolerance
        // Generate test data with various intensity values
        var pixels16 = [UInt16]()
        for i in 0..<1000 {
            pixels16.append(UInt16(i * 4))  // Range 0 to 3996
        }

        let center = 2000.0
        let width = 2000.0

        // Compute vDSP result
        let vdspResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .vdsp
        )
        XCTAssertNotNil(vdspResult, "vDSP windowing should succeed")

        // Compute Metal result
        let metalResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .metal
        )
        XCTAssertNotNil(metalResult, "Metal windowing should succeed (or fallback)")

        // Compare results pixel by pixel
        let vdspBytes = [UInt8](vdspResult!)
        let metalBytes = [UInt8](metalResult!)

        XCTAssertEqual(vdspBytes.count, metalBytes.count, "Output sizes should match")

        var exactMatches = 0
        var withinTolerance = 0

        for i in 0..<vdspBytes.count {
            let diff = abs(Int(vdspBytes[i]) - Int(metalBytes[i]))
            if diff == 0 {
                exactMatches += 1
            }
            if diff <= 1 {
                withinTolerance += 1
            }
        }

        let exactMatchPercentage = Double(exactMatches) / Double(vdspBytes.count) * 100.0
        let tolerancePercentage = Double(withinTolerance) / Double(vdspBytes.count) * 100.0

        // Expect 99.9%+ exact matches, 100% within ±1 tolerance
        XCTAssertGreaterThan(exactMatchPercentage, 99.0, "Should have >99% exact pixel matches")
        XCTAssertEqual(tolerancePercentage, 100.0, "All pixels should match within ±1 tolerance")
    }

    func testBackwardCompatibility() {
        // Verify calling without processingMode parameter defaults to vDSP
        let pixels16: [UInt16] = [0, 1000, 2000, 3000, 4000]
        let center = 2000.0
        let width = 2000.0

        // Call without mode parameter (default behavior)
        let defaultResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width
        )

        // Call with explicit vDSP mode
        let vdspResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .vdsp
        )

        XCTAssertNotNil(defaultResult, "Default call should succeed")
        XCTAssertNotNil(vdspResult, "vDSP call should succeed")

        // Results should be identical (backward compatibility)
        let defaultBytes = [UInt8](defaultResult!)
        let vdspBytes = [UInt8](vdspResult!)

        XCTAssertEqual(defaultBytes, vdspBytes, "Default mode should match vDSP mode exactly")
    }

    func testMetalFallback() {
        // Verify Metal mode falls back to vDSP gracefully if Metal unavailable
        // This test passes regardless of Metal availability
        let pixels16: [UInt16] = [0, 1000, 2000, 3000, 4000]
        let center = 2000.0
        let width = 2000.0

        // Explicit Metal mode should always return a result (fallback to vDSP if needed)
        let metalResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .metal
        )
        XCTAssertNotNil(metalResult, "Metal mode should produce result or fallback to vDSP")

        // Auto mode should also always work
        let autoResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .auto
        )
        XCTAssertNotNil(autoResult, "Auto mode should produce result with Metal or vDSP")

        // Verify outputs are valid (non-empty, correct size)
        XCTAssertEqual(metalResult?.count, pixels16.count, "Metal result should have correct size")
        XCTAssertEqual(autoResult?.count, pixels16.count, "Auto result should have correct size")
    }

    // MARK: - Edge Case Tests

    func testEdgeCases() {
        // Test 1: Empty input array
        let emptyResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: [],
            center: 2000.0,
            width: 2000.0,
            processingMode: .vdsp
        )
        XCTAssertNil(emptyResult, "Empty array should return nil")

        let emptyMetalResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: [],
            center: 2000.0,
            width: 2000.0,
            processingMode: .metal
        )
        XCTAssertNil(emptyMetalResult, "Empty array should return nil for Metal mode")

        // Test 2: Zero width
        let zeroWidthResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: [1000, 2000, 3000],
            center: 2000.0,
            width: 0.0,
            processingMode: .vdsp
        )
        XCTAssertNil(zeroWidthResult, "Zero width should return nil")

        // Test 3: Negative width
        let negativeWidthResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: [1000, 2000, 3000],
            center: 2000.0,
            width: -100.0,
            processingMode: .vdsp
        )
        XCTAssertNil(negativeWidthResult, "Negative width should return nil")

        // Test 4: Single pixel image (auto mode should use vDSP)
        let singlePixelResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: [2000],
            center: 2000.0,
            width: 2000.0,
            processingMode: .auto
        )
        XCTAssertNotNil(singlePixelResult, "Single pixel should be processed")
        XCTAssertEqual(singlePixelResult?.count, 1, "Should have one output pixel")

        // Test 5: Very large width (should handle gracefully)
        let largeWidthResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: [0, 1000, 2000],
            center: 2000.0,
            width: 100000.0,
            processingMode: .vdsp
        )
        XCTAssertNotNil(largeWidthResult, "Large width should be handled")

        // Test 6: All pixels same value
        let uniformPixels = [UInt16](repeating: 2000, count: 100)
        let uniformResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: uniformPixels,
            center: 2000.0,
            width: 2000.0,
            processingMode: .vdsp
        )
        XCTAssertNotNil(uniformResult, "Uniform pixels should be processed")
        let uniformBytes = [UInt8](uniformResult!)
        // All pixels at center should map to ~127
        for byte in uniformBytes {
            XCTAssertTrue(byte >= 125 && byte <= 130, "Uniform pixels at center should map to ~127")
        }
    }

    // MARK: - Additional Functional Tests

    func testWindowingRange() {
        // Test windowing with different ranges to verify clamping
        let pixels16: [UInt16] = [0, 500, 1000, 1500, 2000, 2500, 3000, 3500, 4000]
        let center = 2000.0
        let width = 1000.0  // Range [1500, 2500]

        let result = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .vdsp
        )

        XCTAssertNotNil(result)
        let bytes = [UInt8](result!)

        // Verify clamping behavior
        XCTAssertEqual(bytes[0], 0, "Value 0 below range should clamp to 0")
        XCTAssertEqual(bytes[1], 0, "Value 500 below range should clamp to 0")
        XCTAssertEqual(bytes[2], 0, "Value 1000 below range should clamp to 0")
        XCTAssertTrue(bytes[3] >= 0 && bytes[3] <= 10, "Value 1500 at min should be ~0")
        XCTAssertTrue(bytes[4] >= 125 && bytes[4] <= 130, "Value 2000 at center should be ~127")
        XCTAssertTrue(bytes[5] >= 245 && bytes[5] <= 255, "Value 2500 at max should be ~255")
        XCTAssertEqual(bytes[6], 255, "Value 3000 above range should clamp to 255")
        XCTAssertEqual(bytes[7], 255, "Value 3500 above range should clamp to 255")
        XCTAssertEqual(bytes[8], 255, "Value 4000 above range should clamp to 255")
    }

    func testLargeImageProcessing() {
        // Test processing of large image (simulates real medical image)
        // 1024×1024 = 1,048,576 pixels (typical CT/MRI slice)
        let pixelCount = 1024 * 1024
        var pixels16 = [UInt16]()

        // Create gradient pattern
        for i in 0..<pixelCount {
            pixels16.append(UInt16(i % 4096))
        }

        let center = 2048.0
        let width = 2048.0

        // Test with vDSP mode
        let vdspResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .vdsp
        )
        XCTAssertNotNil(vdspResult, "vDSP should handle large images")
        XCTAssertEqual(vdspResult?.count, pixelCount, "Output size should match input")

        // Test with auto mode (should select Metal for large image if available)
        let autoResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .auto
        )
        XCTAssertNotNil(autoResult, "Auto mode should handle large images")
        XCTAssertEqual(autoResult?.count, pixelCount, "Output size should match input")
    }

    func testExtremeWindowValues() {
        // Test with extreme window/level values
        let pixels16: [UInt16] = [0, 16384, 32768, 49152, 65535]

        // Very narrow window
        let narrowResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 32768.0,
            width: 100.0,
            processingMode: .vdsp
        )
        XCTAssertNotNil(narrowResult, "Narrow window should be handled")

        // Very wide window
        let wideResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 32768.0,
            width: 65535.0,
            processingMode: .vdsp
        )
        XCTAssertNotNil(wideResult, "Wide window should be handled")

        // Window at extreme low center
        let lowCenterResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 100.0,
            width: 200.0,
            processingMode: .vdsp
        )
        XCTAssertNotNil(lowCenterResult, "Low center should be handled")

        // Window at extreme high center
        let highCenterResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: 65000.0,
            width: 200.0,
            processingMode: .vdsp
        )
        XCTAssertNotNil(highCenterResult, "High center should be handled")
    }

    func testAllModesProduceSimilarResults() {
        // Verify all three modes produce similar results for the same input
        let pixels16 = [UInt16](0..<1000).map { UInt16($0 * 4) }
        let center = 2000.0
        let width = 2000.0

        let vdspResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .vdsp
        )

        let metalResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .metal
        )

        let autoResult = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: center,
            width: width,
            processingMode: .auto
        )

        XCTAssertNotNil(vdspResult)
        XCTAssertNotNil(metalResult)
        XCTAssertNotNil(autoResult)

        // All should produce same size output
        XCTAssertEqual(vdspResult?.count, pixels16.count)
        XCTAssertEqual(metalResult?.count, pixels16.count)
        XCTAssertEqual(autoResult?.count, pixels16.count)

        // Results should be consistent within tolerance
        let vdspBytes = [UInt8](vdspResult!)
        let metalBytes = [UInt8](metalResult!)
        let autoBytes = [UInt8](autoResult!)

        for i in 0..<vdspBytes.count {
            let vdspMetalDiff = abs(Int(vdspBytes[i]) - Int(metalBytes[i]))
            let vdspAutoDiff = abs(Int(vdspBytes[i]) - Int(autoBytes[i]))

            XCTAssertLessThanOrEqual(vdspMetalDiff, 1, "vDSP and Metal should match within ±1 at index \(i)")
            XCTAssertLessThanOrEqual(vdspAutoDiff, 1, "vDSP and Auto should match within ±1 at index \(i)")
        }
    }

    // MARK: - Single-Pass Algorithm Tests

    func testSinglePassCorrectness() {
        // Verify single-pass implementation produces correct statistics across various pixel distributions

        // Test 1: Uniform distribution (all same value)
        let uniformPixels: [UInt16] = [UInt16](repeating: 2000, count: 100)
        var minVal = 0.0, maxVal = 0.0, meanVal = 0.0
        let uniformHistogram = DCMWindowingProcessor.calculateHistogram(
            pixels16: uniformPixels,
            minValue: &minVal,
            maxValue: &maxVal,
            meanValue: &meanVal
        )

        XCTAssertEqual(minVal, 2000.0, accuracy: 0.001, "Uniform min should be 2000")
        XCTAssertEqual(maxVal, 2000.0, accuracy: 0.001, "Uniform max should be 2000")
        XCTAssertEqual(meanVal, 2000.0, accuracy: 0.001, "Uniform mean should be 2000")
        XCTAssertEqual(uniformHistogram.count, 256, "Histogram should have 256 bins")

        let uniformMetrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: uniformPixels)
        XCTAssertEqual(uniformMetrics["mean"] ?? -1, 2000.0, accuracy: 0.001, "Quality metrics mean should match")
        XCTAssertEqual(uniformMetrics["std_deviation"] ?? -1, 0.0, accuracy: 0.001, "Uniform pixels should have zero std deviation")

        // Test 2: Linear gradient distribution
        let gradientPixels: [UInt16] = (0..<1000).map { UInt16($0 * 4) }  // 0 to 3996
        var gradMinVal = 0.0, gradMaxVal = 0.0, gradMeanVal = 0.0
        let gradientHistogram = DCMWindowingProcessor.calculateHistogram(
            pixels16: gradientPixels,
            minValue: &gradMinVal,
            maxValue: &gradMaxVal,
            meanValue: &gradMeanVal
        )

        XCTAssertEqual(gradMinVal, 0.0, accuracy: 0.001, "Gradient min should be 0")
        XCTAssertEqual(gradMaxVal, 3996.0, accuracy: 0.001, "Gradient max should be 3996")
        XCTAssertEqual(gradMeanVal, 1998.0, accuracy: 1.0, "Gradient mean should be approximately 1998")
        XCTAssertEqual(gradientHistogram.count, 256, "Histogram should have 256 bins")

        let gradientMetrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: gradientPixels)
        XCTAssertEqual(gradientMetrics["mean"] ?? -1, 1998.0, accuracy: 1.0, "Quality metrics mean should match histogram")
        XCTAssertEqual(gradientMetrics["min_value"] ?? -1, 0.0, accuracy: 0.001, "Quality metrics min should match")
        XCTAssertEqual(gradientMetrics["max_value"] ?? -1, 3996.0, accuracy: 0.001, "Quality metrics max should match")

        // Verify std deviation is computed correctly for gradient
        // Standard deviation of 0,4,8,...,3996 (linear sequence with step 4)
        let expectedStdDev = sqrt((1000.0 * 1000.0 - 1.0) / 12.0) * 4.0
        XCTAssertEqual(gradientMetrics["std_deviation"] ?? -1, expectedStdDev, accuracy: expectedStdDev * 0.01,
                       "Gradient std deviation should match expected formula")

        // Test 3: Binary distribution (only two values)
        let binaryPixels: [UInt16] = Array(repeating: 1000, count: 50) + Array(repeating: 3000, count: 50)
        var binMinVal = 0.0, binMaxVal = 0.0, binMeanVal = 0.0
        let binaryHistogram = DCMWindowingProcessor.calculateHistogram(
            pixels16: binaryPixels,
            minValue: &binMinVal,
            maxValue: &binMaxVal,
            meanValue: &binMeanVal
        )

        XCTAssertEqual(binMinVal, 1000.0, accuracy: 0.001, "Binary min should be 1000")
        XCTAssertEqual(binMaxVal, 3000.0, accuracy: 0.001, "Binary max should be 3000")
        XCTAssertEqual(binMeanVal, 2000.0, accuracy: 0.001, "Binary mean should be 2000")
        XCTAssertEqual(binaryHistogram.count, 256, "Histogram should have 256 bins")

        let binaryMetrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: binaryPixels)
        XCTAssertEqual(binaryMetrics["mean"] ?? -1, 2000.0, accuracy: 0.001, "Binary mean should be 2000")

        // Binary std deviation: sqrt(E[(X-μ)²]) = sqrt(0.5*(1000-2000)² + 0.5*(3000-2000)²) = 1000
        let expectedBinaryStdDev = 1000.0
        XCTAssertEqual(binaryMetrics["std_deviation"] ?? -1, expectedBinaryStdDev, accuracy: 1.0,
                       "Binary std deviation should be 1000")

        // Test 4: Edge case - single pixel
        let singlePixel: [UInt16] = [5000]
        var singleMinVal = 0.0, singleMaxVal = 0.0, singleMeanVal = 0.0
        let singleHistogram = DCMWindowingProcessor.calculateHistogram(
            pixels16: singlePixel,
            minValue: &singleMinVal,
            maxValue: &singleMaxVal,
            meanValue: &singleMeanVal
        )

        XCTAssertEqual(singleMinVal, 5000.0, accuracy: 0.001, "Single pixel min should be 5000")
        XCTAssertEqual(singleMaxVal, 5000.0, accuracy: 0.001, "Single pixel max should be 5000")
        XCTAssertEqual(singleMeanVal, 5000.0, accuracy: 0.001, "Single pixel mean should be 5000")
        XCTAssertEqual(singleHistogram.count, 256, "Histogram should have 256 bins")

        let singleMetrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: singlePixel)
        XCTAssertEqual(singleMetrics["mean"] ?? -1, 5000.0, accuracy: 0.001, "Single pixel mean should be 5000")
        XCTAssertEqual(singleMetrics["std_deviation"] ?? -1, 0.0, accuracy: 0.001, "Single pixel std deviation should be 0")

        // Test 5: Verify histogram consistency - calculateHistogram and calculateQualityMetrics
        // should produce identical statistical values
        let testPixels: [UInt16] = (0..<500).map { UInt16($0 * 8) }  // 0 to 3992
        var histMinVal = 0.0, histMaxVal = 0.0, histMeanVal = 0.0
        _ = DCMWindowingProcessor.calculateHistogram(
            pixels16: testPixels,
            minValue: &histMinVal,
            maxValue: &histMaxVal,
            meanValue: &histMeanVal
        )

        let metricsDict = DCMWindowingProcessor.calculateQualityMetrics(pixels16: testPixels)

        // Both methods should return identical min, max, mean values
        XCTAssertEqual(histMinVal, metricsDict["min_value"] ?? -1, accuracy: 0.001,
                       "Histogram and quality metrics min should match")
        XCTAssertEqual(histMaxVal, metricsDict["max_value"] ?? -1, accuracy: 0.001,
                       "Histogram and quality metrics max should match")
        XCTAssertEqual(histMeanVal, metricsDict["mean"] ?? -1, accuracy: 0.001,
                       "Histogram and quality metrics mean should match")

        // Test 6: Large image consistency (1024x1024 pixels)
        let largePixelCount = 1024 * 1024
        var largePixels = [UInt16]()
        for i in 0..<largePixelCount {
            largePixels.append(UInt16(i % 4096))
        }

        var largeMinVal = 0.0, largeMaxVal = 0.0, largeMeanVal = 0.0
        let largeHistogram = DCMWindowingProcessor.calculateHistogram(
            pixels16: largePixels,
            minValue: &largeMinVal,
            maxValue: &largeMaxVal,
            meanValue: &largeMeanVal
        )

        let largeMetrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: largePixels)

        // Verify consistency on large dataset
        XCTAssertEqual(largeMinVal, largeMetrics["min_value"] ?? -1, accuracy: 0.001,
                       "Large image min should match between methods")
        XCTAssertEqual(largeMaxVal, largeMetrics["max_value"] ?? -1, accuracy: 0.001,
                       "Large image max should match between methods")
        XCTAssertEqual(largeMeanVal, largeMetrics["mean"] ?? -1, accuracy: 0.001,
                       "Large image mean should match between methods")
        XCTAssertEqual(largeHistogram.count, 256, "Large image histogram should have 256 bins")

        // Verify histogram bins sum to total pixel count
        let totalHistogramCount = largeHistogram.reduce(0, +)
        XCTAssertEqual(totalHistogramCount, largePixelCount,
                       "Histogram bins should sum to total pixel count")
    }

    // MARK: - V2 API Tests (Type-Safe WindowSettings)

    func testCalculateOptimalWindowLevelV2() {
        // Test calculateOptimalWindowLevelV2 returns WindowSettings struct
        let pixels16: [UInt16] = (0..<1000).map { UInt16($0 * 4) }

        // V2 API returns WindowSettings
        let settingsV2 = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels16)

        // Verify it returns correct type
        XCTAssertTrue(type(of: settingsV2) == WindowSettings.self, "Should return WindowSettings struct")

        // Verify values are reasonable for the given pixel distribution
        XCTAssertGreaterThan(settingsV2.center, 0.0, "Center should be positive")
        XCTAssertGreaterThan(settingsV2.width, 0.0, "Width should be positive")
        XCTAssertTrue(settingsV2.isValid, "Settings should be valid")
    }

    func testCalculateOptimalWindowLevelV2EmptyInput() {
        // Test V2 API with empty input
        let emptyPixels: [UInt16] = []
        let settings = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: emptyPixels)

        // Should return settings with zero values (not crash)
        XCTAssertEqual(settings.center, 0.0, "Empty input should return zero center")
        XCTAssertEqual(settings.width, 0.0, "Empty input should return zero width")
        XCTAssertFalse(settings.isValid, "Empty input settings should be invalid")
    }

    func testGetPresetValuesV2WithPresetEnum() {
        // Test getPresetValuesV2 with MedicalPreset enum
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)

        // Verify it returns WindowSettings struct
        XCTAssertTrue(type(of: lungSettings) == WindowSettings.self, "Should return WindowSettings struct")

        // Verify lung preset has expected range (center around -600, width around 1500)
        XCTAssertEqual(lungSettings.center, -600.0, accuracy: 50.0, "Lung preset center should be around -600")
        XCTAssertEqual(lungSettings.width, 1500.0, accuracy: 200.0, "Lung preset width should be around 1500")
        XCTAssertTrue(lungSettings.isValid, "Lung preset should have valid settings")
    }

    func testGetPresetValuesV2AllPresets() {
        // Test all presets to ensure V2 API returns correct WindowSettings for each
        let allPresets: [MedicalPreset] = [
            .lung, .abdomen, .bone, .brain, .mediastinum, .liver,
            .angiography, .pelvis, .spine, .softTissue, .pulmonaryEmbolism,
            .mammography, .petScan, .custom
        ]

        for preset in allPresets {
            let settingsV2 = DCMWindowingProcessor.getPresetValuesV2(preset: preset)

            // Verify each preset has valid settings
            XCTAssertTrue(settingsV2.isValid,
                         "Preset \(preset) should have valid settings")
            XCTAssertGreaterThan(settingsV2.width, 0.0,
                               "Preset \(preset) should have positive width")
        }
    }

    func testGetPresetValuesV2WithNameString() {
        // Test getPresetValuesV2 with string name
        let lungSettings = DCMWindowingProcessor.getPresetValuesV2(named: "lung")
        XCTAssertNotNil(lungSettings, "Should find lung preset by name")

        // Test case insensitivity
        let lungSettingsUpper = DCMWindowingProcessor.getPresetValuesV2(named: "LUNG")
        XCTAssertNotNil(lungSettingsUpper, "Should find preset with uppercase name")
        XCTAssertEqual(lungSettingsUpper?.center, lungSettings?.center, "Case should not matter")

        // Verify returned values are valid
        XCTAssertTrue(lungSettings!.isValid, "Lung preset should have valid settings")
        XCTAssertEqual(lungSettings!.center, -600.0, accuracy: 50.0, "Lung preset center should be around -600")
    }

    func testGetPresetValuesV2WithInvalidName() {
        // Test V2 API with invalid preset name
        let invalidSettings = DCMWindowingProcessor.getPresetValuesV2(named: "nonexistent")
        XCTAssertNil(invalidSettings, "Should return nil for invalid preset name")

        let emptySettings = DCMWindowingProcessor.getPresetValuesV2(named: "")
        XCTAssertNil(emptySettings, "Should return nil for empty preset name")
    }

    func testGetPresetValuesV2AllNamedPresets() {
        // Test all preset names work with V2 API
        let presetNames = [
            "lung", "abdomen", "bone", "brain", "mediastinum", "liver",
            "angiography", "pelvis", "spine", "soft tissue", "pulmonary embolism",
            "mammography", "pet scan"
        ]

        for name in presetNames {
            let settingsV2 = DCMWindowingProcessor.getPresetValuesV2(named: name)

            XCTAssertNotNil(settingsV2, "Should find preset: \(name)")

            // Verify each preset has valid settings
            XCTAssertTrue(settingsV2!.isValid, "Preset '\(name)' should have valid settings")
            XCTAssertGreaterThan(settingsV2!.width, 0.0, "Preset '\(name)' should have positive width")
        }
    }

    func testBatchCalculateOptimalWindowLevelV2() {
        // Test batchCalculateOptimalWindowLevelV2 with multiple images
        let image1Pixels: [UInt16] = (0..<500).map { UInt16($0 * 4) }
        let image2Pixels: [UInt16] = (500..<1000).map { UInt16($0 * 4) }
        let image3Pixels: [UInt16] = [UInt16](repeating: 2000, count: 100)

        let imagePixels = [image1Pixels, image2Pixels, image3Pixels]

        // V2 API returns array of WindowSettings
        let batchSettings = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(imagePixels: imagePixels)

        // Verify return type
        XCTAssertTrue(type(of: batchSettings) == [WindowSettings].self, "Should return [WindowSettings]")
        XCTAssertEqual(batchSettings.count, 3, "Should return 3 WindowSettings")

        // Verify settings for each image
        for i in 0..<batchSettings.count {
            XCTAssertTrue(batchSettings[i].isValid,
                         "Image \(i) settings should be valid")
            XCTAssertGreaterThan(batchSettings[i].width, 0,
                                "Image \(i) width should be positive")
        }

        // Verify individual results make sense
        XCTAssertGreaterThan(batchSettings[0].center, 0.0, "Image 1 should have positive center")
        XCTAssertGreaterThan(batchSettings[1].center, batchSettings[0].center,
                            "Image 2 should have higher center than Image 1")
        XCTAssertEqual(batchSettings[2].center, 2000.0, accuracy: 100.0,
                      "Image 3 uniform pixels should have center around 2000")
    }

    func testBatchCalculateOptimalWindowLevelV2EmptyInput() {
        // Test batch V2 API with empty array
        let emptyBatch: [[UInt16]] = []
        let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(imagePixels: emptyBatch)

        XCTAssertTrue(results.isEmpty, "Empty batch should return empty array")
    }

    func testBatchCalculateOptimalWindowLevelV2WithEmptyImages() {
        // Test batch V2 API with array containing empty image
        let imagePixels: [[UInt16]] = [
            [1000, 2000, 3000],  // Valid image
            [],                   // Empty image
            [5000, 6000, 7000]   // Valid image
        ]

        let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(imagePixels: imagePixels)

        XCTAssertEqual(results.count, 3, "Should return 3 results")
        XCTAssertTrue(results[0].isValid, "First image should have valid settings")
        XCTAssertFalse(results[1].isValid, "Empty image should have invalid settings")
        XCTAssertTrue(results[2].isValid, "Third image should have valid settings")
    }

    func testGetPresetNameWithWindowSettings() {
        // Test getPresetName with WindowSettings parameter
        let lungPreset = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        let presetName = DCMWindowingProcessor.getPresetName(settings: lungPreset)

        XCTAssertNotNil(presetName, "Should identify lung preset")
        XCTAssertEqual(presetName, "Lung", "Should return 'Lung' display name")

        // Test with bone preset
        let bonePreset = DCMWindowingProcessor.getPresetValuesV2(preset: .bone)
        let boneName = DCMWindowingProcessor.getPresetName(settings: bonePreset)
        XCTAssertEqual(boneName, "Bone", "Should return 'Bone' display name")

        // Test with brain preset
        let brainPreset = DCMWindowingProcessor.getPresetValuesV2(preset: .brain)
        let brainName = DCMWindowingProcessor.getPresetName(settings: brainPreset)
        XCTAssertEqual(brainName, "Brain", "Should return 'Brain' display name")
    }

    func testGetPresetNameWithCustomSettings() {
        // Test getPresetName with custom WindowSettings that don't match any preset
        let customSettings = WindowSettings(center: 12345.0, width: 67890.0)
        let presetName = DCMWindowingProcessor.getPresetName(settings: customSettings)

        XCTAssertNil(presetName, "Should return nil for custom settings that don't match presets")
    }

    func testGetPresetNameWithTolerance() {
        // Test getPresetName with tolerance parameter
        let lungPreset = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)

        // Slightly modify lung preset values (within tolerance)
        let nearLungSettings = WindowSettings(
            center: lungPreset.center + 25.0,
            width: lungPreset.width + 25.0
        )

        // Should still match with default tolerance (50.0)
        let matchedName = DCMWindowingProcessor.getPresetName(settings: nearLungSettings)
        XCTAssertEqual(matchedName, "Lung", "Should match lung preset within tolerance")

        // Should not match with very tight tolerance
        let noMatchName = DCMWindowingProcessor.getPresetName(settings: nearLungSettings, tolerance: 10.0)
        XCTAssertNil(noMatchName, "Should not match with tight tolerance")
    }

    func testGetPresetNameWithKnownValues() {
        // Test that getPresetName(settings:) correctly identifies known preset values
        let lungSettings = WindowSettings(center: -600.0, width: 1500.0)

        let presetName = DCMWindowingProcessor.getPresetName(settings: lungSettings)

        XCTAssertEqual(presetName, "Lung", "Should identify lung preset from center/width values")
    }

    func testV2APIsWithRealWorldMedicalValues() {
        // Test V2 APIs with realistic medical imaging pixel values

        // Simulate CT chest scan (typical Hounsfield units range)
        let ctChestPixels: [UInt16] = [
            500,   // Lung tissue (around -500 HU after rescale)
            1024,  // Water equivalent (0 HU)
            1524,  // Soft tissue (+500 HU)
            2048,  // Bone (+1024 HU)
            100    // Air (-900+ HU)
        ]

        let ctSettings = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: ctChestPixels)
        XCTAssertTrue(ctSettings.isValid, "CT chest should produce valid settings")
        XCTAssertGreaterThan(ctSettings.width, 0.0, "CT chest should have positive width")

        // Simulate MRI brain scan (arbitrary intensity units)
        let mriPixels: [UInt16] = (0..<1000).map { UInt16($0) }
        let mriSettings = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: mriPixels)
        XCTAssertTrue(mriSettings.isValid, "MRI brain should produce valid settings")

        // Batch process both
        let batchResults = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
            imagePixels: [ctChestPixels, mriPixels]
        )
        XCTAssertEqual(batchResults.count, 2, "Should process both scans")
        XCTAssertTrue(batchResults.allSatisfy { $0.isValid }, "All scans should have valid settings")
    }

    func testV2APIsReturnCodableTypes() {
        // Verify that V2 APIs return Codable types for serialization
        let pixels: [UInt16] = [1000, 2000, 3000, 4000, 5000]
        let settings = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)

        // Verify WindowSettings is Codable by encoding/decoding
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        do {
            let jsonData = try encoder.encode(settings)
            let decodedSettings = try decoder.decode(WindowSettings.self, from: jsonData)

            XCTAssertEqual(decodedSettings.center, settings.center, "Decoded center should match")
            XCTAssertEqual(decodedSettings.width, settings.width, "Decoded width should match")
        } catch {
            XCTFail("WindowSettings should be Codable: \(error)")
        }
    }
}
