import XCTest
@testable import DicomCore

final class DCMDecoderEdgeCasesTests: XCTestCase {

    // MARK: - DICOMError Comprehensive Coverage Tests

    func testFileOperationErrors() {
        // File not found error
        let fileNotFound = DICOMError.fileNotFound(path: "/nonexistent/path/test.dcm")
        XCTAssertNotNil(fileNotFound.errorDescription, "Should have error description")
        XCTAssertNotNil(fileNotFound.recoverySuggestion, "Should have recovery suggestion")
        XCTAssertEqual(fileNotFound.category, .file, "Should be file category")
        XCTAssertEqual(fileNotFound.severity, .warning, "File not found should be warning")
        XCTAssertTrue(fileNotFound.errorDescription!.contains("/nonexistent/path/test.dcm"))

        // File read error
        let fileReadError = DICOMError.fileReadError(path: "/test/file.dcm", underlyingError: "Permission denied")
        XCTAssertNotNil(fileReadError.errorDescription)
        XCTAssertNotNil(fileReadError.recoverySuggestion)
        XCTAssertEqual(fileReadError.category, .file)
        XCTAssertTrue(fileReadError.errorDescription!.contains("Permission denied"))

        // Invalid file format
        let invalidFormat = DICOMError.invalidFileFormat(path: "/test/file.txt", expectedFormat: "DICOM")
        XCTAssertNotNil(invalidFormat.errorDescription)
        XCTAssertNotNil(invalidFormat.recoverySuggestion)
        XCTAssertEqual(invalidFormat.category, .file)
        XCTAssertEqual(invalidFormat.severity, .warning)

        // File corrupted
        let fileCorrupted = DICOMError.fileCorrupted(path: "/test/bad.dcm", reason: "Invalid magic number")
        XCTAssertNotNil(fileCorrupted.errorDescription)
        XCTAssertEqual(fileCorrupted.category, .file)
        XCTAssertTrue(fileCorrupted.errorDescription!.contains("Invalid magic number"))
    }

    func testDICOMParsingErrors() {
        // Invalid DICOM format
        let invalidFormat = DICOMError.invalidDICOMFormat(reason: "Missing DICM prefix")
        XCTAssertNotNil(invalidFormat.errorDescription)
        XCTAssertNotNil(invalidFormat.recoverySuggestion)
        XCTAssertEqual(invalidFormat.category, .dicom)
        XCTAssertEqual(invalidFormat.severity, .error)
        XCTAssertTrue(invalidFormat.errorDescription!.contains("Missing DICM prefix"))

        // Missing required tag
        let missingTag = DICOMError.missingRequiredTag(tag: "0x00280010", description: "Rows")
        XCTAssertNotNil(missingTag.errorDescription)
        XCTAssertEqual(missingTag.category, .dicom)
        XCTAssertTrue(missingTag.errorDescription!.contains("0x00280010"))
        XCTAssertTrue(missingTag.errorDescription!.contains("Rows"))

        // Unsupported transfer syntax
        let unsupportedSyntax = DICOMError.unsupportedTransferSyntax(syntax: "1.2.840.10008.1.2.4.90")
        XCTAssertNotNil(unsupportedSyntax.errorDescription)
        XCTAssertNotNil(unsupportedSyntax.recoverySuggestion)
        XCTAssertEqual(unsupportedSyntax.category, .dicom)
        XCTAssertTrue(unsupportedSyntax.errorDescription!.contains("1.2.840.10008.1.2.4.90"))

        // Invalid pixel data
        let invalidPixelData = DICOMError.invalidPixelData(reason: "Buffer size mismatch")
        XCTAssertNotNil(invalidPixelData.errorDescription)
        XCTAssertEqual(invalidPixelData.category, .dicom)
        XCTAssertTrue(invalidPixelData.errorDescription!.contains("Buffer size mismatch"))
    }

    func testBoundsCheckingErrors() {
        // Buffer overflow error
        let bufferOverflow = DICOMError.bufferOverflow(operation: "readString", offset: 1024, available: 512)
        XCTAssertNotNil(bufferOverflow.errorDescription)
        XCTAssertNotNil(bufferOverflow.recoverySuggestion)
        XCTAssertEqual(bufferOverflow.category, .dicom)
        XCTAssertEqual(bufferOverflow.severity, .critical, "Buffer overflow should be critical")
        XCTAssertTrue(bufferOverflow.errorDescription!.contains("readString"))
        XCTAssertTrue(bufferOverflow.errorDescription!.contains("1024"))
        XCTAssertTrue(bufferOverflow.errorDescription!.contains("512"))

        // Invalid offset error
        let invalidOffset = DICOMError.invalidOffset(offset: 99999, fileSize: 50000, context: "tag parsing")
        XCTAssertNotNil(invalidOffset.errorDescription)
        XCTAssertNotNil(invalidOffset.recoverySuggestion)
        XCTAssertEqual(invalidOffset.category, .dicom)
        XCTAssertEqual(invalidOffset.severity, .error)
        XCTAssertTrue(invalidOffset.errorDescription!.contains("99999"))
        XCTAssertTrue(invalidOffset.errorDescription!.contains("50000"))
        XCTAssertTrue(invalidOffset.errorDescription!.contains("tag parsing"))

        // Invalid length error
        let invalidLength = DICOMError.invalidLength(requested: 10000, available: 100, context: "element data")
        XCTAssertNotNil(invalidLength.errorDescription)
        XCTAssertNotNil(invalidLength.recoverySuggestion)
        XCTAssertEqual(invalidLength.category, .dicom)
        XCTAssertEqual(invalidLength.severity, .error)
        XCTAssertTrue(invalidLength.errorDescription!.contains("10000"))
        XCTAssertTrue(invalidLength.errorDescription!.contains("100"))
        XCTAssertTrue(invalidLength.errorDescription!.contains("element data"))

        // Excessive allocation error
        let excessiveAllocation = DICOMError.excessiveAllocation(requested: 2147483648, limit: 1073741824, context: "pixel buffer allocation")
        XCTAssertNotNil(excessiveAllocation.errorDescription)
        XCTAssertNotNil(excessiveAllocation.recoverySuggestion)
        XCTAssertEqual(excessiveAllocation.category, .dicom)
        XCTAssertEqual(excessiveAllocation.severity, .critical, "Excessive allocation should be critical")
        XCTAssertTrue(excessiveAllocation.errorDescription!.contains("2147483648"))
        XCTAssertTrue(excessiveAllocation.errorDescription!.contains("1073741824"))
        XCTAssertTrue(excessiveAllocation.errorDescription!.contains("pixel buffer allocation"))
    }

