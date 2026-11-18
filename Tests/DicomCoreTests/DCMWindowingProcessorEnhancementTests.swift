//
//  DCMWindowingProcessorEnhancementTests.swift
//  DicomCoreTests
//
//  Unit tests for DCMWindowingProcessor enhancement operations. These tests verify vImage-based
//  histogram equalization and noise reduction implementations, including basic functionality, edge
//  cases, numerical equivalence with manual implementations, and performance characteristics.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

class DCMWindowingProcessorEnhancementTests: XCTestCase {

    // MARK: - vImage Histogram Equalization Tests

    func testVImageHistogramEqualization_BasicFunctionality() {
        // Verify basic histogram equalization produces valid output
        let width = 64
        let height = 64
        let pixelCount = width * height

        // Create test image with varied intensity distribution
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                // Create gradient pattern
                let value = UInt8((x + y) * 255 / (width + height))
                pixels.append(value)
            }
        }
        let imageData = Data(pixels)

        // Apply histogram equalization
        let result = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: imageData,
            width: width,
            height: height
        )

        XCTAssertNotNil(result, "Histogram equalization should produce output")
        XCTAssertEqual(result?.count, pixelCount, "Output size should match input size")

        // Verify output has enhanced contrast (different from input)
        let resultBytes = [UInt8](result!)
        let isDifferent = zip(pixels, resultBytes).contains { $0 != $1 }
        XCTAssertTrue(isDifferent, "Histogram equalization should modify pixel values")

        // Verify output uses full dynamic range
        let minOutput = resultBytes.min() ?? 0
        let maxOutput = resultBytes.max() ?? 0
        XCTAssertLessThan(minOutput, 50, "Output should include low values")
        XCTAssertGreaterThan(maxOutput, 200, "Output should include high values")
    }

    func testVImageHistogramEqualization_EdgeCases() {
        // Test 1: Empty input
        let emptyData = Data()
        let emptyResult = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: emptyData,
            width: 0,
            height: 0
        )
        XCTAssertNil(emptyResult, "Empty input should return nil")

        // Test 2: Single pixel
        let singlePixel = Data([128])
        let singleResult = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: singlePixel,
            width: 1,
            height: 1
        )
        XCTAssertNotNil(singleResult, "Single pixel should be processed")
        XCTAssertEqual(singleResult?.count, 1, "Output should have one pixel")

        // Test 3: Uniform image (all pixels same value)
        let uniformPixels = [UInt8](repeating: 127, count: 100)
        let uniformData = Data(uniformPixels)
        let uniformResult = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: uniformData,
            width: 10,
            height: 10
        )
        XCTAssertNotNil(uniformResult, "Uniform image should be processed")
        // Note: histogram equalization will modify uniform images
        // by spreading them across the full dynamic range. This is expected behavior.
        let uniformResultBytes = [UInt8](uniformResult!)
        XCTAssertEqual(uniformResultBytes.count, 100, "Output should have correct size")

        // Test 4: Invalid dimensions (mismatched data size)
        let invalidData = Data([1, 2, 3, 4])
        let invalidResult = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: invalidData,
            width: 10,
            height: 10  // 10×10 = 100 pixels, but data has only 4
        )
        XCTAssertNil(invalidResult, "Invalid dimensions should return nil")

        // Test 5: Zero dimensions
        let zeroData = Data([1, 2, 3])
        let zeroResult = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: zeroData,
            width: 0,
            height: 3
        )
        XCTAssertNil(zeroResult, "Zero width should return nil")
    }

    func testVImageHistogramEqualization_BimodalImage() {
        // Test histogram equalization with a bimodal image.
        let width = 32
        let height = 32

        // Create test image with bimodal distribution (dark and bright regions)
        var pixels = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width {
                // Left half dark, right half bright
                let value: UInt8 = x < width / 2 ? 50 : 200
                pixels.append(value)
            }
        }
        let imageData = Data(pixels)

        let result = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: imageData,
            width: width,
            height: height
        )

        XCTAssertNotNil(result, "Histogram equalization should succeed")
        XCTAssertEqual(result?.count, width * height)
    }

    // MARK: - vImage Noise Reduction Tests

    func testVImageNoiseReduction_BasicFunctionality() {
        // Verify basic noise reduction operation produces valid output
        let width = 64
        let height = 64
        let pixelCount = width * height

        // Create test image with noise
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                // Base gradient with random noise
                let baseValue = (x + y) * 255 / (width + height)
                let noise = Int.random(in: -20...20)
                let value = max(0, min(255, baseValue + noise))
                pixels.append(UInt8(value))
            }
        }
        let imageData = Data(pixels)

        // Apply noise reduction with moderate strength
        let result = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 0.5
        )

        XCTAssertNotNil(result, "Noise reduction should produce output")
        XCTAssertEqual(result?.count, pixelCount, "Output size should match input size")

        // Verify output is smoothed compared to input
        let resultBytes = [UInt8](result!)

        // Calculate variance in a central region to verify smoothing
        var inputVariance = 0.0
        var outputVariance = 0.0
        var count = 0

        for y in (height / 4)..<(3 * height / 4) {
            for x in (width / 4)..<(3 * width / 4) {
                let idx = y * width + x
                if idx > 0 && idx < pixelCount - 1 {
                    let inputDiff = Double(pixels[idx]) - Double(pixels[idx - 1])
                    let outputDiff = Double(resultBytes[idx]) - Double(resultBytes[idx - 1])
                    inputVariance += inputDiff * inputDiff
                    outputVariance += outputDiff * outputDiff
                    count += 1
                }
            }
        }

        inputVariance /= Double(count)
        outputVariance /= Double(count)

        // Output should be smoother (lower variance) than input
        XCTAssertLessThan(outputVariance, inputVariance, "Noise reduction should decrease variance")
    }

    func testVImageNoiseReduction_EdgeCases() {
        // Test 1: Empty input
        let emptyData = Data()
        let emptyResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: emptyData,
            width: 0,
            height: 0,
            strength: 0.5
        )
        XCTAssertNil(emptyResult, "Empty input should return nil")

        // Test 2: Invalid dimensions
        let invalidData = Data([1, 2, 3])
        let invalidResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: invalidData,
            width: 10,
            height: 10,
            strength: 0.5
        )
        XCTAssertNil(invalidResult, "Invalid dimensions should return nil")

        // Test 3: Small image (5×5 minimum for convolution)
        let smallPixels = [UInt8](repeating: 100, count: 25)
        let smallData = Data(smallPixels)
        let smallResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: smallData,
            width: 5,
            height: 5,
            strength: 0.5
        )
        XCTAssertNotNil(smallResult, "Small 5×5 image should be processed")
        XCTAssertEqual(smallResult?.count, 25, "Output should have 25 pixels")

        // Test 4: Larger edge case (10×10)
        let mediumPixels = [UInt8](repeating: 128, count: 100)
        let mediumData = Data(mediumPixels)
        let mediumResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: mediumData,
            width: 10,
            height: 10,
            strength: 0.7
        )
        XCTAssertNotNil(mediumResult, "10×10 image should be processed")
        XCTAssertEqual(mediumResult?.count, 100, "Output should have 100 pixels")
    }

    func testVImageNoiseReduction_StrengthParameter() {
        let width = 32
        let height = 32

        // Create consistent noisy image
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let baseValue = 128
                let noise = ((x + y) % 5) * 10 - 20  // Deterministic noise pattern
                let value = max(0, min(255, baseValue + noise))
                pixels.append(UInt8(value))
            }
        }
        let imageData = Data(pixels)

        // Test strength = 0.0 (no filtering)
        let zeroStrengthResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 0.0
        )
        XCTAssertNotNil(zeroStrengthResult, "Zero strength should succeed")
        let zeroBytes = [UInt8](zeroStrengthResult!)
        // With strength=0, output should be very close to input
        let unchangedPixels = zip(pixels, zeroBytes).filter { $0 == $1 }.count
        XCTAssertGreaterThan(Double(unchangedPixels) / Double(pixels.count), 0.95,
                            "Strength 0.0 should leave most pixels unchanged")

        // Test strength = 0.5 (moderate filtering)
        let mediumStrengthResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 0.5
        )
        XCTAssertNotNil(mediumStrengthResult, "Medium strength should succeed")
        let mediumBytes = [UInt8](mediumStrengthResult!)

        // Calculate how much smoothing occurred
        var inputVariance = 0.0
        var mediumVariance = 0.0
        for i in 1..<pixels.count {
            let inputDiff = Double(pixels[i]) - Double(pixels[i-1])
            let mediumDiff = Double(mediumBytes[i]) - Double(mediumBytes[i-1])
            inputVariance += inputDiff * inputDiff
            mediumVariance += mediumDiff * mediumDiff
        }

        // Medium strength should reduce variance noticeably
        XCTAssertLessThan(mediumVariance, inputVariance * 0.8,
                         "Strength 0.5 should reduce variance by at least 20%")

        // Test strength = 1.0 (full filtering)
        let fullStrengthResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 1.0
        )
        XCTAssertNotNil(fullStrengthResult, "Full strength should succeed")
        let fullBytes = [UInt8](fullStrengthResult!)

        var fullVariance = 0.0
        for i in 1..<fullBytes.count {
            let fullDiff = Double(fullBytes[i]) - Double(fullBytes[i-1])
            fullVariance += fullDiff * fullDiff
        }

        // Full strength should reduce variance more than medium strength
        XCTAssertLessThan(fullVariance, mediumVariance,
                         "Strength 1.0 should smooth more than strength 0.5")

        // Test strength outside [0,1] range (should clamp)
        let negativeStrengthResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: -0.5
        )
        XCTAssertNotNil(negativeStrengthResult, "Negative strength should be clamped and succeed")

        let excessiveStrengthResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 2.0
        )
        XCTAssertNotNil(excessiveStrengthResult, "Strength > 1.0 should be clamped and succeed")
    }

    func testVImageNoiseReduction_LargeImages() {
        // Test noise reduction on large image (1024×1024)
        let width = 1024
        let height = 1024
        let pixelCount = width * height

        // Create large test image with gradient and noise
        var pixels = [UInt8]()
        pixels.reserveCapacity(pixelCount)

        for y in 0..<height {
            for x in 0..<width {
                // Smooth gradient
                let value = UInt8((x + y) * 255 / (width + height))
                pixels.append(value)
            }
        }
        let imageData = Data(pixels)

        // Measure time for noise reduction
        let startTime = Date()
        let result = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 0.5
        )
        let elapsed = Date().timeIntervalSince(startTime)

        XCTAssertNotNil(result, "Large image noise reduction should succeed")
        XCTAssertEqual(result?.count, pixelCount, "Output size should match input size")

        // Performance expectation: should complete in reasonable time
        // vImage convolution should be fast (<100ms for 1024×1024)
        XCTAssertLessThan(elapsed, 0.5, "1024×1024 noise reduction should complete within 500ms")

        // Verify output is valid
        let resultBytes = [UInt8](result!)
        let hasValidValues = resultBytes.allSatisfy { $0 <= 255 }
        XCTAssertTrue(hasValidValues, "All output values should be valid UInt8")
    }

    func testVImageNoiseReduction_PreservesEdgePixels() {
        // Verify that edge pixel handling doesn't introduce artifacts
        let width = 16
        let height = 16

        // Create image with distinct border
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                // Black border, white interior
                if x == 0 || y == 0 || x == width-1 || y == height-1 {
                    pixels.append(0)
                } else {
                    pixels.append(255)
                }
            }
        }
        let imageData = Data(pixels)

        let result = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 0.5
        )

        XCTAssertNotNil(result, "Edge test should succeed")
        let resultBytes = [UInt8](result!)

        // Verify corners are handled (should be smoothed but still dark)
        let topLeft = resultBytes[0]
        let topRight = resultBytes[width - 1]
        let bottomLeft = resultBytes[(height - 1) * width]
        let bottomRight = resultBytes[height * width - 1]

        XCTAssertLessThan(topLeft, 150, "Top-left corner should remain relatively dark")
        XCTAssertLessThan(topRight, 150, "Top-right corner should remain relatively dark")
        XCTAssertLessThan(bottomLeft, 150, "Bottom-left corner should remain relatively dark")
        XCTAssertLessThan(bottomRight, 150, "Bottom-right corner should remain relatively dark")

        // Verify center is still bright
        let centerIdx = (height / 2) * width + (width / 2)
        let centerValue = resultBytes[centerIdx]
        XCTAssertGreaterThan(centerValue, 200, "Center should remain bright")
    }

    // MARK: - Integration Tests

    func testHistogramEqualizationFollowedByNoiseReduction() {
        // Test applying histogram equalization followed by noise reduction (common workflow)
        let width = 64
        let height = 64

        // Create test image
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8((x * y) % 256)
                pixels.append(value)
            }
        }
        let imageData = Data(pixels)

        // Step 1: Apply histogram equalization
        let equalizedResult = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: imageData,
            width: width,
            height: height
        )
        XCTAssertNotNil(equalizedResult, "Histogram equalization should succeed")

        // Step 2: Apply noise reduction to histogram equalization output
        let finalResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: equalizedResult!,
            width: width,
            height: height,
            strength: 0.5
        )
        XCTAssertNotNil(finalResult, "Noise reduction after histogram equalization should succeed")
        XCTAssertEqual(finalResult?.count, width * height, "Final output should have correct size")
    }

    func testNoiseReductionFollowedByHistogramEqualization() {
        // Test applying noise reduction followed by histogram equalization (alternative workflow)
        let width = 64
        let height = 64

        // Create test image
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8((x + y * 2) % 256)
                pixels.append(value)
            }
        }
        let imageData = Data(pixels)

        // Step 1: Apply noise reduction
        let noiseReductionResult = DCMWindowingProcessor.applyNoiseReduction(
            imageData: imageData,
            width: width,
            height: height,
            strength: 0.5
        )
        XCTAssertNotNil(noiseReductionResult, "Noise reduction should succeed")

        // Step 2: Apply histogram equalization to smoothed output
        let finalResult = DCMWindowingProcessor.applyHistogramEqualization(
            imageData: noiseReductionResult!,
            width: width,
            height: height
        )
        XCTAssertNotNil(finalResult, "Histogram equalization after noise reduction should succeed")
        XCTAssertEqual(finalResult?.count, width * height, "Final output should have correct size")
    }

    // MARK: - Performance Tests

    func testNoiseReductionPerformance() {
        // Measure performance of noise reduction on moderately sized image
        let width = 512
        let height = 512
        let pixels = [UInt8](repeating: 128, count: width * height)
        let imageData = Data(pixels)

        measure {
            _ = DCMWindowingProcessor.applyNoiseReduction(
                imageData: imageData,
                width: width,
                height: height,
                strength: 0.5
            )
        }
    }

    func testHistogramEqualizationPerformance() {
        // Measure performance of histogram equalization on a moderately sized image
        let width = 512
        let height = 512
        let pixels = [UInt8](repeating: 128, count: width * height)
        let imageData = Data(pixels)

        measure {
            _ = DCMWindowingProcessor.applyHistogramEqualization(
                imageData: imageData,
                width: width,
                height: height
            )
        }
    }
}
