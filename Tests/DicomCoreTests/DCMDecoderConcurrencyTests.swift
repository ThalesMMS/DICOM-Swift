import XCTest
@testable import DicomCore
import DicomTestSupport

final class DCMDecoderConcurrencyTests: XCTestCase {

    // MARK: - Concurrent Instance Tests

    func testMultipleDecoderInstancesConcurrent() {
        // Test that multiple decoder instances can be created and used concurrently
        let expectation = XCTestExpectation(description: "Multiple decoders created concurrently")
        let iterations = 10
        let completedCount = DicomTestLockedValue(0)
        let queue = DispatchQueue.global(qos: .userInitiated)

        for i in 0..<iterations {
            queue.async {
                // Create a decoder instance in this thread
                let decoder = DCMDecoder()

                // Verify initial state is consistent
                XCTAssertFalse(decoder.isValid(), "New decoder \(i) should not be valid")

                // Test basic operations
                let status = decoder.getValidationStatus()
                XCTAssertFalse(status.isValid, "Decoder \(i) validation should fail initially")

                // Increment completed count safely
                let isComplete = completedCount.withValue { count in
                    count += 1
                    return count == iterations
                }
                if isComplete {
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(completedCount.value, iterations, "All decoder instances should complete")
    }

    func testConcurrentDecoderPropertyAccess() {
        // Test that multiple threads can safely access decoder properties
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent property access")
        let iterations = 20
        let completedCount = DicomTestLockedValue(0)
        let queue = DispatchQueue.global(qos: .userInitiated)

        for _ in 0..<iterations {
            queue.async {
                // Access various properties concurrently
                _ = decoder.isValid()
                _ = decoder.width
                _ = decoder.height
                _ = decoder.imageDimensions
                _ = decoder.pixelSpacingV2
                _ = decoder.windowSettingsV2
                _ = decoder.rescaleParametersV2
                _ = decoder.isGrayscale
                _ = decoder.isColorImage

                // Increment completed count safely
                let isComplete = completedCount.withValue { count in
                    count += 1
                    return count == iterations
                }
                if isComplete {
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(completedCount.value, iterations, "All property access operations should complete")
    }

    func testConcurrentValidationStatusChecks() {
        // Test that validation status can be checked from multiple threads safely
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent validation checks")
        let iterations = 15
        let completedCount = DicomTestLockedValue(0)
        let queue = DispatchQueue.global(qos: .userInitiated)

        for i in 0..<iterations {
            queue.async {
                // Check validation status
                let status = decoder.getValidationStatus()
                XCTAssertFalse(status.isValid, "Thread \(i): validation should fail for unloaded decoder")
                XCTAssertFalse(status.hasPixels, "Thread \(i): should have no pixels")

                // Check convenience methods
                XCTAssertFalse(decoder.isValid(), "Thread \(i): decoder should not be valid")

                // Increment completed count safely
                let isComplete = completedCount.withValue { count in
                    count += 1
                    return count == iterations
                }
                if isComplete {
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(completedCount.value, iterations, "All validation checks should complete")
    }

    func testConcurrentMetadataAccess() {
        // Test that metadata access is thread-safe
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent metadata access")
        let iterations = 20
        let completedCount = DicomTestLockedValue(0)
        let queue = DispatchQueue.global(qos: .userInitiated)

        // Common DICOM tags to query
        let tags = [
            0x00100010, // Patient Name
            0x00100020, // Patient ID
            0x00080060, // Modality
            0x00280010, // Rows
            0x00280011, // Columns
            0x0020000D, // Study Instance UID
        ]

        for _ in 0..<iterations {
            queue.async {
                // Access metadata concurrently
                for tag in tags {
                    _ = decoder.info(for: tag)
                    _ = decoder.intValue(for: tag)
                    _ = decoder.doubleValue(for: tag)
                }

                // Access grouped metadata
                _ = decoder.getPatientInfo()
                _ = decoder.getStudyInfo()
                _ = decoder.getSeriesInfo()

                // Increment completed count safely
                let isComplete = completedCount.withValue { count in
                    count += 1
                    return count == iterations
                }
                if isComplete {
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(completedCount.value, iterations, "All metadata access operations should complete")
    }

    func testConcurrentPixelDataAccess() {
        // Test that pixel data access is thread-safe (even when no pixels are loaded)
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent pixel access")
        let iterations = 15
        let completedCount = DicomTestLockedValue(0)
        let queue = DispatchQueue.global(qos: .userInitiated)

        for i in 0..<iterations {
            queue.async {
                // Attempt to access pixels concurrently
                let pixels8 = decoder.getPixels8()
                let pixels16 = decoder.getPixels16()

                // Should be nil since no file is loaded
                XCTAssertNil(pixels8, "Thread \(i): pixels8 should be nil")
                XCTAssertNil(pixels16, "Thread \(i): pixels16 should be nil")

                // Increment completed count safely
                let isComplete = completedCount.withValue { count in
                    count += 1
                    return count == iterations
                }
                if isComplete {
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(completedCount.value, iterations, "All pixel access operations should complete")
    }

    func testConcurrentPixelAndMetadataAccess() {
        // Test that a single decoder instance can handle concurrent pixel and metadata access
        // This is the most realistic scenario - threads reading both pixel data and metadata
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent pixel and metadata access")
        let iterations = 30
        let completedCount = DicomTestLockedValue(0)
        let queue = DispatchQueue.global(qos: .userInitiated)

        for i in 0..<iterations {
            queue.async {
                // Mix pixel access with metadata access
                switch i % 6 {
                case 0:
                    // Pixel access - 8-bit
                    let pixels8 = decoder.getPixels8()
                    XCTAssertNil(pixels8, "Thread \(i): pixels8 should be nil")
                    _ = decoder.width
                    _ = decoder.height

                case 1:
                    // Pixel access - 16-bit
                    let pixels16 = decoder.getPixels16()
                    XCTAssertNil(pixels16, "Thread \(i): pixels16 should be nil")
                    _ = decoder.info(for: 0x00280010) // Rows
                    _ = decoder.info(for: 0x00280011) // Columns

                case 2:
                    // Pixel access - 24-bit color
                    let pixels24 = decoder.getPixels24()
                    XCTAssertNil(pixels24, "Thread \(i): pixels24 should be nil")
                    _ = decoder.isColorImage
                    _ = decoder.isGrayscale

                case 3:
                    // Downsampled pixel access (may return default values even when no file loaded)
                    _ = decoder.getDownsampledPixels16(maxDimension: 150)
                    _ = decoder.pixelSpacingV2
                    _ = decoder.imageDimensions

                case 4:
                    // Multiple pixel format checks
                    _ = decoder.getPixels8()
                    _ = decoder.getPixels16()
                    _ = decoder.windowSettingsV2
                    _ = decoder.rescaleParametersV2

                case 5:
                    // Mixed metadata and validation
                    _ = decoder.getValidationStatus()
                    _ = decoder.getPatientInfo()
                    let pixels = decoder.getPixels16()
                    XCTAssertNil(pixels, "Thread \(i): pixels16 should be nil")
                    _ = decoder.getStudyInfo()

                default:
                    break
                }

                // Increment completed count safely
                let isComplete = completedCount.withValue { count in
                    count += 1
                    return count == iterations
                }
                if isComplete {
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 10.0)
        XCTAssertEqual(
            completedCount.value,
            iterations,
            "All concurrent pixel and metadata access operations should complete"
        )
    }

    // MARK: - Mixed Operations Tests

    func testConcurrentMixedOperations() {
        // Test a realistic scenario with mixed read operations
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent mixed operations")
        let iterations = 25
        let completedCount = DicomTestLockedValue(0)
        let queue = DispatchQueue.global(qos: .userInitiated)

        for i in 0..<iterations {
            queue.async {
                // Perform various operations concurrently
                switch i % 5 {
                case 0:
                    _ = decoder.isValid()
                    _ = decoder.getValidationStatus()
                case 1:
                    _ = decoder.width
                    _ = decoder.height
                    _ = decoder.imageDimensions
                case 2:
                    _ = decoder.info(for: 0x00100010)
                    _ = decoder.getPatientInfo()
                case 3:
                    _ = decoder.getPixels16()
                    _ = decoder.getPixels8()
                case 4:
                    _ = decoder.windowSettingsV2
                    _ = decoder.rescaleParametersV2
                    _ = decoder.pixelSpacingV2
                default:
                    break
                }

                // Increment completed count safely
                let isComplete = completedCount.withValue { count in
                    count += 1
                    return count == iterations
                }
                if isComplete {
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(completedCount.value, iterations, "All mixed operations should complete")
    }

    // MARK: - Async API Tests

    func testConcurrentAsyncPixelAccess() {
        // Test that pixel access is thread-safe from multiple concurrent tasks
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent pixel access")
        let iterations = 10
        let counts = DicomTestLockedValue((completed: 0, attempted: 0))
        let queue = DispatchQueue.global(qos: .userInitiated)

        for _ in 0..<iterations {
            queue.async {
                // Use synchronous pixel methods (they are thread-safe)
                let pixels16 = decoder.getPixels16()
                let pixels8 = decoder.getPixels8()

                // Should be nil since no file is loaded
                let success = pixels16 == nil && pixels8 == nil

                let isComplete = counts.withValue { counts in
                    if success {
                        counts.completed += 1
                    }
                    counts.attempted += 1
                    return counts.attempted == iterations
                }
                if isComplete {
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(counts.value.completed, iterations, "All concurrent pixel access tasks should succeed")
    }

    // MARK: - Performance Tests

    func testConcurrencyPerformance() {
        // Measure performance of concurrent access
        let decoder = DCMDecoder()

        measure {
            let expectation = XCTestExpectation(description: "Performance test")
            let iterations = 100
            let completedCount = DicomTestLockedValue(0)
            let queue = DispatchQueue.global(qos: .userInitiated)

            for _ in 0..<iterations {
                queue.async {
                    _ = decoder.isValid()
                    _ = decoder.width
                    _ = decoder.info(for: 0x00100010)

                    let isComplete = completedCount.withValue { count in
                        count += 1
                        return count == iterations
                    }
                    if isComplete {
                        expectation.fulfill()
                    }
                }
            }

            self.wait(for: [expectation], timeout: 5.0)
        }
    }
}