    func testInvalidElementLengthError() {
        // Specific test for invalid element length scenario
        let error = DICOMError.invalidLength(requested: 4294967295, available: 1024, context: "DICOM element length")
        XCTAssertNotNil(error.errorDescription, "Should have error description")
        XCTAssertNotNil(error.recoverySuggestion, "Should have recovery suggestion")
        XCTAssertEqual(error.category, .dicom, "Should be DICOM category")
        XCTAssertEqual(error.severity, .error, "Should be error severity")

        // Verify the error message contains relevant details
        XCTAssertTrue(error.errorDescription!.contains("4294967295"), "Should mention requested length")
        XCTAssertTrue(error.errorDescription!.contains("1024"), "Should mention available bytes")
        XCTAssertTrue(error.errorDescription!.contains("DICOM element length"), "Should mention context")
        XCTAssertTrue(error.recoverySuggestion!.contains("malformed") || error.recoverySuggestion!.contains("corrupted"),
                      "Recovery suggestion should mention file corruption")
    }

    func testMedicalDataErrors() {
        // Invalid window level
        let invalidWindow = DICOMError.invalidWindowLevel(window: -100, level: 50, reason: "Negative window width")
        XCTAssertNotNil(invalidWindow.errorDescription)
        XCTAssertNotNil(invalidWindow.recoverySuggestion)
        XCTAssertEqual(invalidWindow.category, .medical)
        XCTAssertTrue(invalidWindow.errorDescription!.contains("-100"))
        XCTAssertTrue(invalidWindow.errorDescription!.contains("50"))

        // Invalid patient data
        let invalidPatient = DICOMError.invalidPatientData(field: "PatientBirthDate", value: "invalid", reason: "Not in YYYYMMDD format")
        XCTAssertNotNil(invalidPatient.errorDescription)
        XCTAssertEqual(invalidPatient.category, .medical)
        XCTAssertTrue(invalidPatient.errorDescription!.contains("PatientBirthDate"))

        // Missing study information
        let missingStudy = DICOMError.missingStudyInformation(missingFields: ["StudyDate", "StudyTime", "StudyInstanceUID"])
        XCTAssertNotNil(missingStudy.errorDescription)
        XCTAssertEqual(missingStudy.category, .medical)
        XCTAssertTrue(missingStudy.errorDescription!.contains("StudyDate"))
        XCTAssertTrue(missingStudy.errorDescription!.contains("StudyTime"))

        // Invalid modality
        let invalidModality = DICOMError.invalidModality(modality: "UNKNOWN")
        XCTAssertNotNil(invalidModality.errorDescription)
        XCTAssertEqual(invalidModality.category, .medical)
        XCTAssertTrue(invalidModality.errorDescription!.contains("UNKNOWN"))
    }

    func testNetworkErrors() {
        // Network unavailable
        let networkUnavailable = DICOMError.networkUnavailable
        XCTAssertNotNil(networkUnavailable.errorDescription)
        XCTAssertNotNil(networkUnavailable.recoverySuggestion)
        XCTAssertEqual(networkUnavailable.category, .network)
        XCTAssertEqual(networkUnavailable.severity, .error)

        // Server error
        let serverError = DICOMError.serverError(statusCode: 500, message: "Internal Server Error")
        XCTAssertNotNil(serverError.errorDescription)
        XCTAssertEqual(serverError.category, .network)
        XCTAssertTrue(serverError.errorDescription!.contains("500"))
        XCTAssertTrue(serverError.errorDescription!.contains("Internal Server Error"))

        // Authentication failed
        let authFailed = DICOMError.authenticationFailed(reason: "Invalid credentials")
        XCTAssertNotNil(authFailed.errorDescription)
        XCTAssertEqual(authFailed.category, .network)
        XCTAssertTrue(authFailed.errorDescription!.contains("Invalid credentials"))
    }

    func testSystemErrors() {
        // Memory allocation failed
        let memoryError = DICOMError.memoryAllocationFailed(requestedSize: 1073741824)
        XCTAssertNotNil(memoryError.errorDescription)
        XCTAssertNotNil(memoryError.recoverySuggestion)
        XCTAssertEqual(memoryError.category, .system)
        XCTAssertEqual(memoryError.severity, .critical, "Memory error should be critical")
        XCTAssertTrue(memoryError.errorDescription!.contains("1073741824"))

        // Image processing failed
        let processingError = DICOMError.imageProcessingFailed(operation: "windowing", reason: "Invalid pixel range")
        XCTAssertNotNil(processingError.errorDescription)
        XCTAssertEqual(processingError.category, .system)
        XCTAssertTrue(processingError.errorDescription!.contains("windowing"))
        XCTAssertTrue(processingError.errorDescription!.contains("Invalid pixel range"))

        // Unknown error
        let unknownError = DICOMError.unknown(underlyingError: "Unexpected condition")
        XCTAssertNotNil(unknownError.errorDescription)
        XCTAssertNotNil(unknownError.recoverySuggestion)
        XCTAssertEqual(unknownError.category, .system)
        XCTAssertTrue(unknownError.errorDescription!.contains("Unexpected condition"))
    }

