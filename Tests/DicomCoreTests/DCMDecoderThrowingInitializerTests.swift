//
//  DCMDecoderThrowingInitializerTests.swift
//  DicomCoreTests
//
//  Checks throwing decoder initialization with missing paths and URLs.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DCMDecoderThrowingInitializerTests: XCTestCase {
    /// Get any available DICOM file from fixtures
    private func getAnyDICOMFile() throws -> URL {
        try getAnyFixtureDICOMURL()
    }

    private func withTemporaryInvalidDICOMFile(_ body: (URL) throws -> Void) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let invalidFileURL = tempDir.appendingPathComponent("invalid_dicom_\(UUID().uuidString).dcm")
        let invalidData = "This is not a DICOM file".data(using: .utf8)!

        try invalidData.write(to: invalidFileURL)
        defer {
            try? FileManager.default.removeItem(at: invalidFileURL)
        }

        try body(invalidFileURL)
    }

    private func missingDICOMPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("missing_\(UUID().uuidString).dcm")
            .path
    }

    private func assertInvalidDICOMFormatError(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let dicomError = error as? DICOMError else {
            XCTFail("Error should be of type DICOMError", file: file, line: line)
            return
        }

        guard case .invalidDICOMFormat = dicomError else {
            XCTFail("Error should be .invalidDICOMFormat, got \(dicomError)", file: file, line: line)
            return
        }
    }

    private func assertFileNotFoundError(_ error: Error, expectedPath: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let dicomError = error as? DICOMError else {
            XCTFail("Error should be of type DICOMError", file: file, line: line)
            return
        }

        guard case .fileNotFound(let path) = dicomError else {
            XCTFail("Error should be .fileNotFound, got \(dicomError)", file: file, line: line)
            return
        }

        XCTAssertEqual(path, expectedPath, "Error should reference the exact missing path", file: file, line: line)
    }

    // MARK: - Throwing Initializer Tests

    func testThrowingInitializerWithURLAndValidFile() throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()

        // Test that initializer succeeds with valid file
        let decoder = try DCMDecoder(contentsOf: fileURL)

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

    func testThrowingInitializerWithPathAndValidFile() throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()
        let filePath = fileURL.path

        // Test that initializer succeeds with valid file path
        let decoder = try DCMDecoder(contentsOfFile: filePath)

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

    func testThrowingInitializerWithDataAndValidBytes() throws {
        let fileURL = try getAnyDICOMFile()
        let data = try Data(contentsOf: fileURL)

        let decoder = try DCMDecoder(data: data)

        XCTAssertTrue(decoder.dicomFound, "Decoder should have found DICM marker")
        XCTAssertGreaterThan(decoder.width, 0, "Width should be greater than 0")
        XCTAssertGreaterThan(decoder.height, 0, "Height should be greater than 0")
        XCTAssertTrue(decoder.isValid(), "Decoder should be valid after loading in-memory bytes")
    }

    func testThrowingInitializerLoadsMetadata() throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()

        // Test that initializer loads metadata
        let decoder = try DCMDecoder(contentsOf: fileURL)

        // Verify some basic metadata is accessible
        // We can't test specific values since we don't know which test file was loaded,
        // but we can verify the decoder can retrieve tag information
        XCTAssertNotNil(decoder.getAllTags(), "Should be able to get all tags")

        // Verify dimensions are accessible through convenience properties
        let dimensions = decoder.imageDimensions
        XCTAssertEqual(dimensions.width, decoder.width, "imageDimensions should match width")
        XCTAssertEqual(dimensions.height, decoder.height, "imageDimensions should match height")

        XCTAssertFalse(
            decoder.info(for: .pixelSpacing).isEmpty,
            "Required bundled fixture must include Pixel Spacing metadata."
        )

        // Verify pixel spacing metadata is accessible when present in the fixture
        let spacing = decoder.pixelSpacingV2
        XCTAssertGreaterThan(spacing.x, 0, "Pixel spacing x should be positive")
        XCTAssertGreaterThan(spacing.y, 0, "Pixel spacing y should be positive")
    }

    func testThrowingInitializerLoadsDecoderState() throws {
        // Get a valid DICOM file from fixtures
        let fileURL = try getAnyDICOMFile()

        // Load with throwing initializer
        let decoder = try DCMDecoder(contentsOf: fileURL)

        // Verify decoder loaded successfully
        XCTAssertGreaterThan(decoder.width, 0, "Decoder should have valid width")
        XCTAssertGreaterThan(decoder.height, 0, "Decoder should have valid height")
        XCTAssertGreaterThan(decoder.bitDepth, 0, "Decoder should have valid bit depth")
        XCTAssertGreaterThan(decoder.samplesPerPixel, 0, "Decoder should have valid samples per pixel")
        XCTAssertTrue(decoder.dicomFound, "Decoder should have found DICM marker")
    }

    // MARK: - Throwing Initializer Error Tests

    func testThrowingInitializerWithURLThrowsForNonExistentFile() {
        // Create URL for non-existent file
        let missingPath = missingDICOMPath()
        let nonExistentURL = URL(fileURLWithPath: missingPath)

        // Test that initializer throws fileNotFound error
        XCTAssertThrowsError(try DCMDecoder(contentsOf: nonExistentURL)) { error in
            assertFileNotFoundError(error, expectedPath: missingPath)
        }
    }

    func testThrowingInitializerWithPathThrowsForNonExistentFile() {
        let missingPath = missingDICOMPath()

        // Test that initializer throws fileNotFound error for non-existent file
        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: missingPath)) { error in
            assertFileNotFoundError(error, expectedPath: missingPath)
        }
    }

    func testThrowingInitializerWithURLThrowsForInvalidDICOMFile() throws {
        try withTemporaryInvalidDICOMFile { invalidFileURL in
            XCTAssertThrowsError(try DCMDecoder(contentsOf: invalidFileURL)) { error in
                assertInvalidDICOMFormatError(error)
            }
        }
    }

    func testThrowingInitializerWithPathThrowsForInvalidDICOMFile() throws {
        try withTemporaryInvalidDICOMFile { invalidFileURL in
            XCTAssertThrowsError(try DCMDecoder(contentsOfFile: invalidFileURL.path)) { error in
                assertInvalidDICOMFormatError(error)
            }
        }
    }

    func testThrowingInitializerWithDataThrowsForInvalidDICOMBytes() {
        let invalidData = Data("This is not a DICOM file".utf8)

        XCTAssertThrowsError(try DCMDecoder(data: invalidData)) { error in
            assertInvalidDICOMFormatError(error)
        }
    }

    func testThrowingInitializerWithURLThrowsForDirectory() {
        // Test that initializer throws error when given a directory path
        let directoryURL = FileManager.default.temporaryDirectory

        XCTAssertThrowsError(try DCMDecoder(contentsOf: directoryURL)) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty,
                           "Directory I/O failures should preserve a descriptive underlying error")
        }
    }

    func testThrowingInitializerErrorMessagesAreDescriptive() {
        // Test that error messages contain useful information
        do {
            _ = try DCMDecoder(contentsOfFile: "/nonexistent/test.dcm")
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

    func testThrowingInitializerDoesNotLeavePartialState() {
        // Verify that a failed throwing initializer doesn't leave a partially initialized object
        // This is guaranteed by Swift's error handling - the object is never returned if init throws

        let missingPath = missingDICOMPath()
        let nonExistentURL = URL(fileURLWithPath: missingPath)

        XCTAssertThrowsError(try DCMDecoder(contentsOf: nonExistentURL)) { error in
            assertFileNotFoundError(error, expectedPath: missingPath)
        }
    }


    // MARK: - File Loading Error Tests

    func testThrowingInitializerWithEmptyPath() {
        // Test throwing initializer with empty filename
        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: "")) { error in
            assertFileNotFoundError(error, expectedPath: "")
        }
    }

    func testThrowingInitializerWithInvalidPaths() {
        // Test throwing initializer with various invalid paths
        let missingNestedPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing_directory_\(UUID().uuidString)")
            .appendingPathComponent("file.dcm")
            .path
        let missingFilePath = missingDICOMPath()

        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: missingNestedPath)) { error in
            assertFileNotFoundError(error, expectedPath: missingNestedPath)
        }

        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: missingFilePath)) { error in
            assertFileNotFoundError(error, expectedPath: missingFilePath)
        }

        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: "/")) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty,
                           "Directory I/O failures should preserve a descriptive underlying error")
        }
    }

    func testThrowingInitializerMultipleAttempts() {
        // Test multiple failed initialization attempts
        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: "/nonexistent/file1.dcm")) { error in
            XCTAssertTrue(error is DICOMError, "First attempt should throw DICOMError")
        }

        // Second attempt should also fail
        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: "/nonexistent/file2.dcm")) { error in
            XCTAssertTrue(error is DICOMError, "Second attempt should throw DICOMError")
        }
    }

    func testThrowingInitializerThreadSafety() async {
        // Test concurrent initialization attempts
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                let missingPath = missingDICOMPath()
                group.addTask {
                    do {
                        _ = try DCMDecoder(contentsOfFile: missingPath)
                        XCTFail("Should have thrown an error")
                    } catch DICOMError.fileNotFound(let path) {
                        XCTAssertEqual(path, missingPath, "Error should reference the exact missing path")
                    } catch {
                        XCTFail("Error should be .fileNotFound, got \(error)")
                    }
                }
            }
        }
    }

    func testThrowingInitializerThreadSafetyWithValidFiles() async throws {
        let fileURL = try getAnyDICOMFile()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        let decoder = try DCMDecoder(contentsOf: fileURL)
                        XCTAssertTrue(decoder.isValid(), "Decoder should be valid after loading")
                        XCTAssertGreaterThan(decoder.width, 0, "Decoder should have valid width")
                        XCTAssertGreaterThan(decoder.height, 0, "Decoder should have valid height")
                    } catch {
                        XCTFail("Valid DICOM initialization should not throw: \(error)")
                    }
                }
            }
        }
    }

    func testThrowingInitializerDoesNotAffectOtherDecoders() {
        // Test that failed initialization doesn't affect other decoder instances
        let validDecoder = DCMDecoder()
        let initialWidth = validDecoder.width
        let initialHeight = validDecoder.height
        let missingPath = missingDICOMPath()

        // Attempt to create invalid decoder
        do {
            _ = try DCMDecoder(contentsOfFile: missingPath)
            XCTFail("Should have thrown an error")
        } catch {
            assertFileNotFoundError(error, expectedPath: missingPath)
        }

        // Original decoder should be unaffected
        XCTAssertEqual(validDecoder.width, initialWidth, "Width should remain unchanged")
        XCTAssertEqual(validDecoder.height, initialHeight, "Height should remain unchanged")
    }

    func testThrowingInitializerWithDirectoryPath() {
        // Test throwing initializer with directory instead of file
        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: "/tmp")) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty,
                           "Directory I/O failures should preserve a descriptive underlying error")
        }
    }

    func testThrowingInitializerWithSymbolicPaths() {
        // Test throwing initializer with various symbolic paths
        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: "~/nonexistent/file.dcm")) { error in
            XCTAssertTrue(error is DICOMError, "Error should be of type DICOMError")
        }

        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: "./nonexistent/file.dcm")) { error in
            XCTAssertTrue(error is DICOMError, "Error should be of type DICOMError")
        }

        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: "../nonexistent/file.dcm")) { error in
            XCTAssertTrue(error is DICOMError, "Error should be of type DICOMError")
        }
    }

    func testUninitializedDecoderState() {
        // Test that uninitialized decoder has correct default state
        let decoder = DCMDecoder()

        // Check all state flags
        XCTAssertFalse(decoder.dicomFound, "DICM marker should not be found")
        XCTAssertFalse(decoder.isValid(), "Should not be valid")

        // Check validation status
        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.isValid, "Validation status should be invalid")
        XCTAssertFalse(status.hasPixels, "Should not have pixels")

        // Check pixel buffers are nil
        XCTAssertNil(decoder.getPixels8(), "pixels8 should be nil")
        XCTAssertNil(decoder.getPixels16(), "pixels16 should be nil")
        XCTAssertNil(decoder.getPixels24(), "pixels24 should be nil")
    }

}
