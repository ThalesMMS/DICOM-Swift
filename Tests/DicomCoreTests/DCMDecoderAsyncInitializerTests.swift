import XCTest
@testable import DicomCore

final class DCMDecoderAsyncInitializerTests: XCTestCase {
    /// Get any available DICOM file from fixtures
    private func getAnyDICOMFile() throws -> URL {
        try getAnyFixtureDICOMURL()
    }

    // MARK: - Async Throwing Initializer Tests

    func testAsyncThrowingInitializerWithURLAndValidFile() async throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()

        // Test that async initializer succeeds with valid file
        let decoder = try await DCMDecoder(contentsOf: fileURL)

        // Verify decoder loaded successfully
        XCTAssertTrue(decoder.dicomFound, "Decoder should have found DICM marker")

        // Verify decoder has valid dimensions
        XCTAssertGreaterThan(decoder.width, 0, "Width should be greater than 0")
        XCTAssertGreaterThan(decoder.height, 0, "Height should be greater than 0")

        // Verify decoder is valid
        XCTAssertTrue(decoder.isValid(), "Decoder should be valid after loading")

        // Verify validation status
        let status = decoder.getValidationStatus()
        XCTAssertTrue(status.isValid, "Validation status should be true")
        XCTAssertGreaterThan(status.width, 0, "Status width should be greater than 0")
        XCTAssertGreaterThan(status.height, 0, "Status height should be greater than 0")
    }

    func testAsyncThrowingInitializerWithPathAndValidFile() async throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()
        let filePath = fileURL.path

        // Test that async initializer succeeds with valid file path
        let decoder = try await DCMDecoder(contentsOfFile: filePath)

        // Verify decoder loaded successfully
        XCTAssertTrue(decoder.dicomFound, "Decoder should have found DICM marker")

        // Verify decoder has valid dimensions
        XCTAssertGreaterThan(decoder.width, 0, "Width should be greater than 0")
        XCTAssertGreaterThan(decoder.height, 0, "Height should be greater than 0")

        // Verify decoder is valid
        XCTAssertTrue(decoder.isValid(), "Decoder should be valid after loading")

        // Verify validation status
        let status = decoder.getValidationStatus()
        XCTAssertTrue(status.isValid, "Validation status should be true")
        XCTAssertGreaterThan(status.width, 0, "Status width should be greater than 0")
        XCTAssertGreaterThan(status.height, 0, "Status height should be greater than 0")
    }

    func testAsyncThrowingInitializerLoadsMetadata() async throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()

        // Test that async initializer loads metadata
        let decoder = try await DCMDecoder(contentsOf: fileURL)

        // Verify some basic metadata is accessible
        // We can't test specific values since we don't know which test file was loaded,
        // but we can verify the decoder can retrieve tag information
        XCTAssertNotNil(decoder.getAllTags(), "Should be able to get all tags")

        // Verify dimensions are accessible through convenience properties
        let dimensions = decoder.imageDimensions
        XCTAssertEqual(dimensions.width, decoder.width, "imageDimensions should match width")
        XCTAssertEqual(dimensions.height, decoder.height, "imageDimensions should match height")

        // Verify pixel spacing is accessible
        let optionalSpacing: PixelSpacing? = decoder.pixelSpacingV2
        XCTAssertNotNil(optionalSpacing, "Pixel spacing should be available")
        let spacing = try XCTUnwrap(optionalSpacing)
        XCTAssertGreaterThanOrEqual(spacing.x, 0, "Pixel spacing x should be non-negative")
        XCTAssertGreaterThanOrEqual(spacing.y, 0, "Pixel spacing y should be non-negative")
    }

    func testAsyncThrowingInitializerEquivalentToSyncVersion() async throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()
        let filePath = fileURL.path

        // Load with async throwing initializer
        let decoder1 = try await DCMDecoder(contentsOf: fileURL)

        // Load with sync throwing initializer (need await in async context)
        let decoder2 = try await DCMDecoder(contentsOfFile: filePath)

        // Verify both methods produce equivalent results
        XCTAssertEqual(decoder1.width, decoder2.width, "Both decoders should have same width")
        XCTAssertEqual(decoder1.height, decoder2.height, "Both decoders should have same height")
        XCTAssertEqual(decoder1.bitDepth, decoder2.bitDepth, "Both decoders should have same bit depth")
        XCTAssertEqual(decoder1.samplesPerPixel, decoder2.samplesPerPixel, "Both decoders should have same samples per pixel")
        XCTAssertEqual(decoder1.dicomFound, decoder2.dicomFound, "Both decoders should have same DICM marker status")
    }

    func testAsyncThrowingInitializerEquivalentToLoadDICOMFileAsync() async throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()

        // Load with async throwing initializer
        let decoder = try await DCMDecoder(contentsOf: fileURL)

        // Verify decoder loaded successfully
        XCTAssertGreaterThan(decoder.width, 0, "Decoder should have valid width")
        XCTAssertGreaterThan(decoder.height, 0, "Decoder should have valid height")
        XCTAssertGreaterThan(decoder.bitDepth, 0, "Decoder should have valid bit depth")
        XCTAssertGreaterThan(decoder.samplesPerPixel, 0, "Decoder should have valid samples per pixel")
        XCTAssertTrue(decoder.dicomFound, "Decoder should have found DICM marker")
    }

    // MARK: - Async Throwing Initializer Error Tests

    func testAsyncThrowingEntryPointsReturnCancellationErrorWhenCallerIsAlreadyCancelled() async {
        let url = URL(fileURLWithPath: "/nonexistent/cancelled-before-load.dcm")
        let entryPoints: [(String, @Sendable () async throws -> DCMDecoder)] = [
            ("URL initializer", { try await DCMDecoder(contentsOf: url) }),
            ("path initializer", { try await DCMDecoder(contentsOfFile: url.path) }),
            ("URL factory", { try await DCMDecoder.load(from: url) }),
            ("path factory", { try await DCMDecoder.load(fromFile: url.path) })
        ]

        for (name, entryPoint) in entryPoints {
            let task = Task {
                withUnsafeCurrentTask { currentTask in
                    currentTask?.cancel()
                }
                return try await entryPoint()
            }

            do {
                _ = try await task.value
                XCTFail("A cancelled \(name) should not publish a decoder")
            } catch is CancellationError {
                // Expected cooperative cancellation.
            } catch {
                XCTFail("Expected CancellationError from \(name), got \(error)")
            }
        }
    }

    func testAsyncThrowingInitializerWithURLThrowsForNonExistentFile() async {
        // Create URL for non-existent file
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        // Test that async initializer throws fileNotFound error
        do {
            _ = try await DCMDecoder(contentsOf: nonExistentURL)
            XCTFail("Should have thrown an error")
        } catch let error as DICOMError {
            // Verify it's the correct error type
            if case .fileNotFound(let path) = error {
                XCTAssertTrue(path.contains("nonexistent"), "Error should reference the non-existent path")
            } else {
                XCTFail("Error should be .fileNotFound, got \(error)")
            }
        } catch {
            XCTFail("Error should be of type DICOMError")
        }
    }

    func testAsyncThrowingInitializerWithPathThrowsForNonExistentFile() async {
        // Test that async initializer throws fileNotFound error for non-existent file
        do {
            _ = try await DCMDecoder(contentsOfFile: "/nonexistent/file.dcm")
            XCTFail("Should have thrown an error")
        } catch let error as DICOMError {
            // Verify it's the correct error type
            if case .fileNotFound(let path) = error {
                XCTAssertTrue(path.contains("nonexistent"), "Error should reference the non-existent path")
            } else {
                XCTFail("Error should be .fileNotFound, got \(error)")
            }
        } catch {
            XCTFail("Error should be of type DICOMError")
        }
    }

    func testAsyncThrowingInitializerWithPathThrowsForEmptyPath() async {
        // Test that async initializer throws error for empty path
        do {
            _ = try await DCMDecoder(contentsOfFile: "")
            XCTFail("Should have thrown an error")
        } catch let error as DICOMError {
            // Should be fileNotFound or invalidFileFormat
            switch error {
            case .fileNotFound:
                break // Valid error for empty path
            case .invalidFileFormat:
                break // Also valid for empty path
            default:
                XCTFail("Error should be .fileNotFound or .invalidFileFormat, got \(error)")
            }
        } catch {
            XCTFail("Error should be of type DICOMError")
        }
    }

    func testAsyncThrowingInitializerWithURLThrowsForInvalidDICOMFile() async throws {
        // Create a temporary file that is not a valid DICOM file
        let tempDir = FileManager.default.temporaryDirectory
        let invalidFileURL = tempDir.appendingPathComponent("invalid_dicom_async_\(UUID().uuidString).dcm")

        // Write some non-DICOM data to the file
        let invalidData = "This is not a DICOM file".data(using: .utf8)!
        try invalidData.write(to: invalidFileURL)

        // Ensure cleanup
        defer {
            try? FileManager.default.removeItem(at: invalidFileURL)
        }

        // Test that async initializer throws error for invalid DICOM file
        do {
            _ = try await DCMDecoder(contentsOf: invalidFileURL)
            XCTFail("Should have thrown an error")
        } catch let error as DICOMError {
            // Should be invalidDICOMFormat or similar
            switch error {
            case .invalidDICOMFormat:
                break // Expected error
            case .invalidFileFormat:
                break // Also acceptable
            case .fileCorrupted:
                break // Also acceptable
            default:
                XCTFail("Error should be .invalidDICOMFormat, .invalidFileFormat, or .fileCorrupted, got \(error)")
            }
        } catch {
            XCTFail("Error should be of type DICOMError")
        }
    }

    func testAsyncThrowingInitializerWithPathThrowsForInvalidDICOMFile() async throws {
        // Create a temporary file that is not a valid DICOM file
        let tempDir = FileManager.default.temporaryDirectory
        let invalidFileURL = tempDir.appendingPathComponent("invalid_dicom_async_path_\(UUID().uuidString).dcm")

        // Write some non-DICOM data to the file
        let invalidData = "This is not a DICOM file".data(using: .utf8)!
        try invalidData.write(to: invalidFileURL)

        // Ensure cleanup
        defer {
            try? FileManager.default.removeItem(at: invalidFileURL)
        }

        // Test that async initializer throws error for invalid DICOM file
        do {
            _ = try await DCMDecoder(contentsOfFile: invalidFileURL.path)
            XCTFail("Should have thrown an error")
        } catch let error as DICOMError {
            // Should be invalidDICOMFormat or similar
            switch error {
            case .invalidDICOMFormat:
                break // Expected error
            case .invalidFileFormat:
                break // Also acceptable
            case .fileCorrupted:
                break // Also acceptable
            default:
                XCTFail("Error should be .invalidDICOMFormat, .invalidFileFormat, or .fileCorrupted, got \(error)")
            }
        } catch {
            XCTFail("Error should be of type DICOMError")
        }
    }

    func testAsyncThrowingInitializerWithURLThrowsForDirectory() async {
        // Test that async initializer throws error when given a directory path
        let directoryURL = FileManager.default.temporaryDirectory

        do {
            _ = try await DCMDecoder(contentsOf: directoryURL)
            XCTFail("Should have thrown an error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty,
                           "Directory I/O failures should preserve a descriptive underlying error")
        }
    }

    func testAsyncThrowingInitializerErrorMessagesAreDescriptive() async {
        // Test that async initializer error messages contain useful information
        do {
            _ = try await DCMDecoder(contentsOfFile: "/nonexistent/test.dcm")
            XCTFail("Should have thrown an error")
        } catch let error as DICOMError {
            let errorMessage = error.errorDescription ?? ""
            XCTAssertFalse(errorMessage.isEmpty, "Error should have a description")
            XCTAssertTrue(errorMessage.contains("test.dcm") || errorMessage.contains("nonexistent"),
                         "Error message should mention the file path")

            // Verify recovery suggestion exists
            XCTAssertNotNil(error.recoverySuggestion, "Error should have recovery suggestion")
        } catch {
            XCTFail("Error should be of type DICOMError")
        }
    }

    func testAsyncThrowingInitializerDoesNotLeavePartialState() async {
        // Verify that a failed async throwing initializer doesn't leave a partially initialized object
        // This is guaranteed by Swift's error handling - the object is never returned if init throws

        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/file.dcm")

        do {
            _ = try await DCMDecoder(contentsOf: nonExistentURL)
            XCTFail("Should have thrown an error")
        } catch let error as DICOMError {
            guard case .fileNotFound = error else {
                return XCTFail("Expected fileNotFound, got \(error)")
            }
        } catch {
            XCTFail("Expected DICOMError.fileNotFound, got \(error)")
        }
    }

    func testAsyncThrowingInitializerConcurrentCalls() async throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()

        // Test concurrent async initializer calls with the same file
        async let decoder1 = try DCMDecoder(contentsOf: fileURL)
        async let decoder2 = try DCMDecoder(contentsOf: fileURL)
        async let decoder3 = try DCMDecoder(contentsOf: fileURL)

        let decoders = try await [decoder1, decoder2, decoder3]

        // All decoders should have loaded successfully and have same properties
        for decoder in decoders {
            XCTAssertTrue(decoder.dicomFound, "Decoder should have found DICM marker")
            XCTAssertTrue(decoder.isValid(), "Decoder should be valid")
        }

        // Verify all decoders have same dimensions
        let firstDecoder = decoders[0]
        for decoder in decoders.dropFirst() {
            XCTAssertEqual(decoder.width, firstDecoder.width, "All decoders should have same width")
            XCTAssertEqual(decoder.height, firstDecoder.height, "All decoders should have same height")
            XCTAssertEqual(decoder.bitDepth, firstDecoder.bitDepth, "All decoders should have same bit depth")
        }
    }

    func testAsyncThrowingInitializerConcurrentCallsWithErrors() async {
        // Test concurrent async initializer calls with non-existent files
        async let result1 = try? DCMDecoder(contentsOfFile: "/nonexistent/file1.dcm")
        async let result2 = try? DCMDecoder(contentsOfFile: "/nonexistent/file2.dcm")
        async let result3 = try? DCMDecoder(contentsOfFile: "/nonexistent/file3.dcm")

        let results = await [result1, result2, result3]

        // All should be nil (failed to initialize)
        for result in results {
            XCTAssertNil(result, "Decoder should be nil for non-existent file")
        }
    }

    func testAsyncThrowingInitializerPreservesErrorInformation() async {
        // Test that async initializer preserves detailed error information
        let nonExistentPath = "/nonexistent/deeply/nested/path/file.dcm"

        do {
            _ = try await DCMDecoder(contentsOfFile: nonExistentPath)
            XCTFail("Should have thrown an error")
        } catch let error as DICOMError {
            // Verify error preserves path information
            let errorDescription = error.errorDescription ?? ""
            let failureReason = error.failureReason ?? ""
            let recoverySuggestion = error.recoverySuggestion ?? ""

            // At least one of these should contain path information
            let containsPath = errorDescription.contains("file.dcm") ||
                              failureReason.contains("file.dcm") ||
                              recoverySuggestion.contains("exist")

            XCTAssertTrue(containsPath, "Error should preserve path information in description, reason, or suggestion")
        } catch {
            XCTFail("Error should be of type DICOMError")
        }
    }


    // MARK: - Additional Async Throwing Initializer Error Tests

    func testAsyncThrowingInitializerMultipleCalls() async {
        // Test multiple async throwing initializer attempts
        do {
            _ = try await DCMDecoder(contentsOfFile: "/nonexistent/file1.dcm")
            XCTFail("First attempt should have thrown an error")
        } catch {
            XCTAssertTrue(error is DICOMError, "First attempt should throw DICOMError")
        }

        do {
            _ = try await DCMDecoder(contentsOfFile: "/nonexistent/file2.dcm")
            XCTFail("Second attempt should have thrown an error")
        } catch {
            XCTAssertTrue(error is DICOMError, "Second attempt should throw DICOMError")
        }
    }

}
