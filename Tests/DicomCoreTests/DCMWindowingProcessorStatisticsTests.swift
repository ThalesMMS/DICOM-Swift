//
//  DCMWindowingProcessorStatisticsTests.swift
//  DicomCoreTests
//
//  Checks pixel histograms, mean values, quality statistics, and zero-slope HU conversion.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

// MARK: - DCMWindowingProcessor Statistics Tests

final class DCMWindowingProcessorStatisticsTests: XCTestCase {

    // MARK: - calculateHistogram Tests

    func testCalculateHistogramBasicGradient() {
        let pixels: [UInt16] = [0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
        var minVal: Double = 0
        var maxVal: Double = 0
        var meanVal: Double = 0

        let histogram = DCMWindowingProcessor.calculateHistogram(pixels16: pixels,
                                                                  minValue: &minVal,
                                                                  maxValue: &maxVal,
                                                                  meanValue: &meanVal)

        XCTAssertEqual(histogram.count, 256, "Histogram should have 256 bins")
        XCTAssertEqual(minVal, 0.0, accuracy: 0.01, "Min value should be 0")
        XCTAssertEqual(maxVal, 1000.0, accuracy: 0.01, "Max value should be 1000")
        XCTAssertGreaterThan(meanVal, 0.0, "Mean value should be positive")

        // Total count should equal input count
        let totalCount = histogram.reduce(0, +)
        XCTAssertEqual(totalCount, pixels.count, "Total histogram count should equal pixel count")
    }

    func testCalculateHistogramEmptyInput() {
        let pixels: [UInt16] = []
        var minVal: Double = 999
        var maxVal: Double = 999
        var meanVal: Double = 999

        let histogram = DCMWindowingProcessor.calculateHistogram(pixels16: pixels,
                                                                  minValue: &minVal,
                                                                  maxValue: &maxVal,
                                                                  meanValue: &meanVal)

        XCTAssertTrue(histogram.isEmpty, "Empty input should return empty histogram")
        XCTAssertEqual(minVal, 0, "Empty input should reset min value")
        XCTAssertEqual(maxVal, 0, "Empty input should reset max value")
        XCTAssertEqual(meanVal, 0, "Empty input should reset mean value")
    }

    func testCalculateHistogramSingleValue() {
        let pixels: [UInt16] = [500, 500, 500, 500]
        var minVal: Double = 0
        var maxVal: Double = 0
        var meanVal: Double = 0

        let histogram = DCMWindowingProcessor.calculateHistogram(pixels16: pixels,
                                                                  minValue: &minVal,
                                                                  maxValue: &maxVal,
                                                                  meanValue: &meanVal)

        XCTAssertEqual(minVal, 500.0, accuracy: 0.01, "Min should be 500")
        XCTAssertEqual(maxVal, 500.0, accuracy: 0.01, "Max should be 500")
        XCTAssertEqual(meanVal, 500.0, accuracy: 0.01, "Mean should be 500")
        XCTAssertEqual(histogram.count, 256, "Histogram should have 256 bins")

        let nonEmptyBins = histogram.enumerated().filter { $0.element > 0 }
        XCTAssertEqual(nonEmptyBins.count, 1, "Uniform image should populate exactly one histogram bin")
        XCTAssertEqual(nonEmptyBins.first?.element, 4, "The populated bin should contain all 4 identical pixels")
        XCTAssertEqual(histogram.reduce(0, +), 4, "All other bins should be empty for uniform image")
    }

    func testCalculateHistogramMinMaxValues() {
        let pixels: [UInt16] = [0, 32768, 65535]
        var minVal: Double = 0
        var maxVal: Double = 0
        var meanVal: Double = 0

        let histogram = DCMWindowingProcessor.calculateHistogram(pixels16: pixels,
                                                                  minValue: &minVal,
                                                                  maxValue: &maxVal,
                                                                  meanValue: &meanVal)

        XCTAssertEqual(minVal, 0.0, accuracy: 0.01, "Min should be 0")
        XCTAssertEqual(maxVal, 65535.0, accuracy: 1.0, "Max should be 65535")
        XCTAssertGreaterThan(meanVal, 0.0, "Mean should be positive")

        let totalCount = histogram.reduce(0, +)
        XCTAssertEqual(totalCount, 3, "Total count should be 3")
    }

    func testCalculateHistogramMeanIsCorrect() {
        // Use known values to verify mean calculation
        let pixels: [UInt16] = [100, 200, 300]
        var minVal: Double = 0
        var maxVal: Double = 0
        var meanVal: Double = 0

        _ = DCMWindowingProcessor.calculateHistogram(pixels16: pixels,
                                                      minValue: &minVal,
                                                      maxValue: &maxVal,
                                                      meanValue: &meanVal)

        XCTAssertEqual(meanVal, 200.0, accuracy: 0.01, "Mean of [100,200,300] should be 200")
        XCTAssertEqual(minVal, 100.0, accuracy: 0.01, "Min should be 100")
        XCTAssertEqual(maxVal, 300.0, accuracy: 0.01, "Max should be 300")
    }

    // MARK: - calculateQualityMetrics Tests

    func testCalculateQualityMetricsBasic() {
        let pixels: [UInt16] = [100, 200, 300, 400, 500]
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)

        XCTAssertFalse(metrics.isEmpty, "Quality metrics should not be empty")
        XCTAssertNotNil(metrics["mean"], "Metrics should contain 'mean'")
        XCTAssertNotNil(metrics["std_deviation"], "Metrics should contain 'std_deviation'")
        XCTAssertNotNil(metrics["min_value"], "Metrics should contain 'min_value'")
        XCTAssertNotNil(metrics["max_value"], "Metrics should contain 'max_value'")
        XCTAssertNotNil(metrics["contrast"], "Metrics should contain 'contrast'")
        XCTAssertNotNil(metrics["snr"], "Metrics should contain 'snr'")
        XCTAssertNotNil(metrics["dynamic_range"], "Metrics should contain 'dynamic_range'")
    }

