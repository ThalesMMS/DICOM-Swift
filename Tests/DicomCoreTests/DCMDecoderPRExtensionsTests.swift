import XCTest
@testable import DicomCore

// MARK: - DCMDecoder PR Extensions Tests
//
// Tests for code added or changed in this PR:
//   - DCMDecoder+LegacyConvenience: pixelSpacing, windowSettings, rescaleParameters
//   - DCMDecoder+Loading: init(contentsOf:), init(contentsOfFile:), load(from:), load(fromFile:)
//   - DCMDecoder+LazyMetadata: info(for:), intValue(for:), doubleValue(for:),
//                              hasDecodedPixelBuffers, currentLittleEndian, etc.
//   - DCMDecoder+Pixels: getPixels8/16/24 on unloaded decoder

// Compatibility coverage: this suite intentionally exercises deprecated
// public APIs that remain available (issue #1221); the annotation keeps
// the deliberate legacy usage warning-free without hiding new ones.
@available(*, deprecated)
final class DCMDecoderPRExtensionsTests: XCTestCase {

    // MARK: - DCMDecoder+LegacyConvenience Tests

    func testPixelSpacingDefaultValues() {
        let decoder = DCMDecoder()
        let spacing = decoder.pixelSpacing
        XCTAssertEqual(spacing.width, 1.0, accuracy: 0.001, "Default pixel spacing width should be 1.0")
        XCTAssertEqual(spacing.height, 1.0, accuracy: 0.001, "Default pixel spacing height should be 1.0")
        XCTAssertEqual(spacing.depth, 1.0, accuracy: 0.001, "Default pixel spacing depth should be 1.0")
    }

    func testWindowSettingsDefaultValues() {
        let decoder = DCMDecoder()
        let settings = decoder.windowSettings
        XCTAssertEqual(settings.center, 0.0, accuracy: 0.001, "Default window center should be 0.0")
        XCTAssertEqual(settings.width, 0.0, accuracy: 0.001, "Default window width should be 0.0")
    }

    func testRescaleParametersDefaultValues() {
        let decoder = DCMDecoder()
        let params = decoder.rescaleParameters
        XCTAssertEqual(params.intercept, 0.0, accuracy: 0.001, "Default rescale intercept should be 0.0")
        XCTAssertEqual(params.slope, 1.0, accuracy: 0.001, "Default rescale slope should be 1.0")
    }

    func testRescaleParametersMatchV2Values() {
        let decoder = DCMDecoder()
        let params = decoder.rescaleParameters
        let v2Params = decoder.rescaleParametersV2
        XCTAssertEqual(params.intercept, v2Params.intercept, accuracy: 0.001,
                       "rescaleParameters.intercept should match rescaleParametersV2.intercept")
        XCTAssertEqual(params.slope, v2Params.slope, accuracy: 0.001,
                       "rescaleParameters.slope should match rescaleParametersV2.slope")
    }

    func testIsGrayscaleDefault() {
        let decoder = DCMDecoder()
        XCTAssertTrue(decoder.isGrayscale, "Default decoder should be grayscale (samplesPerPixel=1)")
    }

    func testIsColorImageDefault() {
        let decoder = DCMDecoder()
        XCTAssertFalse(decoder.isColorImage, "Default decoder should not be color (samplesPerPixel=1, not 3)")
    }

    func testIsMultiFrameDefault() {
        let decoder = DCMDecoder()
        XCTAssertFalse(decoder.isMultiFrame, "Default decoder should not be multi-frame (nImages=1)")
    }

    func testImageDimensionsDefault() {
        let decoder = DCMDecoder()
        let dims = decoder.imageDimensions
        XCTAssertEqual(dims.width, decoder.width, "imageDimensions.width should equal width")
        XCTAssertEqual(dims.height, decoder.height, "imageDimensions.height should equal height")
    }

    // MARK: - DCMDecoder+Loading Error Tests

    func testInitContentsOfNonExistentURLThrowsFileNotFound() {
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/path/that/does/not/exist/file.dcm")
        XCTAssertThrowsError(try DCMDecoder(contentsOf: nonExistentURL)) { error in
            if case DICOMError.fileNotFound(let path) = error {
                XCTAssertFalse(path.isEmpty, "fileNotFound error should contain a path")
            } else {
                XCTFail("Expected DICOMError.fileNotFound, got \(error)")
            }
        }
    }

