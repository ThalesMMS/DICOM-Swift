import XCTest
import DicomTestSupport
@testable import DicomCore
import Foundation

final class DCMDecoderIntegrationTests: XCTestCase {

    // MARK: - Setup & Utilities

    /// Get path to fixtures directory
    private func getFixturesPath() -> URL {
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    /// Get DICOM files from specific modality subdirectory
    private func getDICOMFiles(from subdirectory: String) throws -> [URL] {
        try DicomTestRuntimePreflight.require(.bundledSyntheticFixtures)
        let modalityPath = getFixturesPath().appendingPathComponent(subdirectory)

        // Skip if directory doesn't exist
        guard FileManager.default.fileExists(atPath: modalityPath.path) else {
            throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
                capability: .bundledSyntheticFixtures,
                kind: .regression,
                message: "Fixtures directory '\(subdirectory)' not found."
            ))
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: modalityPath,
            includingPropertiesForKeys: nil
        ).filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "dcm" || ext == "dicom"
        }

        guard !files.isEmpty else {
            throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
                capability: .bundledSyntheticFixtures,
                kind: .regression,
                message: "No DICOM files found in required '\(subdirectory)' fixture directory."
            ))
        }

        return files
    }

    /// Get any available DICOM file from fixtures
    private func getAnyDICOMFile() throws -> URL {
        try getAnyFixtureDICOMURL()
    }

    // MARK: - Basic Integration Tests

    func testLoadRealDICOMFile() throws {
        let file = try getAnyDICOMFile()

        guard let decoder = try? DCMDecoder(contentsOf: file) else {
            XCTFail("Should successfully read DICOM file: \(file.lastPathComponent)")
            return
        }

        XCTAssertTrue(decoder.dicomFound, "Should successfully read DICOM file: \(file.lastPathComponent)")
        XCTAssertTrue(decoder.isValid(), "Decoder should be valid after loading real DICOM file")
        XCTAssertGreaterThan(decoder.width, 0, "Image width should be greater than 0")
        XCTAssertGreaterThan(decoder.height, 0, "Image height should be greater than 0")
    }

    func testLoadRealDICOMFileSync() throws {
        let file = try getAnyDICOMFile()

        guard let decoder = try? DCMDecoder(contentsOf: file) else {
            XCTFail("Should successfully load DICOM file: \(file.lastPathComponent)")
            return
        }

        XCTAssertTrue(decoder.dicomFound, "Should have read success flag set")
        XCTAssertTrue(decoder.isValid(), "Decoder should be valid after loading")
        XCTAssertGreaterThan(decoder.width, 0, "Image width should be greater than 0")
        XCTAssertGreaterThan(decoder.height, 0, "Image height should be greater than 0")
    }

    func testValidateRealDICOMFile() throws {
        let file = try getAnyDICOMFile()

        let decoder = DCMDecoder()
        let validation = decoder.validateDICOMFile(file.path)

        XCTAssertTrue(validation.isValid, "Real DICOM file should pass validation: \(file.lastPathComponent)")
        XCTAssertTrue(validation.issues.isEmpty, "Valid DICOM file should have no validation issues")
    }

    func testExtractMetadataFromRealFile() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOf: file)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        // Get all tags - should have at least some metadata
        let allTags = decoder.getAllTags()
        XCTAssertFalse(allTags.isEmpty, "Real DICOM file should have metadata tags")

        // Test common required tags
        let rows = try XCTUnwrap(decoder.intValue(for: 0x00280010))
        let columns = try XCTUnwrap(decoder.intValue(for: 0x00280011))
        XCTAssertEqual(rows, decoder.height, "Rows should match height")
        XCTAssertEqual(columns, decoder.width, "Columns should match width")
    }

    func testExtractPixelDataFromRealFile() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        let validationStatus = decoder.getValidationStatus()
        XCTAssertTrue(validationStatus.hasPixels, "Real DICOM file should have pixel data")

        switch decoder.bitDepth {
        case 8:
            let pixels = try XCTUnwrap(decoder.getPixels8())
            XCTAssertEqual(pixels.count, decoder.width * decoder.height * decoder.samplesPerPixel)
        case 16:
            let pixels = try XCTUnwrap(decoder.getPixels16())
            XCTAssertEqual(pixels.count, decoder.width * decoder.height * decoder.samplesPerPixel)
        case 24:
            let pixels = try XCTUnwrap(decoder.getPixels24())
            XCTAssertEqual(pixels.count, decoder.width * decoder.height)
        default:
            XCTFail("Fixture uses unsupported bit depth \(decoder.bitDepth)")
        }
    }

    // MARK: - Modality-Specific Tests

    func testLoadCTImage() throws {
        let files = try getDICOMFiles(from: "CT")
        let file = files.first!

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read CT file")
        XCTAssertEqual(decoder.info(for: 0x00080060), "CT", "Modality should be CT")

        // CT images are typically 16-bit
        XCTAssertGreaterThanOrEqual(decoder.bitDepth, 8, "CT should have at least 8-bit depth")

        // CT should be grayscale (1 sample per pixel)
        XCTAssertEqual(decoder.samplesPerPixel, 1, "CT should be grayscale")
        XCTAssertTrue(decoder.isGrayscale, "CT should be grayscale")

        // CT should have window/level settings
        XCTAssertNotEqual(decoder.windowWidth, 0.0, "CT should have window width")

        // CT should have Hounsfield units (rescale intercept typically -1024)
        let rescaleType = decoder.info(for: 0x00281054)
        if !rescaleType.isEmpty {
            XCTAssertEqual(rescaleType, "HU", "CT rescale type should be HU (Hounsfield Units)")
        }
    }

    func testLoadMRImage() throws {
        let files = try getDICOMFiles(from: "MR")
        let file = files.first!

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read MR file")
        XCTAssertEqual(decoder.info(for: 0x00080060), "MR", "Modality should be MR")

        // MR images are typically 16-bit grayscale
        XCTAssertEqual(decoder.samplesPerPixel, 1, "MR should be grayscale")
        XCTAssertTrue(decoder.isGrayscale, "MR should be grayscale")

        // MR should have echo time
        let echoTime = decoder.doubleValue(for: 0x00180081)
        if let te = echoTime {
            XCTAssertGreaterThan(te, 0.0, "MR should have positive echo time")
        }

        // MR should have repetition time
        let repetitionTime = decoder.doubleValue(for: 0x00180080)
        if let tr = repetitionTime {
            XCTAssertGreaterThan(tr, 0.0, "MR should have positive repetition time")
        }
    }

    func testLoadXRayImage() throws {
        let files = try getDICOMFiles(from: "XR")
        let file = files.first!

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read X-ray file")

        let modality = decoder.info(for: 0x00080060)
        XCTAssertTrue(["XR", "CR", "DX"].contains(modality), "Modality should be X-ray type (XR, CR, or DX)")

        // X-ray images are typically grayscale
        XCTAssertTrue(decoder.isGrayscale, "X-ray should be grayscale")
    }

    func testLoadUltrasoundImage() throws {
        let files = try getDICOMFiles(from: "US")
        let file = files.first!

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read ultrasound file")
        XCTAssertEqual(decoder.info(for: 0x00080060), "US", "Modality should be US")

        // Ultrasound can be grayscale or color
        XCTAssertTrue(decoder.samplesPerPixel >= 1, "US should have at least 1 sample per pixel")
    }

    // MARK: - Transfer Syntax Tests

    func testLoadLittleEndianExplicitVRImage() throws {
        let file = getFixturesPath()
            .appendingPathComponent("DecoderParity")
            .appendingPathComponent("ct_explicit_vr_le_rescale.dcm")

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file with explicit VR")

        XCTAssertEqual(decoder.info(for: 0x00020010), "1.2.840.10008.1.2.1")
    }

    func testLoadCompressedImage() throws {
        let files = try getDICOMFiles(from: "Compressed")
        let file = files.first!

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.isValid(), "Compressed fixture should decode as a valid DICOM object")
        XCTAssertTrue(decoder.compressedImage, "Compressed file should set compressed flag")
        XCTAssertGreaterThan(decoder.width, 0, "Should have valid dimensions")
        XCTAssertGreaterThan(decoder.height, 0, "Should have valid dimensions")
    }

    // MARK: - Patient/Study/Series Extraction Tests

    func testExtractPatientInformation() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        let patientInfo = decoder.getPatientInfo()
        XCTAssertNotNil(patientInfo, "Should return patient info dictionary")

        // Check dictionary has expected keys
        XCTAssertTrue(patientInfo.keys.contains("Name"), "Should have Name key")
        XCTAssertTrue(patientInfo.keys.contains("ID"), "Should have ID key")
        XCTAssertTrue(patientInfo.keys.contains("Sex"), "Should have Sex key")
        XCTAssertTrue(patientInfo.keys.contains("Age"), "Should have Age key")

        // Values should be strings (may be empty for anonymized files)
        XCTAssertNotNil(patientInfo["Name"], "Name should exist")
        XCTAssertNotNil(patientInfo["ID"], "ID should exist")
    }

    func testExtractStudyInformation() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        let studyInfo = decoder.getStudyInfo()
        XCTAssertNotNil(studyInfo, "Should return study info dictionary")

        // Study Instance UID is required
        XCTAssertTrue(studyInfo.keys.contains("StudyInstanceUID"), "Should have StudyInstanceUID key")

        let studyUID = try XCTUnwrap(studyInfo["StudyInstanceUID"])
        XCTAssertFalse(studyUID.isEmpty)
        XCTAssertTrue(studyUID.contains("."), "Study Instance UID should be a UID (contains dots)")
    }

    func testExtractSeriesInformation() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        let seriesInfo = decoder.getSeriesInfo()
        XCTAssertNotNil(seriesInfo, "Should return series info dictionary")

        // Series Instance UID is required
        XCTAssertTrue(seriesInfo.keys.contains("SeriesInstanceUID"), "Should have SeriesInstanceUID key")

        let seriesUID = try XCTUnwrap(seriesInfo["SeriesInstanceUID"])
        XCTAssertFalse(seriesUID.isEmpty)
        XCTAssertTrue(seriesUID.contains("."), "Series Instance UID should be a UID (contains dots)")

        // Modality should be present
        XCTAssertTrue(seriesInfo.keys.contains("Modality"), "Should have Modality key")
    }

    // MARK: - Image Properties Tests

    func testImageDimensionsConsistency() throws {
        let files = try getDICOMFiles(from: "CT")
        let file = try XCTUnwrap(files.first)

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        // Test convenience properties match direct access
        let dimensions = decoder.imageDimensions
        XCTAssertEqual(dimensions.width, decoder.width, "imageDimensions.width should match width")
        XCTAssertEqual(dimensions.height, decoder.height, "imageDimensions.height should match height")

        let rows = try XCTUnwrap(decoder.intValue(for: 0x00280010))
        let columns = try XCTUnwrap(decoder.intValue(for: 0x00280011))
        XCTAssertEqual(rows, decoder.height, "Rows tag should match height")
        XCTAssertEqual(columns, decoder.width, "Columns tag should match width")
    }

    func testPixelSpacingExtraction() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        let spacing = decoder.pixelSpacingV2
        XCTAssertGreaterThan(spacing.x, 0.0, "Pixel spacing width should be positive")
        XCTAssertGreaterThan(spacing.y, 0.0, "Pixel spacing height should be positive")
        XCTAssertGreaterThan(spacing.z, 0.0, "Pixel spacing depth should be positive")
    }

    func testWindowingSettings() throws {
        let files = try getDICOMFiles(from: "CT")
        let file = try XCTUnwrap(files.first)

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        let windowSettings = decoder.windowSettingsV2

        XCTAssertGreaterThan(windowSettings.width, 0.0, "CT fixture should provide a positive window width")
    }

    func testRescaleParameters() throws {
        let files = try getDICOMFiles(from: "CT")
        let file = try XCTUnwrap(files.first)

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        let rescale = decoder.rescaleParametersV2

        // Verify rescale slope is not zero (would be invalid)
        XCTAssertNotEqual(rescale.slope, 0.0, "Rescale slope should not be zero")

        // Test applyRescale method
        let testValue = 100.0
        let rescaled = decoder.applyRescale(to: testValue)
        let expected = testValue * rescale.slope + rescale.intercept
        XCTAssertEqual(rescaled, expected, accuracy: 0.01, "applyRescale should match formula")
    }

    // MARK: - Windowing and Image Processing Tests

    func testCalculateOptimalWindowFromRealImage() throws {
        let files = try getDICOMFiles(from: "CT")
        let file = try XCTUnwrap(files.first)

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        XCTAssertEqual(decoder.bitDepth, 16)
        let window = try XCTUnwrap(decoder.calculateOptimalWindowV2())
        XCTAssertGreaterThan(window.center, 0.0, "Optimal window center should be positive")
        XCTAssertGreaterThan(window.width, 0.0, "Optimal window width should be positive")
    }

    func testCalculateQualityMetrics() throws {
        let files = try getDICOMFiles(from: "CT")
        let file = try XCTUnwrap(files.first)

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        XCTAssertEqual(decoder.bitDepth, 16)
        let metrics = try XCTUnwrap(decoder.getQualityMetrics())
        let mean = try XCTUnwrap(metrics["mean"])
        let standardDeviation = try XCTUnwrap(metrics["std_deviation"])
        XCTAssertNotNil(metrics["contrast"], "Should have contrast")
        XCTAssertNotNil(metrics["snr"], "Should have SNR")
        XCTAssertGreaterThanOrEqual(mean, 0.0, "Mean should be non-negative")
        XCTAssertGreaterThanOrEqual(standardDeviation, 0.0, "Standard deviation should be non-negative")
    }

    func testApplyWindowingPresets() throws {
        let files = try getDICOMFiles(from: "CT")
        let file = try XCTUnwrap(files.first)

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read CT file")

        let pixels = try XCTUnwrap(decoder.getPixels16())
        let lungPreset = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
        let windowed = try XCTUnwrap(DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels,
            center: lungPreset.center,
            width: lungPreset.width
        ))
        XCTAssertEqual(windowed.count, pixels.count, "Windowed pixel count should match input")
        XCTAssertTrue(windowed.allSatisfy { $0 <= 255 }, "Windowed values should be in 0-255 range")
    }

    // MARK: - Multi-file Tests

    func testLoadMultipleFilesFromSameSeries() throws {
        let file = try getAnyDICOMFile()

        // Load same file multiple times (simulating series)
        let decoder1 = try DCMDecoder(contentsOfFile: file.path)
        let decoder2 = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder1.isValid(), "First decoder should load successfully")
        XCTAssertTrue(decoder2.isValid(), "Second decoder should load successfully")

        // Both should have same properties
        XCTAssertEqual(decoder1.width, decoder2.width, "Both decoders should have same width")
        XCTAssertEqual(decoder1.height, decoder2.height, "Both decoders should have same height")
        XCTAssertEqual(decoder1.bitDepth, decoder2.bitDepth, "Both decoders should have same bit depth")

        let seriesUID1 = decoder1.info(for: 0x0020000E)
        let seriesUID2 = decoder2.info(for: 0x0020000E)
        XCTAssertEqual(seriesUID1, seriesUID2, "Both should have same Series Instance UID")
    }

    func testLoadAllFilesInDirectory() throws {
        let file = try getAnyDICOMFile()
        let directory = file.deletingLastPathComponent()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "dcm" }

        let selectedFiles = Array(files.prefix(5))
        XCTAssertFalse(selectedFiles.isEmpty)
        for file in selectedFiles {
            let decoder = try DCMDecoder(contentsOfFile: file.path)
            XCTAssertTrue(decoder.isValid(), "Declared fixture should load: \(file.lastPathComponent)")
        }
    }

    // MARK: - Performance Tests

    func testLoadingPerformance() throws {
        let file = try getAnyDICOMFile()

        measure {
            do {
                _ = try DCMDecoder(contentsOfFile: file.path)
            } catch {
                XCTFail("Fixture loading failed during measurement: \(error)")
            }
        }
    }

    func testMetadataExtractionPerformance() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        measure {
            _ = decoder.info(for: 0x00100010) // Patient Name
            _ = decoder.info(for: 0x00080060) // Modality
            _ = decoder.intValue(for: 0x00280010) // Rows
            _ = decoder.intValue(for: 0x00280011) // Columns
            _ = decoder.getPatientInfo()
            _ = decoder.getStudyInfo()
            _ = decoder.getSeriesInfo()
        }
    }

    func testPixelDataAccessPerformance() throws {
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully read file")

        measure {
            switch decoder.bitDepth {
            case 8:
                XCTAssertNotNil(decoder.getPixels8())
            case 16:
                XCTAssertNotNil(decoder.getPixels16())
            case 24:
                XCTAssertNotNil(decoder.getPixels24())
            default:
                XCTFail("Fixture uses unsupported bit depth \(decoder.bitDepth)")
            }
        }
    }

    // MARK: - Edge Cases

    func testLoadVeryLargeImage() throws {
        try DicomTestRuntimePreflight.require(.largeDicomFixtures)

        // Try to find a large image (>1MB)
        let fixturesPath = getFixturesPath()

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
                capability: .bundledSyntheticFixtures,
                kind: .regression,
                message: "Fixtures directory not found at \(fixturesPath.path)."
            ))
        }

        let enumerator = FileManager.default.enumerator(at: fixturesPath, includingPropertiesForKeys: [.fileSizeKey])
        var largeFile: URL?

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension.lowercased() == "dcm" {
                if let resources = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resources.fileSize,
                   fileSize > 1_000_000 { // > 1MB
                    largeFile = fileURL
                    break
                }
            }
        }

        guard let file = largeFile else {
            throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
                capability: .largeDicomFixtures,
                kind: .regression,
                message: "Large DICOM fixture preflight passed but no fixture larger than 1 MB was found."
            ))
        }

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should successfully load large DICOM file")
        XCTAssertTrue(decoder.isValid(), "Large file should be valid")
    }

    func testHandleMinimalMetadata() throws {
        // Test with any available file - should handle gracefully even if minimal metadata
        let file = try getAnyDICOMFile()

        let decoder = try DCMDecoder(contentsOfFile: file.path)

        XCTAssertTrue(decoder.dicomFound, "Should load file even with minimal metadata")

        let absentPrivateTag = 0x0009_1001
        XCTAssertEqual(decoder.info(for: absentPrivateTag), "")
        XCTAssertNil(decoder.doubleValue(for: absentPrivateTag))
        XCTAssertNil(decoder.intValue(for: absentPrivateTag))
    }

    // MARK: - Concurrent Access Tests

    func testConcurrentFileLoading() async throws {
        let file = try getAnyDICOMFile()

        // Load same file concurrently with multiple decoders
        async let result1 = Task {
            try await DCMDecoder(contentsOfFile: file.path)
        }.value

        async let result2 = Task {
            try await DCMDecoder(contentsOfFile: file.path)
        }.value

        async let result3 = Task {
            try await DCMDecoder(contentsOfFile: file.path)
        }.value

        let results = try await [result1, result2, result3]

        // All should succeed
        for decoder in results {
            XCTAssertTrue(decoder.isValid(), "Concurrently loaded decoder should be valid")
        }

        // All should have same dimensions
        let widths = results.map { $0.width }
        let heights = results.map { $0.height }
        XCTAssertTrue(widths.allSatisfy { $0 == widths[0] }, "All decoders should have same width")
        XCTAssertTrue(heights.allSatisfy { $0 == heights[0] }, "All decoders should have same height")
    }

    // MARK: - New API Integration Tests

    func testCompleteWorkflowWithNewThrowingAPI() throws {
        let file = try getAnyDICOMFile()

        // Complete workflow: load → extract metadata → get pixels
        do {
            // Load file using new throwing initializer
            let decoder = try DCMDecoder(contentsOf: file)

            // Verify decoder is in valid state
            XCTAssertTrue(decoder.isValid(), "Decoder should be valid after initialization")
            XCTAssertGreaterThan(decoder.width, 0, "Should have valid width")
            XCTAssertGreaterThan(decoder.height, 0, "Should have valid height")

            // Extract metadata
            _ = decoder.info(for: 0x00100010)  // Patient Name
            _ = decoder.info(for: 0x00080060)  // Modality
            let rows = decoder.intValue(for: 0x00280010)
            let columns = decoder.intValue(for: 0x00280011)

            // Verify metadata extraction works
            XCTAssertNotNil(rows, "Should extract Rows tag")
            XCTAssertNotNil(columns, "Should extract Columns tag")
            if let r = rows, let c = columns {
                XCTAssertEqual(r, decoder.height, "Rows should match height")
                XCTAssertEqual(c, decoder.width, "Columns should match width")
            }

            // Extract pixel data based on bit depth
            let validationStatus = decoder.getValidationStatus()
            if validationStatus.hasPixels {
                if decoder.bitDepth == 8 {
                    let pixels = decoder.getPixels8()
                    XCTAssertNotNil(pixels, "Should extract 8-bit pixels")
                    if let pixels = pixels {
                        let expectedSize = decoder.width * decoder.height * decoder.samplesPerPixel
                        XCTAssertEqual(pixels.count, expectedSize, "Pixel count should match dimensions")
                    }
                } else if decoder.bitDepth == 16 {
                    let pixels = decoder.getPixels16()
                    XCTAssertNotNil(pixels, "Should extract 16-bit pixels")
                    if let pixels = pixels {
                        let expectedSize = decoder.width * decoder.height * decoder.samplesPerPixel
                        XCTAssertEqual(pixels.count, expectedSize, "Pixel count should match dimensions")
                    }
                } else if decoder.bitDepth == 24 {
                    let pixels = decoder.getPixels24()
                    XCTAssertNotNil(pixels, "Should extract 24-bit pixels")
                    if let pixels = pixels {
                        let expectedSize = decoder.width * decoder.height
                        XCTAssertEqual(pixels.count, expectedSize, "Pixel count should match dimensions")
                    }
                }
            }

        } catch {
            XCTFail("New throwing API should succeed with valid file: \(error)")
        }
    }

    func testCompleteWorkflowWithStaticFactoryMethod() throws {
        let file = try getAnyDICOMFile()

        // Complete workflow using static factory method
        do {
            let decoder = try DCMDecoder.load(from: file)

            // Verify decoder is valid
            XCTAssertTrue(decoder.isValid(), "Decoder from static factory should be valid")
            XCTAssertGreaterThan(decoder.width, 0, "Should have valid width")
            XCTAssertGreaterThan(decoder.height, 0, "Should have valid height")

            // Extract and verify metadata
            let allTags = decoder.getAllTags()
            XCTAssertFalse(allTags.isEmpty, "Should have metadata tags")

        } catch {
            XCTFail("Static factory method should succeed with valid file: \(error)")
        }
    }

    func testCompleteWorkflowWithAsyncThrowingAPI() async throws {
        let file = try getAnyDICOMFile()

        // Complete async workflow
        do {
            // Load file asynchronously using new throwing initializer
            let decoder = try await DCMDecoder(contentsOf: file)

            // Verify decoder is valid
            XCTAssertTrue(decoder.isValid(), "Async decoder should be valid")
            XCTAssertGreaterThan(decoder.width, 0, "Should have valid width")
            XCTAssertGreaterThan(decoder.height, 0, "Should have valid height")

            // Extract metadata
            let modality = decoder.info(for: 0x00080060)
            XCTAssertFalse(modality.isEmpty, "Should extract modality")

        } catch {
            XCTFail("Async throwing API should succeed with valid file: \(error)")
        }
    }

    func testErrorRecoveryPatternsWithNewAPI() throws {
        let fixturesPath = getFixturesPath()

        // Test error recovery with non-existent file
        var caughtFileNotFound = false
        do {
            let nonExistentPath = fixturesPath.appendingPathComponent("nonexistent.dcm")
            _ = try DCMDecoder(contentsOf: nonExistentPath)
            XCTFail("Should throw error for non-existent file")
        } catch let error as DICOMError {
            // Proper error recovery - can handle specific error type
            switch error {
            case .fileNotFound:
                caughtFileNotFound = true
            default:
                XCTFail("Should throw fileNotFound error, got: \(error)")
            }
        } catch {
            XCTFail("Should throw DICOMError type, got: \(error)")
        }
        XCTAssertTrue(caughtFileNotFound, "Should have caught fileNotFound error")

        // Test error recovery with invalid file
        var caughtInvalidFormat = false
        do {
            // Create temporary invalid file
            let tempDir = FileManager.default.temporaryDirectory
            let invalidFile = tempDir.appendingPathComponent("invalid-\(UUID().uuidString).dcm")
            try "Not a DICOM file".write(to: invalidFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: invalidFile) }

            _ = try DCMDecoder(contentsOf: invalidFile)
            XCTFail("Should throw error for invalid DICOM file")
        } catch let error as DICOMError {
            // Proper error recovery - can handle specific error type
            switch error {
            case .invalidDICOMFormat:
                caughtInvalidFormat = true
            default:
                XCTFail("Should throw invalidDICOMFormat error, got: \(error)")
            }
        } catch {
            XCTFail("Should throw DICOMError type, got: \(error)")
        }
        XCTAssertTrue(caughtInvalidFormat, "Should have caught invalidDICOMFormat error")

    }

    func testMigrationFromOldAPIToNewAPI() throws {
        let file = try getAnyDICOMFile()

        // OLD API pattern (imperative) - no longer available
        // Testing only the new API now
        let oldDecoder = try DCMDecoder(contentsOfFile: file.path)

        // NEW API pattern (declarative)
        let newDecoder: DCMDecoder
        do {
            newDecoder = try DCMDecoder(contentsOf: file)
        } catch {
            XCTFail("New API should succeed: \(error)")
            return
        }

        // Both should produce identical results
        XCTAssertEqual(oldDecoder.width, newDecoder.width, "Width should match between old and new API")
        XCTAssertEqual(oldDecoder.height, newDecoder.height, "Height should match between old and new API")
        XCTAssertEqual(oldDecoder.bitDepth, newDecoder.bitDepth, "Bit depth should match")
        XCTAssertEqual(oldDecoder.samplesPerPixel, newDecoder.samplesPerPixel, "Samples per pixel should match")

        // Compare metadata extraction
        let oldModality = oldDecoder.info(for: 0x00080060)
        let newModality = newDecoder.info(for: 0x00080060)
        XCTAssertEqual(oldModality, newModality, "Modality should match between APIs")

        let oldPatientName = oldDecoder.info(for: 0x00100010)
        let newPatientName = newDecoder.info(for: 0x00100010)
        XCTAssertEqual(oldPatientName, newPatientName, "Patient name should match between APIs")

    }

    func testNewAPIWithPathStringVariant() throws {
        let file = try getAnyDICOMFile()

        // Test String path variant
        do {
            let decoder = try DCMDecoder(contentsOfFile: file.path)

            XCTAssertTrue(decoder.isValid(), "String path variant should work")
            XCTAssertGreaterThan(decoder.width, 0, "Should have valid width")
            XCTAssertGreaterThan(decoder.height, 0, "Should have valid height")

        } catch {
            XCTFail("String path variant should succeed: \(error)")
        }

        // Test static factory with String path
        do {
            let decoder = try DCMDecoder.load(fromFile: file.path)

            XCTAssertTrue(decoder.isValid(), "Static factory with String path should work")
            XCTAssertGreaterThan(decoder.width, 0, "Should have valid width")

        } catch {
            XCTFail("Static factory with String path should succeed: \(error)")
        }
    }

    func testNewAPIWithMultipleFilesAsync() async throws {
        // Test loading multiple files concurrently with new async API
        let file = try getAnyDICOMFile()

        // Load multiple decoders concurrently using new async API
        async let decoder1 = try DCMDecoder(contentsOf: file)
        async let decoder2 = try DCMDecoder(contentsOfFile: file.path)
        async let decoder3 = try DCMDecoder.load(from: file)
        async let decoder4 = try DCMDecoder.load(fromFile: file.path)

        let decoders = try await [decoder1, decoder2, decoder3, decoder4]

        // All should be valid
        for decoder in decoders {
            XCTAssertTrue(decoder.isValid(), "All async decoders should be valid")
            XCTAssertGreaterThan(decoder.width, 0, "All should have valid width")
            XCTAssertGreaterThan(decoder.height, 0, "All should have valid height")
        }

        // All should have identical dimensions (same file)
        let widths = decoders.map { $0.width }
        let heights = decoders.map { $0.height }
        XCTAssertTrue(widths.allSatisfy { $0 == widths[0] }, "All widths should match")
        XCTAssertTrue(heights.allSatisfy { $0 == heights[0] }, "All heights should match")
    }

    func testNewAPIWithDecoderFactory() throws {
        let file = try getAnyDICOMFile()

        // Test using decoder factory pattern (common in services)
        let decoderFactory: () throws -> DCMDecoder = {
            try DCMDecoder(contentsOf: file)
        }

        // Create multiple decoders from factory
        do {
            let decoder1 = try decoderFactory()
            let decoder2 = try decoderFactory()

            XCTAssertTrue(decoder1.isValid(), "First decoder from factory should be valid")
            XCTAssertTrue(decoder2.isValid(), "Second decoder from factory should be valid")

            // Each decoder should be independent
            XCTAssertEqual(decoder1.width, decoder2.width, "Both should read same file")

        } catch {
            XCTFail("Decoder factory should succeed: \(error)")
        }
    }

    func testNewAPIProtocolConformance() throws {
        let file = try getAnyDICOMFile()

        // Test that new API works through protocol abstraction
        func loadDicomFile(from url: URL, using factory: () -> DicomDecoderProtocol) throws -> DicomDecoderProtocol {
            let decoder = factory()
            // Use new throwing API through protocol
            return try type(of: decoder).init(contentsOf: url)
        }

        do {
            let decoder = try loadDicomFile(from: file) { DCMDecoder() }

            XCTAssertTrue(decoder.isValid(), "Protocol-based initialization should work")
            XCTAssertGreaterThan(decoder.width, 0, "Should have valid width")

        } catch {
            XCTFail("Protocol-based new API should succeed: \(error)")
        }
    }
}