    func testErrorEquality() {
        // Test that equal errors match
        let error1 = DICOMError.fileNotFound(path: "/test/path")
        let error2 = DICOMError.fileNotFound(path: "/test/path")
        XCTAssertEqual(error1, error2, "Identical errors should be equal")

        // Test that different errors don't match
        let error3 = DICOMError.fileNotFound(path: "/different/path")
        XCTAssertNotEqual(error1, error3, "Different paths should not be equal")

        let error4 = DICOMError.invalidDICOMFormat(reason: "test")
        XCTAssertNotEqual(error1, error4, "Different error types should not be equal")
    }

    func testErrorSeverityClassification() {
        // Warning severity
        let warningErrors: [DICOMError] = [
            .fileNotFound(path: "/test"),
            .invalidFileFormat(path: "/test", expectedFormat: "DICOM")
        ]
        for error in warningErrors {
            XCTAssertEqual(error.severity, .warning, "\(error) should be warning severity")
        }

        // Error severity
        let regularErrors: [DICOMError] = [
            .networkUnavailable,
            .invalidDICOMFormat(reason: "test"),
            .unsupportedTransferSyntax(syntax: "test"),
            .fileReadError(path: "/test", underlyingError: "test"),
            .invalidOffset(offset: 100, fileSize: 50, context: "test"),
            .invalidLength(requested: 100, available: 50, context: "test")
        ]
        for error in regularErrors {
            XCTAssertEqual(error.severity, .error, "\(error) should be error severity")
        }

        // Critical severity
        let criticalErrors: [DICOMError] = [
            .memoryAllocationFailed(requestedSize: 1000000),
            .bufferOverflow(operation: "test", offset: 100, available: 50),
            .excessiveAllocation(requested: 2000000, limit: 1000000, context: "test")
        ]
        for error in criticalErrors {
            XCTAssertEqual(error.severity, .critical, "\(error) should be critical severity")
        }
    }

    func testErrorCategoryClassification() {
        // File category
        let fileErrors: [DICOMError] = [
            .fileNotFound(path: "/test"),
            .fileReadError(path: "/test", underlyingError: "test"),
            .invalidFileFormat(path: "/test", expectedFormat: "DICOM"),
            .fileCorrupted(path: "/test", reason: "test")
        ]
        for error in fileErrors {
            XCTAssertEqual(error.category, .file, "\(error) should be file category")
        }

        // DICOM category
        let dicomErrors: [DICOMError] = [
            .invalidDICOMFormat(reason: "test"),
            .missingRequiredTag(tag: "0x0010", description: "test"),
            .unsupportedTransferSyntax(syntax: "test"),
            .invalidPixelData(reason: "test"),
            .bufferOverflow(operation: "test", offset: 100, available: 50),
            .invalidOffset(offset: 100, fileSize: 50, context: "test"),
            .invalidLength(requested: 100, available: 50, context: "test"),
            .excessiveAllocation(requested: 2000000, limit: 1000000, context: "test")
        ]
        for error in dicomErrors {
            XCTAssertEqual(error.category, .dicom, "\(error) should be DICOM category")
        }

        // Medical category
        let medicalErrors: [DICOMError] = [
            .invalidWindowLevel(window: 100, level: 50, reason: "test"),
            .invalidPatientData(field: "test", value: "test", reason: "test"),
            .missingStudyInformation(missingFields: ["test"]),
            .invalidModality(modality: "test")
        ]
        for error in medicalErrors {
            XCTAssertEqual(error.category, .medical, "\(error) should be medical category")
        }

        // Network category
        let networkErrors: [DICOMError] = [
            .networkUnavailable,
            .serverError(statusCode: 500, message: "test"),
            .authenticationFailed(reason: "test")
        ]
        for error in networkErrors {
            XCTAssertEqual(error.category, .network, "\(error) should be network category")
        }

        // System category
        let systemErrors: [DICOMError] = [
            .memoryAllocationFailed(requestedSize: 1000),
            .imageProcessingFailed(operation: "test", reason: "test"),
            .unknown(underlyingError: "test")
        ]
        for error in systemErrors {
            XCTAssertEqual(error.category, .system, "\(error) should be system category")
        }
    }

    // MARK: - Malformed File Tests

    func testEmptyFilePath() {
        let decoder = try? DCMDecoder(contentsOfFile: "")
        XCTAssertNil(decoder, "Empty path should return nil decoder")
    }

    func testNonexistentFile() {
        let nonexistentPath = "/tmp/nonexistent_dicom_file_\(UUID().uuidString).dcm"
        let decoder = try? DCMDecoder(contentsOfFile: nonexistentPath)
        XCTAssertNil(decoder, "Nonexistent file should return nil decoder")
    }

    func testFileValidationNonexistent() {
        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile("/tmp/nonexistent_\(UUID().uuidString).dcm")
        XCTAssertFalse(result.isValid, "Validation should fail for nonexistent file")
        XCTAssertFalse(result.issues.isEmpty, "Should have validation issues")
        XCTAssertTrue(result.issues.first?.contains("exist") ?? false, "Should mention file existence")
    }

    func testFileValidationWithEmptyFile() throws {
        // Create temporary empty file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("empty_\(UUID().uuidString).dcm")
        try Data().write(to: tempFile)

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile(tempFile.path)
        XCTAssertFalse(result.isValid, "Validation should fail for empty file")
        XCTAssertFalse(result.issues.isEmpty, "Should have validation issues for empty file")
    }

    func testFileValidationWithTooSmallFile() throws {
        // Create temporary file smaller than DICOM minimum (132 bytes)
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("small_\(UUID().uuidString).dcm")
        let smallData = Data(repeating: 0, count: 50)
        try smallData.write(to: tempFile)

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile(tempFile.path)
        // Small files get a warning but still pass validation (isValid: true)
        XCTAssertTrue(result.isValid, "Small file should pass with warnings")
        XCTAssertFalse(result.issues.isEmpty, "Should have validation warnings")
        XCTAssertTrue(result.issues.contains { $0.contains("132 bytes") }, "Should warn about file size")
    }