    func testCalculateQualityMetricsEmptyInput() {
        let pixels: [UInt16] = []
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        XCTAssertTrue(metrics.isEmpty, "Empty pixel input should return empty metrics dictionary")
    }

    func testCalculateQualityMetricsMean() {
        let pixels: [UInt16] = [100, 200, 300]
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        XCTAssertEqual(metrics["mean"] ?? 0, 200.0, accuracy: 0.01, "Mean of [100,200,300] should be 200")
    }

    func testCalculateQualityMetricsMinMax() {
        let pixels: [UInt16] = [50, 150, 250, 350, 450]
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        XCTAssertEqual(metrics["min_value"] ?? 0, 50.0, accuracy: 0.01, "Min should be 50")
        XCTAssertEqual(metrics["max_value"] ?? 0, 450.0, accuracy: 0.01, "Max should be 450")
    }

    func testCalculateQualityMetricsContrastRange() {
        // Contrast is Michelson: (max-min)/(max+min)
        let pixels: [UInt16] = [0, 1000]
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        let contrast = metrics["contrast"] ?? -1
        // With max=1000, min=0: (1000-0)/(1000+0+eps) ≈ 1.0
        XCTAssertTrue(contrast >= 0.0 && contrast <= 1.0, "Contrast should be in [0, 1] range, got \(contrast)")
    }

    func testCalculateQualityMetricsSNRPositive() {
        // SNR = mean / stdDev; with positive mean and non-zero stdDev
        let pixels: [UInt16] = [100, 110, 120, 130, 140]
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        let snr = metrics["snr"] ?? -1
        XCTAssertGreaterThan(snr, 0, "SNR should be positive for positive mean pixels")
    }

    func testCalculateQualityMetricsUniformPixels() {
        // Uniform image: stdDev = 0, contrast = 0
        let pixels: [UInt16] = [200, 200, 200, 200]
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        XCTAssertEqual(metrics["mean"] ?? -1, 200.0, accuracy: 0.01, "Mean should be 200 for uniform image")
        XCTAssertEqual(metrics["std_deviation"] ?? -1, 0.0, accuracy: 0.01, "Std dev should be 0 for uniform image")
        XCTAssertEqual(metrics["contrast"] ?? -1, 0.0, accuracy: 0.01, "Contrast should be 0 for uniform image")
    }

    func testCalculateQualityMetricsZeroPixelsHasFiniteDynamicRange() throws {
        let pixels: [UInt16] = [0, 0, 0, 0]
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        let dynamicRange = try XCTUnwrap(metrics["dynamic_range"])

        XCTAssertTrue(dynamicRange.isFinite, "Dynamic range should remain finite for degenerate images")
        XCTAssertEqual(dynamicRange, 0.0, accuracy: 0.01, "Zero image should use safe dynamic range default")
    }