    func testInitContentsOfFileNonExistentPathThrowsFileNotFound() {
        let nonExistentPath = "/nonexistent/path/file.dcm"
        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: nonExistentPath)) { error in
            if case DICOMError.fileNotFound(let path) = error {
                XCTAssertEqual(path, nonExistentPath, "fileNotFound path should match input path")
            } else {
                XCTFail("Expected DICOMError.fileNotFound, got \(error)")
            }
        }
    }

    func testLoadFromNonExistentURLThrowsFileNotFound() {
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/file.dcm")
        XCTAssertThrowsError(try DCMDecoder.load(from: nonExistentURL)) { error in
            if case DICOMError.fileNotFound(_) = error {
                // Expected
            } else {
                XCTFail("Expected DICOMError.fileNotFound, got \(error)")
            }
        }
    }

    func testLoadFromFileNonExistentPathThrowsFileNotFound() {
        let nonExistentPath = "/nonexistent/path/to/file.dcm"
        XCTAssertThrowsError(try DCMDecoder.load(fromFile: nonExistentPath)) { error in
            if case DICOMError.fileNotFound(let path) = error {
                XCTAssertEqual(path, nonExistentPath, "fileNotFound path should match input path")
            } else {
                XCTFail("Expected DICOMError.fileNotFound, got \(error)")
            }
        }
    }

    func testInitContentsOfNonDICOMFileThrowsInvalidFormat() throws {
        // Create a temp file with non-DICOM content
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_not_dicom_\(UUID().uuidString).dcm")
        try "Not a DICOM file".data(using: .utf8)!.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        XCTAssertThrowsError(try DCMDecoder(contentsOf: tempFile)) { error in
            if case DICOMError.invalidDICOMFormat(_) = error {
                // Expected
            } else {
                XCTFail("Expected DICOMError.invalidDICOMFormat, got \(error)")
            }
        }
    }

    func testInitContentsOfFileNonDICOMFileThrowsInvalidFormat() throws {
        // Create a temp file with non-DICOM content
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_not_dicom_\(UUID().uuidString).dcm")
        try "Not a DICOM file".data(using: .utf8)!.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        XCTAssertThrowsError(try DCMDecoder(contentsOfFile: tempFile.path)) { error in
            if case DICOMError.invalidDICOMFormat(_) = error {
                // Expected
            } else {
                XCTFail("Expected DICOMError.invalidDICOMFormat, got \(error)")
            }
        }
    }

    // MARK: - DCMDecoder+LazyMetadata Tests

    func testInfoForReturnsEmptyStringOnDefaultDecoder() {
        let decoder = DCMDecoder()
        let result = decoder.info(for: DicomTag.patientName.rawValue)
        XCTAssertEqual(result, "", "info(for:) on default decoder should return empty string")
    }

    func testIntValueForReturnsNilOnDefaultDecoder() {
        let decoder = DCMDecoder()
        let result = decoder.intValue(for: DicomTag.rows.rawValue)
        XCTAssertNil(result, "intValue(for:) on default decoder should return nil")
    }

    func testDoubleValueForReturnsNilOnDefaultDecoder() {
        let decoder = DCMDecoder()
        let result = decoder.doubleValue(for: DicomTag.windowCenter.rawValue)
        XCTAssertNil(result, "doubleValue(for:) on default decoder should return nil")
    }

    func testHasDecodedPixelBuffersReturnsFalseOnDefault() {
        let decoder = DCMDecoder()
        XCTAssertFalse(decoder.hasDecodedPixelBuffers(), "Default decoder should have no decoded pixel buffers")
    }

    func testDicomDataCountReturnsZeroOnDefault() {
        let decoder = DCMDecoder()
        XCTAssertEqual(decoder.dicomDataCount(), 0, "Default decoder DICOM data count should be 0")
    }

    func testCurrentLittleEndianReturnsTrueByDefault() {
        let decoder = DCMDecoder()
        XCTAssertTrue(decoder.currentLittleEndian(), "Default decoder should use little endian")
    }

    func testCurrentRescaleParametersDefaults() {
        let decoder = DCMDecoder()
        let params = decoder.currentRescaleParameters()
        XCTAssertEqual(params.intercept, 0.0, accuracy: 0.001, "Default rescale intercept should be 0.0")
        XCTAssertEqual(params.slope, 1.0, accuracy: 0.001, "Default rescale slope should be 1.0")
    }

    func testAllTagKeysReturnsEmptyOnDefault() {
        let decoder = DCMDecoder()
        let keys = decoder.allTagKeys()
        XCTAssertTrue(keys.isEmpty, "Default decoder should have no tag keys")
    }

    func testDicomDataSnapshotReturnsEmptyOnDefault() {
        let decoder = DCMDecoder()
        let data = decoder.dicomDataSnapshot()
        XCTAssertEqual(data.count, 0, "Default decoder DICOM data snapshot should be empty")
    }

    // MARK: - DCMDecoder+Pixels Tests

    func testGetPixels8ReturnsNilOnDefaultDecoder() {
        let decoder = DCMDecoder()
        XCTAssertNil(decoder.getPixels8(), "getPixels8() on default decoder should return nil")
    }

    func testGetPixels16ReturnsNilOnDefaultDecoder() {
        let decoder = DCMDecoder()
        XCTAssertNil(decoder.getPixels16(), "getPixels16() on default decoder should return nil")
    }

    func testGetPixels24ReturnsNilOnDefaultDecoder() {
        let decoder = DCMDecoder()
        XCTAssertNil(decoder.getPixels24(), "getPixels24() on default decoder should return nil")
    }

    // MARK: - Public Metadata Behavior

    func testLoadedFixtureExposesDimensionsThroughPublicMetadata() throws {
        let fixtureURL = try getAnyFixtureDICOMURL()
        let decoder = try DCMDecoder(contentsOf: fixtureURL)

        XCTAssertGreaterThan(decoder.width, 0, "Loaded fixture should have a positive width")
        XCTAssertGreaterThan(decoder.height, 0, "Loaded fixture should have a positive height")
        XCTAssertEqual(decoder.intValue(for: .rows), decoder.height, "Rows metadata should match height")
        XCTAssertEqual(decoder.intValue(for: .columns), decoder.width, "Columns metadata should match width")
        XCTAssertFalse(decoder.getAllTags().isEmpty, "Loaded fixture should expose parsed tags")
    }

    // MARK: - setDicomFilename deprecated API Tests

    func testSetDicomFilenameEmptyStringNoOp() {
        let decoder = DCMDecoder()
        // Calling with empty string should be a no-op (documented behavior)
        decoder.setDicomFilename("")
        XCTAssertFalse(decoder.dicomFound, "Setting empty filename should not change dicomFound")
        XCTAssertFalse(decoder.dicomFileReadSuccess, "Setting empty filename should not set dicomFileReadSuccess")
    }

    func testSetDicomFilenameNonExistentFileFails() {
        let decoder = DCMDecoder()
        decoder.setDicomFilename("/path/that/does/not/exist/at/all/file.dcm")
        XCTAssertFalse(decoder.dicomFileReadSuccess, "Non-existent file should not load successfully")
    }

    func testSetDicomFilenameCanRetrySamePathAfterFailure() throws {
        let fixtureURL = try getAnyFixtureDICOMURL()
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("retry_same_path_\(UUID().uuidString).dcm")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let decoder = DCMDecoder()
        decoder.setDicomFilename(tempFile.path)
        XCTAssertFalse(decoder.dicomFileReadSuccess, "Missing file should fail first load")

        try FileManager.default.copyItem(at: fixtureURL, to: tempFile)
        decoder.setDicomFilename(tempFile.path)

        XCTAssertTrue(decoder.dicomFileReadSuccess, "Decoder should retry the same path after the file becomes available")
        XCTAssertTrue(decoder.dicomFound, "Retried file should parse as DICOM")
    }

    func testSetDicomFilenameIdempotentForSameFile() throws {
        // Create a temp non-DICOM file to test idempotency
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("idempotent_test_\(UUID().uuidString).dcm")
        try "not dicom".data(using: .utf8)!.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let decoder = DCMDecoder()
        decoder.setDicomFilename(tempFile.path)
        let firstResult = decoder.dicomFileReadSuccess

        // Calling again with same filename should be idempotent
        decoder.setDicomFilename(tempFile.path)
        XCTAssertEqual(decoder.dicomFileReadSuccess, firstResult,
                       "Calling setDicomFilename with same file should be idempotent")
    }

    // MARK: - Thread Safety Tests

    @MainActor
    func testGetPixels8ThreadSafety() {
        let decoder = DCMDecoder()
        let expectation = self.expectation(description: "Thread-safe pixel access")
        expectation.expectedFulfillmentCount = 10

        for _ in 0..<10 {
            DispatchQueue.global().async {
                _ = decoder.getPixels8()
                _ = decoder.getPixels16()
                _ = decoder.getPixels24()
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0)
    }

    @MainActor
    func testInfoForThreadSafety() {
        let decoder = DCMDecoder()
        let expectation = self.expectation(description: "Thread-safe info access")
        expectation.expectedFulfillmentCount = 10

        for _ in 0..<10 {
            DispatchQueue.global().async {
                _ = decoder.info(for: DicomTag.patientName.rawValue)
                _ = decoder.intValue(for: DicomTag.rows.rawValue)
                _ = decoder.doubleValue(for: DicomTag.windowCenter.rawValue)
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0)
    }

}