    func testFileValidationWithoutDICMPrefix() throws {
        // Create file without DICM magic number at offset 128
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("no_dicm_\(UUID().uuidString).dcm")
        var data = Data(repeating: 0, count: 132)
        data.replaceSubrange(128..<132, with: Data([0x44, 0x49, 0x43, 0x58])) // DICX instead of DICM
        try data.write(to: tempFile)

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile(tempFile.path)
        // Missing DICM prefix is a warning but still passes validation (preamble is optional)
        XCTAssertTrue(result.isValid, "Should pass with warning (DICM preamble is optional)")
        XCTAssertTrue(result.issues.contains { $0.contains("DICM") }, "Should mention missing DICM prefix")
    }

    func testDecoderWithMalformedData() throws {
        // Create file with DICM prefix but invalid tag structure
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("malformed_\(UUID().uuidString).dcm")
        var data = Data(repeating: 0, count: 132)
        // Add DICM prefix
        data.replaceSubrange(128..<132, with: Data([0x44, 0x49, 0x43, 0x4D])) // DICM
        // Add some random data instead of valid DICOM tags
        data.append(Data(repeating: 0xFF, count: 100))
        try data.write(to: tempFile)

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        guard let decoder = try? DCMDecoder(contentsOfFile: tempFile.path) else {
            // Malformed file may fail to load
            return
        }
        // File may load but should not have valid image data
        XCTAssertEqual(decoder.width, 1, "Width should be default for malformed file")
        XCTAssertEqual(decoder.height, 1, "Height should be default for malformed file")
    }

    // MARK: - Missing Required Tags Tests

    func testDecoderWithMissingImageDimensions() {
        let decoder = DCMDecoder()
        // Without loading a proper file, dimensions should be defaults
        XCTAssertEqual(decoder.width, 1, "Default width should be 1")
        XCTAssertEqual(decoder.height, 1, "Default height should be 1")
        XCTAssertFalse(decoder.isValid(), "Decoder without proper file should not be valid")
    }