    func testCalculateQualityMetricsSinglePixel() {
        let pixels: [UInt16] = [512]
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels)
        XCTAssertEqual(metrics["mean"] ?? 0, 512.0, accuracy: 0.01, "Mean of single pixel should be its value")
        XCTAssertEqual(metrics["min_value"] ?? 0, 512.0, accuracy: 0.01, "Min of single pixel should be its value")
        XCTAssertEqual(metrics["max_value"] ?? 0, 512.0, accuracy: 0.01, "Max of single pixel should be its value")
    }

    // MARK: - huToPixelValue Tests

    func testHUToPixelValueBasicCT() {
        // CT standard: HU = 1.0 * pixel + (-1024)
        // pixel = (HU - intercept) / slope = (0 - (-1024)) / 1.0 = 1024
        let pixelValue = DCMWindowingProcessor.huToPixelValue(
            hu: 0.0, rescaleSlope: 1.0, rescaleIntercept: -1024.0)
        XCTAssertEqual(pixelValue, 1024.0, accuracy: 0.01, "HU=0 with standard CT should give pixel=1024")
    }

    func testHUToPixelValueWaterEquivalent() {
        // Water is 0 HU in CT
        let pixelValue = DCMWindowingProcessor.huToPixelValue(
            hu: 0.0, rescaleSlope: 1.0, rescaleIntercept: 0.0)
        XCTAssertEqual(pixelValue, 0.0, accuracy: 0.01, "HU=0 with zero intercept should give pixel=0")
    }

    func testHUToPixelValueZeroSlopeReturnsZero() {
        // When rescaleSlope is 0, division would cause infinity; function returns 0
        let pixelValue = DCMWindowingProcessor.huToPixelValue(
            hu: 100.0, rescaleSlope: 0.0, rescaleIntercept: -1024.0)
        XCTAssertEqual(pixelValue, 0.0, accuracy: 0.01, "Zero rescaleSlope should return 0 to avoid division by zero")
    }

    func testHUToPixelValueRoundTrip() {
        // Apply huToPixelValue then pixelValueToHU, should get back original HU
        let originalHU = 500.0
        let slope = 1.5
        let intercept = -1024.0

        let pixelValue = DCMWindowingProcessor.huToPixelValue(
            hu: originalHU, rescaleSlope: slope, rescaleIntercept: intercept)
        let recoveredHU = DCMWindowingProcessor.pixelValueToHU(
            pixelValue: pixelValue, rescaleSlope: slope, rescaleIntercept: intercept)

        XCTAssertEqual(recoveredHU, originalHU, accuracy: 0.01, "Round-trip HU → pixel → HU should recover original value")
    }

    // MARK: - pixelValueToHU Tests

    func testPixelValueToHUBasicCT() {
        // CT standard: HU = 1.0 * pixel + (-1024)
        // pixel 1024 → HU = 1024 - 1024 = 0 (water)
        let hu = DCMWindowingProcessor.pixelValueToHU(
            pixelValue: 1024.0, rescaleSlope: 1.0, rescaleIntercept: -1024.0)
        XCTAssertEqual(hu, 0.0, accuracy: 0.01, "Pixel=1024 with CT standard should give HU=0 (water)")
    }

    func testPixelValueToHUAir() {
        // CT: air is -1000 HU. With slope=1, intercept=-1024: pixel=24 → HU=-1000
        let hu = DCMWindowingProcessor.pixelValueToHU(
            pixelValue: 24.0, rescaleSlope: 1.0, rescaleIntercept: -1024.0)
        XCTAssertEqual(hu, -1000.0, accuracy: 0.01, "Pixel=24 with CT standard should give HU=-1000 (air)")
    }

    func testPixelValueToHUZeroPixel() {
        let hu = DCMWindowingProcessor.pixelValueToHU(
            pixelValue: 0.0, rescaleSlope: 1.0, rescaleIntercept: 0.0)
        XCTAssertEqual(hu, 0.0, accuracy: 0.01, "Pixel=0 with zero intercept should give HU=0")
    }

    func testPixelValueToHUWithCustomSlope() {
        // Custom: HU = 2.0 * pixel + 100
        let hu = DCMWindowingProcessor.pixelValueToHU(
            pixelValue: 50.0, rescaleSlope: 2.0, rescaleIntercept: 100.0)
        XCTAssertEqual(hu, 200.0, accuracy: 0.01, "2.0 * 50 + 100 = 200")
    }

    func testPixelValueToHURoundTrip() {
        // Apply pixelValueToHU then huToPixelValue, should get back original pixel
        let originalPixel = 2048.0
        let slope = 0.5
        let intercept = -512.0

        let hu = DCMWindowingProcessor.pixelValueToHU(
            pixelValue: originalPixel, rescaleSlope: slope, rescaleIntercept: intercept)
        let recoveredPixel = DCMWindowingProcessor.huToPixelValue(
            hu: hu, rescaleSlope: slope, rescaleIntercept: intercept)

        XCTAssertEqual(recoveredPixel, originalPixel, accuracy: 0.01, "Round-trip pixel → HU → pixel should recover original")
    }
}
