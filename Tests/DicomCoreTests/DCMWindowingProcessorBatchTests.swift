//
//  DCMWindowingProcessorBatchTests.swift
//  DicomCoreTests
//
//  Checks that batch window/level calculation preserves input ordering.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

// MARK: - DCMWindowingProcessor Batch Tests

final class DCMWindowingProcessorBatchTests: XCTestCase {

    // MARK: - batchCalculateOptimalWindowLevelV2 Tests

    func testBatchCalculateOptimalWindowLevelBasic() {
        let pixels1: [UInt16] = [100, 500, 1000, 1500, 2000]
        let pixels2: [UInt16] = [200, 800, 1600, 2400, 3200]

        let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
            imagePixels: [pixels1, pixels2]
        )

        XCTAssertEqual(results.count, 2, "Should return one result per input image")
    }

    func testBatchCalculateOptimalWindowLevelEmptyInput() {
        let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(imagePixels: [])
        XCTAssertTrue(results.isEmpty, "Empty input should return empty results")
    }

    func testBatchCalculateOptimalWindowLevelResultsHavePositiveWidth() {
        let pixels1: [UInt16] = [100, 500, 1000, 1500, 2000, 2500, 3000]
        let pixels2: [UInt16] = [50, 400, 800, 1200]

        let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
            imagePixels: [pixels1, pixels2]
        )

        for (i, settings) in results.enumerated() {
            XCTAssertGreaterThan(settings.width, 0, "Image \(i) should have positive window width")
        }
    }

    func testBatchCalculateOptimalWindowLevelSingleImage() {
        let pixels: [UInt16] = [1000, 2000, 3000, 4000, 5000]
        let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(imagePixels: [pixels])
        XCTAssertEqual(results.count, 1, "Should return exactly one result for single image")
    }

    func testBatchCalculateOptimalWindowLevelPreservesOrder() {
        // Verify results are returned in the same order as inputs
        let pixelsHigh: [UInt16] = [5000, 6000, 7000, 8000] // high intensity
        let pixelsLow: [UInt16] = [100, 200, 300, 400]      // low intensity

        let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
            imagePixels: [pixelsHigh, pixelsLow]
        )

        XCTAssertEqual(results.count, 2, "Should return 2 results")
        // High intensity image should have higher center than low intensity image
        XCTAssertGreaterThan(results[0].center, results[1].center,
                             "High intensity image should have higher center")
    }

}
