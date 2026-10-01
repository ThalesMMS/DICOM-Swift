import XCTest
@testable import DicomCore
import DicomTestSupport

// Compatibility coverage: this suite intentionally exercises deprecated
// public APIs that remain available (issue #1221); the annotation keeps
// the deliberate legacy usage warning-free without hiding new ones.
@available(*, deprecated)
final class DCMDecoderStressTests: XCTestCase {

    // MARK: - Stress Tests

    func testHighConcurrencyStress() {
        // Stress test with high concurrency
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "High concurrency stress test")
        let iterations = 50
        let completedCount = DicomTestLockedValue(0)
        let queue = DispatchQueue.global(qos: .userInitiated)

        for _ in 0..<iterations {
            queue.async {
                // Rapid-fire property access
                for _ in 0..<10 {
                    _ = decoder.isValid()
                    _ = decoder.width
                    _ = decoder.info(for: 0x00280010)
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
        XCTAssertEqual(completedCount.value, iterations, "All stress test operations should complete")
    }

    func testMultipleDecodersWithMixedAccess() {
        // Test multiple decoders being accessed concurrently
        let decoderCount = 5
        let decoders = (0..<decoderCount).map { _ in DCMDecoder() }
        let expectation = XCTestExpectation(description: "Multiple decoders with mixed access")
        let iterations = 30
        let completedCount = DicomTestLockedValue(0)
        let queue = DispatchQueue.global(qos: .userInitiated)

        for i in 0..<iterations {
            queue.async {
                // Access a random decoder
                let decoder = decoders[i % decoderCount]

                // Perform operations
                _ = decoder.isValid()
                _ = decoder.width
                _ = decoder.height
                _ = decoder.getValidationStatus()
                _ = decoder.info(for: 0x00100010)

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
        XCTAssertEqual(completedCount.value, iterations, "All operations across multiple decoders should complete")
    }

    func testMultipleConcurrentOperationsStress() {
        // Comprehensive stress test with multiple concurrent operations
        // This test simulates a realistic high-load scenario with many threads
        // performing different operations simultaneously
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Multiple concurrent operations stress test")
        #if targetEnvironment(simulator)
        let iterations = 50
        let timeout: TimeInterval = 60.0
        #else
        let iterations = 100
        let timeout: TimeInterval = 15.0
        #endif
        let completedCount = DicomTestLockedValue(0)

        // Use multiple queues to simulate different priority operations
        let highPriorityQueue = DispatchQueue.global(qos: .userInteractive)
        let normalPriorityQueue = DispatchQueue.global(qos: .userInitiated)
        #if targetEnvironment(simulator)
        let backgroundQueue = DispatchQueue.global(qos: .utility)
        #else
        let backgroundQueue = DispatchQueue.global(qos: .background)
        #endif

        // DICOM tags for stress testing metadata access
        let commonTags = [
            0x00100010, // Patient Name
            0x00100020, // Patient ID
            0x00080060, // Modality
            0x00280010, // Rows
            0x00280011, // Columns
            0x0020000D, // Study Instance UID
            0x0020000E, // Series Instance UID
            0x00080020, // Study Date
        ]

        for i in 0..<iterations {
            // Distribute operations across different queues
            let selectedQueue: DispatchQueue
            switch i % 3 {
            case 0:
                selectedQueue = highPriorityQueue
            case 1:
                selectedQueue = normalPriorityQueue
            default:
                selectedQueue = backgroundQueue
            }

            selectedQueue.async {
                // Perform a comprehensive set of operations based on iteration
                switch i % 10 {
                case 0:
                    // Validation operations
                    _ = decoder.isValid()
                    let status = decoder.getValidationStatus()
                    _ = status.isValid
                    _ = status.width
                    _ = status.height
                    _ = status.hasPixels
                    _ = status.isCompressed

                case 1:
                    // Dimension and geometry properties
                    _ = decoder.width
                    _ = decoder.height
                    _ = decoder.imageDimensions
                    _ = decoder.pixelSpacingV2
                    _ = decoder.isMultiFrame

                case 2:
                    // Window and rescale parameters
                    _ = decoder.windowSettingsV2
                    _ = decoder.rescaleParametersV2
                    _ = decoder.isGrayscale
                    _ = decoder.isColorImage

                case 3:
                    // Patient metadata access
                    _ = decoder.getPatientInfo()
                    _ = decoder.info(for: 0x00100010) // Patient Name
                    _ = decoder.info(for: 0x00100020) // Patient ID
                    _ = decoder.info(for: 0x00100030) // Patient Birth Date

                case 4:
                    // Study metadata access
                    _ = decoder.getStudyInfo()
                    _ = decoder.info(for: 0x0020000D) // Study Instance UID
                    _ = decoder.info(for: 0x00080020) // Study Date
                    _ = decoder.info(for: 0x00080030) // Study Time

                case 5:
                    // Series metadata access
                    _ = decoder.getSeriesInfo()
                    _ = decoder.info(for: 0x0020000E) // Series Instance UID
                    _ = decoder.info(for: 0x00080060) // Modality
                    _ = decoder.info(for: 0x00200011) // Series Number

                case 6:
                    // Multiple tag queries
                    for tag in commonTags {
                        _ = decoder.info(for: tag)
                    }

                case 7:
                    // Pixel data access - 8-bit and 16-bit
                    _ = decoder.getPixels8()
                    _ = decoder.getPixels16()
                    _ = decoder.width
                    _ = decoder.height

                case 8:
                    // Color and downsampled pixel access
                    _ = decoder.getPixels24()
                    _ = decoder.getDownsampledPixels16(maxDimension: 150)
                    _ = decoder.isColorImage
                    _ = decoder.isGrayscale

                case 9:
                    // Mixed operations - validation, properties, and metadata
                    _ = decoder.getValidationStatus()
                    _ = decoder.imageDimensions
                    _ = decoder.windowSettingsV2
                    _ = decoder.getPatientInfo()
                    for tag in commonTags.prefix(4) {
                        _ = decoder.info(for: tag)
                        _ = decoder.intValue(for: tag)
                        _ = decoder.doubleValue(for: tag)
                    }

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

        wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(completedCount.value, iterations, "All stress test operations should complete")

        // Verify decoder is still in consistent state after stress test
        XCTAssertFalse(decoder.isValid(), "Decoder should still be invalid after stress test")
        let finalStatus = decoder.getValidationStatus()
        XCTAssertFalse(finalStatus.isValid, "Validation status should be consistent")
    }

    func testThreadSanitizerStressTest() throws {
        // ThreadSanitizer stress test with 50+ concurrent file loads
        // This test is specifically designed to detect data races and thread safety issues
        // when multiple threads simultaneously create decoder instances and load files
        let expectation = XCTestExpectation(description: "ThreadSanitizer stress test with concurrent file loads")
        let iterations = 55 // 50+ as required
        let completedCount = DicomTestLockedValue(0)

        let testFiles: [String]
        do {
            testFiles = try [
                getCTSyntheticFixtureURL().path,
                getMRSyntheticFixtureURL().path,
                getUSSyntheticFixtureURL().path,
                getXRSyntheticFixtureURL().path
            ]
        } catch {
            throw error
        }

        // Use multiple queues with different priorities to maximize contention
        let queues = [
            DispatchQueue.global(qos: .userInteractive),
            DispatchQueue.global(qos: .userInitiated),
            DispatchQueue.global(qos: .default),
            DispatchQueue.global(qos: .utility),
        ]

        for i in 0..<iterations {
            let queue = queues[i % queues.count]
            let testFile = testFiles[i % testFiles.count]

            queue.async {
                // Create decoder and load file using throwing initializer (recommended pattern)
                do {
                    let decoder = try DCMDecoder(contentsOfFile: testFile)

                    // Perform comprehensive operations to stress test all code paths
                    XCTAssertTrue(decoder.isValid(), "Thread \(i): Decoder should be valid after loading")
                    XCTAssertTrue(decoder.dicomFileReadSuccess, "Thread \(i): File read should succeed")

                    // Access validation status
                    let status = decoder.getValidationStatus()
                    XCTAssertTrue(status.isValid, "Thread \(i): Validation status should be valid")
                    XCTAssertGreaterThan(status.width, 0, "Thread \(i): Width should be positive")
                    XCTAssertGreaterThan(status.height, 0, "Thread \(i): Height should be positive")

                    // Access dimension properties
                    XCTAssertGreaterThan(decoder.width, 0, "Thread \(i): Width should be positive")
                    XCTAssertGreaterThan(decoder.height, 0, "Thread \(i): Height should be positive")
                    _ = decoder.imageDimensions
                    _ = decoder.pixelSpacing

                    // Access metadata from multiple tag groups
                    _ = decoder.getPatientInfo()
                    _ = decoder.getStudyInfo()
                    _ = decoder.getSeriesInfo()
                    _ = decoder.info(for: 0x00080060) // Modality
                    _ = decoder.info(for: 0x00280010) // Rows
                    _ = decoder.info(for: 0x00280011) // Columns

                    // Access window and rescale parameters
                    _ = decoder.windowSettings
                    _ = decoder.windowSettingsV2
                    _ = decoder.rescaleParameters
                    _ = decoder.rescaleParametersV2

                    // Access pixel data (stress test the lazy loading mechanism)
                    // Note: Under high concurrency, pixel data may not always be immediately available
                    // The goal is to stress test for data races, not to strictly validate pixel data
                    if decoder.isGrayscale {
                        _ = decoder.getPixels16()
                        _ = decoder.getPixels8()
                    } else if decoder.isColorImage {
                        _ = decoder.getPixels24()
                    }

                    // Test downsampled pixel access (may return empty array if pixels not loaded)
                    _ = decoder.getDownsampledPixels16(maxDimension: 128)

                } catch {
                    XCTFail("Thread \(i): Failed to load file \(testFile): \(error)")
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

        // Allow enough time for all operations to complete
        wait(for: [expectation], timeout: 30.0)
        XCTAssertEqual(
            completedCount.value,
            iterations,
            "All \(iterations) concurrent file load operations should complete"
        )
    }
}