    func testValidationStatusWithoutFile() {
        let decoder = DCMDecoder()
        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.isValid, "Should not be valid without file")
        XCTAssertEqual(status.width, 1, "Default width")
        XCTAssertEqual(status.height, 1, "Default height")
        XCTAssertFalse(status.hasPixels, "Should not have pixels")
        XCTAssertFalse(status.isCompressed, "Should not be compressed by default")
    }

    func testPixelBuffersWithoutFile() {
        let decoder = DCMDecoder()
        XCTAssertNil(decoder.getPixels8(), "Should have no 8-bit pixels without file")
        XCTAssertNil(decoder.getPixels16(), "Should have no 16-bit pixels without file")
        XCTAssertNil(decoder.getPixels24(), "Should have no 24-bit pixels without file")
    }

    // MARK: - Boundary Condition Tests

    func testZeroLengthValues() {
        let decoder = DCMDecoder()
        // Test that empty info values are handled correctly
        let emptyValue = decoder.info(for: 0x99999999) // Nonexistent tag
        XCTAssertEqual(emptyValue, "", "Nonexistent tag should return empty string")
    }

    func testExtremeTagValues() {
        let decoder = DCMDecoder()
        // Test with maximum possible tag value
        let maxTag = decoder.info(for: 0xFFFFFFFF)
        XCTAssertNotNil(maxTag, "Should handle maximum tag value")

        // Test with minimum tag value
        let minTag = decoder.info(for: 0x00000000)
        XCTAssertNotNil(minTag, "Should handle minimum tag value")
    }

    func testUnusualImageDimensions() {
        let decoder = DCMDecoder()
        // Test that decoder handles unusual dimensions gracefully
        // Default dimensions should be 1x1
        XCTAssertGreaterThan(decoder.width, 0, "Width should be positive")
        XCTAssertGreaterThan(decoder.height, 0, "Height should be positive")

        let dimensions = decoder.imageDimensions
        XCTAssertGreaterThan(dimensions.width, 0, "Dimension width should be positive")
        XCTAssertGreaterThan(dimensions.height, 0, "Dimension height should be positive")
    }

    func testExtremeRescaleValues() {
        let decoder = DCMDecoder()
        let rescale = decoder.rescaleParametersV2
        // Default values should be 0.0 intercept and 1.0 slope
        XCTAssertEqual(rescale.intercept, 0.0, "Default intercept should be 0")
        XCTAssertEqual(rescale.slope, 1.0, "Default slope should be 1")
    }

    func testExtremeWindowLevelValues() {
        let decoder = DCMDecoder()
        let window = decoder.windowSettingsV2
        // Without a file, these should have default values
        XCTAssertNotNil(window.center, "Window center should exist")
        XCTAssertNotNil(window.width, "Window width should exist")
    }

    func testWindowLevelBoundaryValues() {
        // Test extreme window/level combinations with actual pixel data
        let testPixels: [UInt16] = [0, 1000, 2000, 3000, 4000, 5000]

        let extremeValues = [
            (window: 1.0, level: 0.0),
            (window: 65536.0, level: 32768.0),
            (window: 0.001, level: 0.0),
            (window: 10000.0, level: -5000.0)
        ]

        for (window, level) in extremeValues {
            let result = DCMWindowingProcessor.applyWindowLevel(pixels16: testPixels, center: level, width: window)
            // Window width > 0 should produce result
            if window > 0 {
                XCTAssertNotNil(result, "Should produce result for window=\(window), level=\(level)")
            }
        }
    }

    func testPixelValueHounsfieldBoundaries() {
        // Test Hounsfield unit conversion at extreme values
        let slope = 1.0
        let intercept = -1024.0

        // Test minimum CT value (air)
        let airHU = DCMWindowingProcessor.pixelValueToHU(pixelValue: 0.0, rescaleSlope: slope, rescaleIntercept: intercept)
        XCTAssertEqual(airHU, -1024.0, accuracy: 0.01, "Air should be -1024 HU")

        // Test water value
        let waterHU = DCMWindowingProcessor.pixelValueToHU(pixelValue: 1024.0, rescaleSlope: slope, rescaleIntercept: intercept)
        XCTAssertEqual(waterHU, 0.0, accuracy: 0.01, "Water should be 0 HU")

        // Test bone value
        let bonePixel = DCMWindowingProcessor.huToPixelValue(hu: 1000.0, rescaleSlope: slope, rescaleIntercept: intercept)
        XCTAssertEqual(bonePixel, 2024.0, accuracy: 0.01, "1000 HU should equal 2024 pixel value")

        // Test extreme negative HU
        let extremeNegativePixel = DCMWindowingProcessor.huToPixelValue(hu: -2000.0, rescaleSlope: slope, rescaleIntercept: intercept)
        XCTAssertGreaterThanOrEqual(extremeNegativePixel, -1024.0, "Should handle extreme negative HU")

        // Test extreme positive HU (metal)
        let metalPixel = DCMWindowingProcessor.huToPixelValue(hu: 3000.0, rescaleSlope: slope, rescaleIntercept: intercept)
        XCTAssertEqual(metalPixel, 4024.0, accuracy: 0.01, "3000 HU should equal 4024 pixel value")
    }

    func testRescaleParameterBoundaries() {
        // Test with zero slope (edge case)
        let zeroSlopeHU = DCMWindowingProcessor.pixelValueToHU(pixelValue: 1000.0, rescaleSlope: 0.0, rescaleIntercept: 0.0)
        XCTAssertEqual(zeroSlopeHU, 0.0, accuracy: 0.01, "Zero slope should result in intercept value")

        // Test with negative slope
        let negativeSlopeHU = DCMWindowingProcessor.pixelValueToHU(pixelValue: 100.0, rescaleSlope: -1.0, rescaleIntercept: 0.0)
        XCTAssertEqual(negativeSlopeHU, -100.0, accuracy: 0.01, "Negative slope should invert values")

        // Test with very large slope
        let largeSlopeHU = DCMWindowingProcessor.pixelValueToHU(pixelValue: 1.0, rescaleSlope: 1000.0, rescaleIntercept: 0.0)
        XCTAssertEqual(largeSlopeHU, 1000.0, accuracy: 0.01, "Large slope should amplify values")

        // Test with very small slope
        let smallSlopeHU = DCMWindowingProcessor.pixelValueToHU(pixelValue: 1000.0, rescaleSlope: 0.001, rescaleIntercept: 0.0)
        XCTAssertEqual(smallSlopeHU, 1.0, accuracy: 0.01, "Small slope should reduce values")
    }

    func testPixelSpacingBoundaries() {
        let decoder = DCMDecoder()
        let spacing = decoder.pixelSpacingV2

        // Test default spacing values are valid
        XCTAssertGreaterThanOrEqual(spacing.x, 0.0, "Pixel width should be non-negative")
        XCTAssertGreaterThanOrEqual(spacing.y, 0.0, "Pixel height should be non-negative")
        XCTAssertGreaterThanOrEqual(spacing.z, 0.0, "Pixel depth should be non-negative")

        // Test individual accessors
        XCTAssertEqual(spacing.x, decoder.pixelWidth, "Spacing width should match pixelWidth")
        XCTAssertEqual(spacing.y, decoder.pixelHeight, "Spacing height should match pixelHeight")
        XCTAssertEqual(spacing.z, decoder.pixelDepth, "Spacing depth should match pixelDepth")
    }

    func testEmptyPixelArrays() {
        // Test windowing with empty arrays
        let emptyPixels16: [UInt16] = []
        let result16 = DCMWindowingProcessor.applyWindowLevel(pixels16: emptyPixels16, center: 40.0, width: 400.0)
        XCTAssertNil(result16, "Empty input should return nil")

        // Test quality metrics with empty array
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: emptyPixels16)
        XCTAssertEqual(metrics["mean"] ?? 0.0, 0.0, "Mean of empty array should be 0")
        XCTAssertEqual(metrics["std_deviation"] ?? 0.0, 0.0, "Std dev of empty array should be 0")

        // Test optimal window calculation with empty array
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: emptyPixels16)
        XCTAssertGreaterThanOrEqual(optimal.width, 0, "Width should be non-negative for empty array")
    }

    func testSinglePixelArrays() {
        // Test with single pixel
        let singlePixel16: [UInt16] = [1000]
        let result16 = DCMWindowingProcessor.applyWindowLevel(pixels16: singlePixel16, center: 1000.0, width: 400.0)
        XCTAssertNotNil(result16, "Single pixel should produce result")
        XCTAssertEqual(result16?.count, 1, "Single pixel should produce single output")

        // Test quality metrics with single pixel
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: singlePixel16)
        XCTAssertEqual(metrics["mean"] ?? 0.0, 1000.0, accuracy: 0.01, "Mean should equal single pixel value")
        XCTAssertEqual(metrics["std_deviation"] ?? 0.0, 0.0, "Std dev of single value should be 0")
        XCTAssertEqual(metrics["min_value"] ?? 0.0, 1000.0, "Min should equal single value")
        XCTAssertEqual(metrics["max_value"] ?? 0.0, 1000.0, "Max should equal single value")

        // Test optimal window with single pixel
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: singlePixel16)
        XCTAssertGreaterThan(optimal.width, 0, "Width should be positive")
    }

    func testMaximumPixelValues() {
        // Test with 16-bit maximum values
        let maxPixels16: [UInt16] = [UInt16.max, UInt16.max, UInt16.max]
        let result16 = DCMWindowingProcessor.applyWindowLevel(pixels16: maxPixels16, center: 32768.0, width: 65536.0)
        XCTAssertNotNil(result16, "Should process max value pixels")
        XCTAssertEqual(result16?.count, 3, "Should process all max value pixels")

        // Test metrics with max values
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: maxPixels16)
        XCTAssertEqual(metrics["mean"] ?? 0.0, Double(UInt16.max), accuracy: 0.01, "Mean should equal max value")
        XCTAssertEqual(metrics["min_value"] ?? 0.0, Double(UInt16.max), "Min should equal max value")
        XCTAssertEqual(metrics["max_value"] ?? 0.0, Double(UInt16.max), "Max should equal max value")
    }

    func testMinimumPixelValues() {
        // Test with 16-bit minimum values (all zeros)
        let minPixels16: [UInt16] = [0, 0, 0, 0, 0]
        let result16 = DCMWindowingProcessor.applyWindowLevel(pixels16: minPixels16, center: 0.0, width: 1.0)
        XCTAssertNotNil(result16, "Should process zero pixels")
        XCTAssertEqual(result16?.count, 5, "Should process all zero pixels")

        // Test metrics with min values
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: minPixels16)
        XCTAssertEqual(metrics["mean"] ?? 0.0, 0.0, accuracy: 0.01, "Mean should be 0")
        XCTAssertEqual(metrics["min_value"] ?? 0.0, 0.0, "Min should be 0")
        XCTAssertEqual(metrics["max_value"] ?? 0.0, 0.0, "Max should be 0")
        // Dynamic range is -inf when all values are the same (log10(0) = -inf)
        let dynamicRange = metrics["dynamic_range"] ?? 0.0
        XCTAssertTrue(dynamicRange.isInfinite || dynamicRange == 0.0, "Dynamic range should be 0 or -inf for uniform values")
    }

    func testLargePixelArrays() {
        // Test with large array (simulate high-resolution image)
        let largeSize = 1024 * 1024 // 1 megapixel
        let largePixels16: [UInt16] = Array(repeating: 1000, count: largeSize)

        // Test that windowing can handle large arrays
        let result16 = DCMWindowingProcessor.applyWindowLevel(pixels16: largePixels16, center: 1000.0, width: 400.0)
        XCTAssertNotNil(result16, "Should process large arrays")
        XCTAssertEqual(result16?.count, largeSize, "Should process all pixels in large array")

        // Test metrics calculation on large array
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: largePixels16)
        XCTAssertEqual(metrics["mean"] ?? 0.0, 1000.0, accuracy: 0.01, "Mean should be correct for large array")
    }

    func testUniformPixelDistribution() {
        // Test with uniform distribution across entire range
        let uniformPixels16: [UInt16] = stride(from: 0, to: 65536, by: 256).map { UInt16($0) }
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: uniformPixels16)

        XCTAssertGreaterThan(metrics["std_deviation"]!, 0, "Uniform distribution should have non-zero std dev")
        XCTAssertGreaterThan(metrics["dynamic_range"]!, 0, "Uniform distribution should have non-zero dynamic range")
        XCTAssertEqual(metrics["min_value"], 0.0, "Min should be 0")
        XCTAssertGreaterThan(metrics["max_value"]!, 60000.0, "Max should be near UInt16.max")
    }

    func testBimodalPixelDistribution() {
        // Test with bimodal distribution (two peaks)
        let bimodalPixels16: [UInt16] = Array(repeating: 1000, count: 500) +
                                        Array(repeating: 3000, count: 500)

        let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: bimodalPixels16)
        let mean = metrics["mean"]!
        XCTAssertGreaterThan(mean, 1000.0, "Mean should be between the two peaks")
        XCTAssertLessThan(mean, 3000.0, "Mean should be between the two peaks")

        // Test optimal window calculation
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: bimodalPixels16)
        XCTAssertGreaterThan(optimal.width, 0, "Width should be positive")
        XCTAssertGreaterThan(optimal.center, 1000.0, "Center should be between peaks")
        XCTAssertLessThan(optimal.center, 3000.0, "Center should be between peaks")
    }

    func testNegativeWindowWidth() {
        // Test that negative window width is handled
        let pixels: [UInt16] = [100, 200, 300]
        let result = DCMWindowingProcessor.applyWindowLevel(pixels16: pixels, center: 200.0, width: -400.0)
        // Negative width should return nil (invalid)
        XCTAssertNil(result, "Negative window width should return nil")
    }

    func testZeroWindowWidth() {
        // Test with zero window width (edge case)
        let pixels: [UInt16] = [100, 200, 300]
        let result = DCMWindowingProcessor.applyWindowLevel(pixels16: pixels, center: 200.0, width: 0.0)
        // Zero width should return nil (invalid)
        XCTAssertNil(result, "Zero window width should return nil")
    }

    func testVeryNarrowWindow() {
        // Test with extremely narrow window
        let pixels: [UInt16] = [1000, 1001, 1002, 1003, 1004]
        let result = DCMWindowingProcessor.applyWindowLevel(pixels16: pixels, center: 1002.0, width: 0.1)
        XCTAssertNotNil(result, "Very narrow window should still work")
        XCTAssertEqual(result?.count, pixels.count, "Should handle very narrow window")
    }

    func testVeryWideWindow() {
        // Test with extremely wide window
        let pixels: [UInt16] = [0, 1000, 2000, 30000, 65000]
        let result = DCMWindowingProcessor.applyWindowLevel(pixels16: pixels, center: 32768.0, width: 100000.0)
        XCTAssertNotNil(result, "Very wide window should work")
        XCTAssertEqual(result?.count, pixels.count, "Should handle very wide window")
    }

    func testPresetNameRecognitionTolerance() {
        // Test preset recognition with values near but not exact
        let lungPreset = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)

        // Test with exact values
        let exactSettings = WindowSettings(center: lungPreset.center, width: lungPreset.width)
        let exactName = DCMWindowingProcessor.getPresetName(settings: exactSettings, tolerance: 10.0)
        XCTAssertEqual(exactName, "Lung", "Should recognize exact preset values")

        // Test with values within tolerance
        let nearSettings = WindowSettings(center: lungPreset.center + 5.0, width: lungPreset.width + 5.0)
        let nearName = DCMWindowingProcessor.getPresetName(settings: nearSettings, tolerance: 10.0)
        XCTAssertEqual(nearName, "Lung", "Should recognize values within tolerance")

        // Test with values outside tolerance
        let farSettings = WindowSettings(center: lungPreset.center + 100.0, width: lungPreset.width + 100.0)
        let farName = DCMWindowingProcessor.getPresetName(settings: farSettings, tolerance: 10.0)
        XCTAssertNil(farName, "Should not recognize values outside tolerance")
    }

    func testMemorySizeBoundaries() {
        // Test memory allocation error with various sizes
        let sizes: [Int64] = [0, 1, 1024, 1073741824, Int64.max]

        for size in sizes {
            let error = DICOMError.memoryAllocationFailed(requestedSize: size)
            XCTAssertNotNil(error.errorDescription, "Should have description for size \(size)")
            XCTAssertTrue(error.errorDescription!.contains("\(size)"), "Should include size in description")
        }
    }

    func testServerStatusCodeBoundaries() {
        // Test server error with various HTTP status codes
        let statusCodes = [0, 200, 400, 404, 500, 503, 999, Int.max]

        for code in statusCodes {
            let error = DICOMError.serverError(statusCode: code, message: "Test error")
            XCTAssertNotNil(error.errorDescription, "Should have description for status \(code)")
            XCTAssertTrue(error.errorDescription!.contains("\(code)"), "Should include status code")
        }
    }

    func testEmptyStringParameters() {
        // Test errors with empty string parameters
        let fileNotFound = DICOMError.fileNotFound(path: "")
        XCTAssertNotNil(fileNotFound.errorDescription, "Should handle empty path")

        let invalidFormat = DICOMError.invalidDICOMFormat(reason: "")
        XCTAssertNotNil(invalidFormat.errorDescription, "Should handle empty reason")

        let invalidModality = DICOMError.invalidModality(modality: "")
        XCTAssertNotNil(invalidModality.errorDescription, "Should handle empty modality")
    }

    func testVeryLongStringParameters() {
        // Test errors with very long string parameters
        let longPath = String(repeating: "a", count: 10000)
        let fileError = DICOMError.fileNotFound(path: longPath)
        XCTAssertNotNil(fileError.errorDescription, "Should handle very long path")

        let longReason = String(repeating: "b", count: 10000)
        let formatError = DICOMError.invalidDICOMFormat(reason: longReason)
        XCTAssertNotNil(formatError.errorDescription, "Should handle very long reason")
    }

    func testEmptyMissingFieldsArray() {
        // Test with empty array of missing fields
        let error = DICOMError.missingStudyInformation(missingFields: [])
        XCTAssertNotNil(error.errorDescription, "Should handle empty missing fields array")
    }

    func testLargeMissingFieldsArray() {
        // Test with large array of missing fields
        let manyFields = Array(repeating: "Field", count: 1000)
        let error = DICOMError.missingStudyInformation(missingFields: manyFields)
        XCTAssertNotNil(error.errorDescription, "Should handle large missing fields array")
    }

    // MARK: - State Consistency Tests

    func testDecoderStateAfterFailedLoad() {
        let decoder1 = DCMDecoder()
        let initiallyValid = decoder1.isValid()

        // Try to load a nonexistent file
        let decoder2 = try? DCMDecoder(contentsOfFile: "/tmp/nonexistent_\(UUID().uuidString).dcm")

        XCTAssertNil(decoder2, "Should be nil")
        XCTAssertFalse(initiallyValid, "Initial decoder should not be valid")
    }

    func testDecoderResetOnNewFile() {
        // Load first file (will fail for nonexistent)
        let firstPath = "/tmp/first_\(UUID().uuidString).dcm"
        let decoder1 = try? DCMDecoder(contentsOfFile: firstPath)
        let firstSuccess = decoder1?.isValid() ?? false

        // Load second file (will also fail)
        let secondPath = "/tmp/second_\(UUID().uuidString).dcm"
        let decoder2 = try? DCMDecoder(contentsOfFile: secondPath)
        let secondSuccess = decoder2?.isValid() ?? false

        // Both should fail, but state should be consistent
        XCTAssertFalse(firstSuccess, "First load should fail")
        XCTAssertFalse(secondSuccess, "Second load should fail")
    }

    func testDecoderSkipsSameFile() {
        let samePath = "/tmp/test_\(UUID().uuidString).dcm"

        // Load same file twice
        let decoder1 = try? DCMDecoder(contentsOfFile: samePath)
        let firstAttempt = decoder1?.isValid() ?? false

        let decoder2 = try? DCMDecoder(contentsOfFile: samePath)
        let secondAttempt = decoder2?.isValid() ?? false

        // Results should be consistent (both will fail for nonexistent file)
        XCTAssertEqual(firstAttempt, secondAttempt, "Same file should produce same result")
    }

    // MARK: - Info Dictionary Edge Cases

    func testInfoDictionaryWithInvalidTags() {
        let decoder = DCMDecoder()

        // Test various invalid or unusual tag IDs
        let invalidTags = [
            0x00000000,  // Minimum value
            0xFFFFFFFF,  // Maximum value
            0x12345678,  // Random value
            0xABCDEF00   // Another random value
        ]

        for tag in invalidTags {
            let value = decoder.info(for: tag)
            XCTAssertNotNil(value, "Should return non-nil for tag \(String(format: "0x%08X", tag))")
        }
    }

    func testInfoDictionaryFormatting() {
        let decoder = DCMDecoder()
        // Test that empty decoder returns empty strings for standard tags
        let patientName = decoder.info(for: 0x00100010)
        XCTAssertEqual(patientName, "", "Should return empty string for missing tag")
    }

    func testGetAllInfoDictionary() {
        let decoder = DCMDecoder()
        let allInfo = decoder.getAllTags()
        // Without loading a file, dictionary should be empty or have minimal entries
        XCTAssertNotNil(allInfo, "getAllTags should return non-nil dictionary")
    }

    // MARK: - Async Methods Edge Cases

    func testLoadDICOMFileWithNonexistent() {
        let decoder = try? DCMDecoder(contentsOfFile: "/tmp/nonexistent_\(UUID().uuidString).dcm")
        XCTAssertNil(decoder, "Load should fail for nonexistent file")
    }

    func testGetPixelsWithoutFile() {
        let decoder = DCMDecoder()

        let pixels8 = decoder.getPixels8()
        XCTAssertNil(pixels8, "Should have no 8-bit pixels without file")

        let pixels16 = decoder.getPixels16()
        XCTAssertNil(pixels16, "Should have no 16-bit pixels without file")

        let pixels24 = decoder.getPixels24()
        XCTAssertNil(pixels24, "Should have no 24-bit pixels without file")
    }

    func testDownsampledPixelsWithoutFile() {
        let decoder = DCMDecoder()

        let downsampled16 = decoder.getDownsampledPixels16(maxDimension: 256)
        // Without a valid file, returns default minimal dimensions
        if let result = downsampled16 {
            XCTAssertEqual(result.width, 1, "Default width should be 1")
            XCTAssertEqual(result.height, 1, "Default height should be 1")
            XCTAssertEqual(result.pixels.count, 1, "Should have 1 pixel")
        }
    }

    // MARK: - Thread Safety Under Edge Conditions

    @MainActor
    func testConcurrentAccessDuringFailedLoads() {
        let iterations = 10
        let expectation = self.expectation(description: "Concurrent failed loads")
        expectation.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let path = "/tmp/concurrent_\(i)_\(UUID().uuidString).dcm"
            let decoder = try? DCMDecoder(contentsOfFile: path)
            _ = decoder?.isValid()
            _ = decoder?.getPixels16()
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5.0)
    }

    @MainActor
    func testConcurrentValidationCalls() {
        let decoder = DCMDecoder()
        let iterations = 20
        let expectation = self.expectation(description: "Concurrent validations")
        expectation.expectedFulfillmentCount = iterations

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            _ = decoder.isValid()
            _ = decoder.getValidationStatus()
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5.0)
    }

    // MARK: - Error Categories and Severity Enums

    func testErrorSeverityEnumValues() {
        let allSeverities = ErrorSeverity.allCases
        XCTAssertEqual(allSeverities.count, 3, "Should have 3 severity levels")
        XCTAssertTrue(allSeverities.contains(.warning))
        XCTAssertTrue(allSeverities.contains(.error))
        XCTAssertTrue(allSeverities.contains(.critical))
    }

    func testErrorCategoryEnumValues() {
        let allCategories = ErrorCategory.allCases
        XCTAssertEqual(allCategories.count, 5, "Should have 5 error categories")
        XCTAssertTrue(allCategories.contains(.file))
        XCTAssertTrue(allCategories.contains(.dicom))
        XCTAssertTrue(allCategories.contains(.medical))
        XCTAssertTrue(allCategories.contains(.network))
        XCTAssertTrue(allCategories.contains(.system))
    }

    func testErrorSeverityRawValues() {
        XCTAssertEqual(ErrorSeverity.warning.rawValue, "Warning")
        XCTAssertEqual(ErrorSeverity.error.rawValue, "Error")
        XCTAssertEqual(ErrorSeverity.critical.rawValue, "Critical")
    }

    func testErrorCategoryRawValues() {
        XCTAssertEqual(ErrorCategory.file.rawValue, "File Operation")
        XCTAssertEqual(ErrorCategory.dicom.rawValue, "DICOM Processing")
        XCTAssertEqual(ErrorCategory.medical.rawValue, "Medical Data")
        XCTAssertEqual(ErrorCategory.network.rawValue, "Network")
        XCTAssertEqual(ErrorCategory.system.rawValue, "System")
    }

    // MARK: - DICOMErrorObjC Bridge Tests

    func testDICOMErrorObjCBridge() {
        let swiftError = DICOMError.fileNotFound(path: "/test/path")
        let objcError = DICOMErrorObjC(from: swiftError)

        XCTAssertNotNil(objcError.localizedDescription, "ObjC error should have localized description")
        XCTAssertEqual(objcError.domain, "com.dicomviewer.error", "Should have correct error domain")
        XCTAssertEqual(objcError.code, 1001, "Should have correct error code")

        let userInfo = objcError.userInfo
        XCTAssertNotNil(userInfo[NSLocalizedDescriptionKey], "Should have description in user info")
        XCTAssertNotNil(userInfo[NSLocalizedRecoverySuggestionErrorKey], "Should have recovery suggestion")
    }

    func testDICOMErrorObjCBridgeWithVariousErrors() {
        let testErrors: [DICOMError] = [
            .fileNotFound(path: "/test"),
            .invalidDICOMFormat(reason: "test"),
            .memoryAllocationFailed(requestedSize: 1000),
            .networkUnavailable,
            .invalidPatientData(field: "test", value: "test", reason: "test")
        ]

        for swiftError in testErrors {
            let objcError = DICOMErrorObjC(from: swiftError)
            XCTAssertNotNil(objcError.localizedDescription, "Should have description for \(swiftError)")
            XCTAssertEqual(objcError.domain, "com.dicomviewer.error")
        }
    }
}
