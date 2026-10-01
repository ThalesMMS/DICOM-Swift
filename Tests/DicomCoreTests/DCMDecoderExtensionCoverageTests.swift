import XCTest
@testable import DicomCore

/// Tests for gaps in coverage of the new extension files introduced in this PR:
/// - DCMDecoder+V2API.swift: getQualityMetrics, applyRescale edge cases
/// - DCMDecoder+Metadata.swift: getAllTags hex format, key structure
/// - DCMDecoder+Validation.swift: getValidationStatus hasPixels logic, validateDICOMFile with temp files
/// - DCMDecoder+DicomTagAPI.swift: equivalence with raw value overloads on uninitialized decoder
// Compatibility coverage: this suite intentionally exercises deprecated
// public APIs that remain available (issue #1221); the annotation keeps
// the deliberate legacy usage warning-free without hiding new ones.
@available(*, deprecated)
final class DCMDecoderExtensionCoverageTests: XCTestCase {

    // MARK: - DCMDecoder+V2API: getQualityMetrics

    func testGetQualityMetricsReturnsNilForUninitializedDecoder() {
        let decoder = DCMDecoder()
        XCTAssertNil(decoder.getQualityMetrics(), "getQualityMetrics should return nil with no pixel data")
    }

    func testGetQualityMetricsReturnsNilAfterFailedLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid_\(UUID().uuidString).dcm")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = DCMDecoder()
        decoder.setDicomFilename(url.path)

        XCTAssertFalse(decoder.isValid(), "Decoder should represent a failed parse")
        XCTAssertNil(decoder.getQualityMetrics(), "getQualityMetrics should return nil after failed load")
    }

    func testGetQualityMetricsConsistency() {
        let decoder = DCMDecoder()
        let result1 = decoder.getQualityMetrics()
        let result2 = decoder.getQualityMetrics()
        // Both nil for uninitialized decoder
        XCTAssertEqual(result1 == nil, result2 == nil,
                       "Multiple getQualityMetrics calls should be consistent")
    }

    // MARK: - DCMDecoder+V2API: applyRescale

    func testApplyRescaleDefaultParameters() {
        let decoder = DCMDecoder()
        // Default: intercept=0, slope=1, so applyRescale(x) = 1*x + 0 = x
        let inputValue = 1000.0
        let result = decoder.applyRescale(to: inputValue)
        XCTAssertEqual(result, inputValue, accuracy: 0.001,
                       "Default rescale (slope=1, intercept=0) should return input value unchanged")
    }

    func testApplyRescaleWithZeroInput() {
        let decoder = DCMDecoder()
        // slope=1, intercept=0: rescale(0) = 0
        XCTAssertEqual(decoder.applyRescale(to: 0.0), 0.0, accuracy: 0.001,
                       "Rescale of 0 with default params should be 0")
    }

    func testApplyRescaleWithNegativeInput() {
        let decoder = DCMDecoder()
        // Default slope=1, intercept=0: rescale(-1000) = -1000
        XCTAssertEqual(decoder.applyRescale(to: -1000.0), -1000.0, accuracy: 0.001,
                       "Rescale of negative value with default params should preserve sign")
    }

    func testApplyRescaleMatchesRescaleParametersV2() {
        let decoder = DCMDecoder()
        let params = decoder.rescaleParametersV2

        let testValues: [Double] = [0, 100, -500, 1000.5, Double.greatestFiniteMagnitude / 2]
        for value in testValues {
            let v2Result = params.apply(to: value)
            let decoderResult = decoder.applyRescale(to: value)
            XCTAssertEqual(v2Result, decoderResult, accuracy: 0.0001,
                           "applyRescale() should match RescaleParameters.apply() for value \(value)")
        }
    }

    func testApplyRescaleConcurrentAccess() {
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent applyRescale")
        expectation.expectedFulfillmentCount = 20

        for i in 0..<20 {
            DispatchQueue.global().async {
                let result = decoder.applyRescale(to: Double(i) * 100.0)
                // With default params (slope=1, intercept=0), result == input
                XCTAssertEqual(result, Double(i) * 100.0, accuracy: 0.001)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - DCMDecoder+V2API: calculateOptimalWindowV2

    func testCalculateOptimalWindowV2ReturnsNilWithNoPixelData() {
        let decoder = DCMDecoder()
        let result = decoder.calculateOptimalWindowV2()
        XCTAssertNil(result, "calculateOptimalWindowV2 should return nil with no pixel data")
    }

    func testCalculateOptimalWindowLegacyReturnsNilWithNoPixelData() {
        let decoder = DCMDecoder()
        // Test the deprecated calculateOptimalWindow() too
        let result = decoder.calculateOptimalWindow()
        XCTAssertNil(result, "calculateOptimalWindow() should return nil with no pixel data")
    }

    // MARK: - DCMDecoder+Metadata: getAllTags key format

    func testGetAllTagsReturnsEmptyDictionaryForUninitializedDecoder() {
        let decoder = DCMDecoder()
        let tags = decoder.getAllTags()
        XCTAssertTrue(tags.isEmpty, "getAllTags should return empty dictionary for uninitialized decoder")
    }

    func testGetAllTagsKeyFormatIsUppercaseHex() throws {
        let url = try makeTemporaryDICOMWithPatientName("Format^Patient")
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let tags = decoder.getAllTags()
        let patientNameKey = String(format: "%08X", DicomTag.patientName.rawValue)

        XCTAssertEqual(tags[patientNameKey], "Format^Patient")
        XCTAssertEqual(patientNameKey.count, 8, "Key should be exactly 8 characters")
        XCTAssertEqual(patientNameKey, patientNameKey.uppercased(), "Key should be uppercase")
    }

    func testGetAllTagsReturnsStringValues() {
        let decoder = DCMDecoder()
        let tags = decoder.getAllTags()
        // For each key-value pair (none expected for uninitialized), verify types
        for (key, value) in tags {
            XCTAssertEqual(key.count, 8, "Tag key should be 8 characters long")
            XCTAssertNotNil(value, "Tag value should not be nil")
        }
    }

    func testGetAllTagsConsistency() {
        let decoder = DCMDecoder()
        let tags1 = decoder.getAllTags()
        let tags2 = decoder.getAllTags()
        XCTAssertEqual(tags1.count, tags2.count,
                       "Multiple getAllTags calls should return consistent results")
    }

    // MARK: - DCMDecoder+Metadata: getPatientInfo, getStudyInfo, getSeriesInfo

    func testGetPatientInfoHasExactKeys() {
        let decoder = DCMDecoder()
        let info = decoder.getPatientInfo()
        XCTAssertNotNil(info["Name"], "getPatientInfo should have 'Name' key")
        XCTAssertNotNil(info["ID"], "getPatientInfo should have 'ID' key")
        XCTAssertNotNil(info["Sex"], "getPatientInfo should have 'Sex' key")
        XCTAssertNotNil(info["Age"], "getPatientInfo should have 'Age' key")
        // Exactly 4 keys
        XCTAssertEqual(info.count, 4, "getPatientInfo should have exactly 4 keys")
    }

    func testGetStudyInfoHasExactKeys() {
        let decoder = DCMDecoder()
        let info = decoder.getStudyInfo()
        XCTAssertNotNil(info["StudyInstanceUID"], "getStudyInfo should have 'StudyInstanceUID' key")
        XCTAssertNotNil(info["StudyID"], "getStudyInfo should have 'StudyID' key")
        XCTAssertNotNil(info["StudyDate"], "getStudyInfo should have 'StudyDate' key")
        XCTAssertNotNil(info["StudyTime"], "getStudyInfo should have 'StudyTime' key")
        XCTAssertNotNil(info["StudyDescription"], "getStudyInfo should have 'StudyDescription' key")
        XCTAssertNotNil(info["ReferringPhysician"], "getStudyInfo should have 'ReferringPhysician' key")
        XCTAssertEqual(info.count, 6, "getStudyInfo should have exactly 6 keys")
    }

    func testGetSeriesInfoHasExactKeys() {
        let decoder = DCMDecoder()
        let info = decoder.getSeriesInfo()
        XCTAssertNotNil(info["SeriesInstanceUID"], "getSeriesInfo should have 'SeriesInstanceUID' key")
        XCTAssertNotNil(info["SeriesNumber"], "getSeriesInfo should have 'SeriesNumber' key")
        XCTAssertNotNil(info["SeriesDate"], "getSeriesInfo should have 'SeriesDate' key")
        XCTAssertNotNil(info["SeriesTime"], "getSeriesInfo should have 'SeriesTime' key")
        XCTAssertNotNil(info["SeriesDescription"], "getSeriesInfo should have 'SeriesDescription' key")
        XCTAssertNotNil(info["Modality"], "getSeriesInfo should have 'Modality' key")
        XCTAssertEqual(info.count, 6, "getSeriesInfo should have exactly 6 keys")
    }

    func testGetPatientInfoEmptyValuesForUninitializedDecoder() {
        let decoder = DCMDecoder()
        let info = decoder.getPatientInfo()
        for (_, value) in info {
            XCTAssertEqual(value, "", "All patient info values should be empty for uninitialized decoder")
        }
    }

    func testGetStudyInfoEmptyValuesForUninitializedDecoder() {
        let decoder = DCMDecoder()
        let info = decoder.getStudyInfo()
        for (_, value) in info {
            XCTAssertEqual(value, "", "All study info values should be empty for uninitialized decoder")
        }
    }

    func testGetSeriesInfoEmptyValuesForUninitializedDecoder() {
        let decoder = DCMDecoder()
        let info = decoder.getSeriesInfo()
        for (_, value) in info {
            XCTAssertEqual(value, "", "All series info values should be empty for uninitialized decoder")
        }
    }

    func testMetadataHelpersConcurrentAccess() {
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent metadata helpers access")
        expectation.expectedFulfillmentCount = 12

        for _ in 0..<4 {
            DispatchQueue.global().async {
                _ = decoder.getAllTags()
                expectation.fulfill()
            }
            DispatchQueue.global().async {
                _ = decoder.getPatientInfo()
                expectation.fulfill()
            }
            DispatchQueue.global().async {
                _ = decoder.getStudyInfo()
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - DCMDecoder+Validation: getValidationStatus hasPixels

    func testGetValidationStatusHasPixelsForUninitializedDecoder() {
        let decoder = DCMDecoder()
        let status = decoder.getValidationStatus()
        // Neither decoded pixels (pixels8/16/24) nor valid file offset (offset > 0)
        XCTAssertFalse(status.hasPixels, "Uninitialized decoder should not have pixels")
    }

    func testGetValidationStatusIsCompressedDefault() {
        let decoder = DCMDecoder()
        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.isCompressed, "Default decoder should not be compressed")
    }

    func testGetValidationStatusWidthAndHeightDefault() {
        let decoder = DCMDecoder()
        let status = decoder.getValidationStatus()
        XCTAssertEqual(status.width, 1, "Default status width should be 1")
        XCTAssertEqual(status.height, 1, "Default status height should be 1")
    }

    func testGetValidationStatusIsValidDefault() {
        let decoder = DCMDecoder()
        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.isValid, "Default decoder should not be valid")
    }

    func testGetValidationStatusTupleFields() {
        let decoder = DCMDecoder()
        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.isValid)
        XCTAssertEqual(status.width, 1)
        XCTAssertEqual(status.height, 1)
        XCTAssertFalse(status.hasPixels)
        XCTAssertFalse(status.isCompressed)
    }

    func testGetValidationStatusConsistency() {
        let decoder = DCMDecoder()
        let status1 = decoder.getValidationStatus()
        let status2 = decoder.getValidationStatus()
        XCTAssertEqual(status1.isValid, status2.isValid, "Status should be consistent")
        XCTAssertEqual(status1.hasPixels, status2.hasPixels, "hasPixels should be consistent")
        XCTAssertEqual(status1.isCompressed, status2.isCompressed, "isCompressed should be consistent")
        XCTAssertEqual(status1.width, status2.width, "width should be consistent")
        XCTAssertEqual(status1.height, status2.height, "height should be consistent")
    }

    func testIsValidMatchesGetValidationStatus() {
        let decoder = DCMDecoder()
        let isValid = decoder.isValid()
        let status = decoder.getValidationStatus()
        // isValid() checks dicomFileReadSuccess && dicomFound && width > 0 && height > 0
        // getValidationStatus() returns dicomFileReadSuccess
        // They may differ: isValid() is stricter
        // For uninitialized decoder, both should indicate invalid state
        XCTAssertFalse(isValid, "isValid() should return false for uninitialized decoder")
        XCTAssertFalse(status.isValid, "getValidationStatus().isValid should be false for uninitialized decoder")
    }

    // MARK: - DCMDecoder+Validation: validateDICOMFile with real files

    func testValidateDICOMFileWithEmptyFile() throws {
        // Create a real temp file that is empty
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dcm")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Create empty file
        FileManager.default.createFile(atPath: tempURL.path, contents: Data(), attributes: nil)

        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile(tempURL.path)

        // Empty file: size == 0, should have issues
        XCTAssertFalse(result.isValid, "Empty file should not be valid")
        XCTAssertTrue(result.issues.contains(where: { $0.contains("empty") || $0.contains("Empty") }),
                      "Should report file is empty")
    }

    func testValidateDICOMFileWithSmallFile() throws {
        // Create a real temp file smaller than 132 bytes (DICOM preamble size)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dcm")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 50 bytes - valid file size but below preamble size
        let smallData = Data(repeating: 0, count: 50)
        FileManager.default.createFile(atPath: tempURL.path, contents: smallData, attributes: nil)

        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile(tempURL.path)

        // File exists and size > 0, so isValid may be true (issues are warnings)
        XCTAssertTrue(result.isValid, "Small file should pass (warnings are not errors)")
        // Should have a warning about missing preamble
        XCTAssertTrue(result.issues.contains(where: { $0.contains("132") || $0.contains("preamble") }),
                      "Should warn about small file size")
    }

    func testValidateDICOMFileWithDICMHeader() throws {
        // Create a file with valid DICOM DICM header at offset 128
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dcm")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var data = Data(count: 200)
        // Write DICM at offset 128
        data[128] = 0x44  // D
        data[129] = 0x49  // I
        data[130] = 0x43  // C
        data[131] = 0x4D  // M
        FileManager.default.createFile(atPath: tempURL.path, contents: data, attributes: nil)

        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile(tempURL.path)

        XCTAssertTrue(result.isValid, "File with valid DICM header should pass validation")
        // Should not have preamble-related warnings
        let hasPreambleWarning = result.issues.contains(where: { $0.contains("DICM signature") })
        XCTAssertFalse(hasPreambleWarning, "File with valid DICM header should not warn about signature")
    }

    func testValidateDICOMFileWithInvalidHeader() throws {
        // Create a file >= 132 bytes but without valid DICM at offset 128
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dcm")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let data = Data(count: 200)  // All zeros, no DICM signature
        FileManager.default.createFile(atPath: tempURL.path, contents: data, attributes: nil)

        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile(tempURL.path)

        // isValid is true (no hard errors), but should warn about missing DICM
        XCTAssertTrue(result.isValid, "File without DICM header should still pass (preamble is optional)")
        let hasDICMWarning = result.issues.contains(where: { $0.contains("DICM") || $0.contains("signature") })
        XCTAssertTrue(hasDICMWarning, "Should warn about missing DICM signature")
    }

    func testValidateDICOMFileReturnsIssuesArray() {
        let decoder = DCMDecoder()
        let result = decoder.validateDICOMFile("/nonexistent/file.dcm")
        XCTAssertFalse(result.issues.isEmpty, "Nonexistent file should have at least one issue")
        XCTAssertTrue(result.issues.allSatisfy { !$0.isEmpty },
                      "All issue messages should be non-empty strings")
    }

    // MARK: - DCMDecoder+DicomTagAPI: DicomTag enum overload equivalence

    func test_pixelValueRangeTags_haveStandardDicomValues() {
        XCTAssertEqual(DicomTag.smallestImagePixelValue.rawValue, 0x0028_0106)
        XCTAssertEqual(DicomTag.largestImagePixelValue.rawValue, 0x0028_0107)
    }

    func testDicomTagEnumOverloadEquivalenceForAllMethods() {
        let decoder = DCMDecoder()

        // Verify info(for:DicomTag) == info(for:Int)
        let commonTags: [(DicomTag, Int)] = [
            (.patientName, DicomTag.patientName.rawValue),
            (.modality, DicomTag.modality.rawValue),
            (.studyDate, DicomTag.studyDate.rawValue),
            (.rows, DicomTag.rows.rawValue),
            (.columns, DicomTag.columns.rawValue)
        ]

        for (enumTag, rawValue) in commonTags {
            XCTAssertEqual(decoder.info(for: enumTag), decoder.info(for: rawValue),
                           "info(for: .\(enumTag)) should equal info(for: \(rawValue))")
            XCTAssertEqual(decoder.intValue(for: enumTag), decoder.intValue(for: rawValue),
                           "intValue(for: .\(enumTag)) should equal intValue(for: \(rawValue))")
            XCTAssertEqual(decoder.doubleValue(for: enumTag), decoder.doubleValue(for: rawValue),
                           "doubleValue(for: .\(enumTag)) should equal doubleValue(for: \(rawValue))")
        }
    }

    func testDicomTagEnumOverloadWithWindowingTags() {
        let decoder = DCMDecoder()

        XCTAssertEqual(
            decoder.doubleValue(for: .windowCenter),
            decoder.doubleValue(for: DicomTag.windowCenter.rawValue),
            "windowCenter via enum and raw value should match"
        )
        XCTAssertEqual(
            decoder.doubleValue(for: .windowWidth),
            decoder.doubleValue(for: DicomTag.windowWidth.rawValue),
            "windowWidth via enum and raw value should match"
        )
        XCTAssertEqual(
            decoder.doubleValue(for: .rescaleSlope),
            decoder.doubleValue(for: DicomTag.rescaleSlope.rawValue),
            "rescaleSlope via enum and raw value should match"
        )
        XCTAssertEqual(
            decoder.doubleValue(for: .rescaleIntercept),
            decoder.doubleValue(for: DicomTag.rescaleIntercept.rawValue),
            "rescaleIntercept via enum and raw value should match"
        )
    }

    func testDicomTagEnumOverloadAllReturnEmptyStringsForUninitializedDecoder() {
        let decoder = DCMDecoder()

        let tagsToCheck: [DicomTag] = [
            .patientName, .patientID, .patientSex, .patientAge,
            .studyInstanceUID, .studyDate, .studyDescription,
            .seriesInstanceUID, .seriesNumber, .modality,
            .photometricInterpretation, .sopInstanceUID
        ]

        for tag in tagsToCheck {
            XCTAssertEqual(decoder.info(for: tag), "",
                           "info(for: .\(tag)) should return empty string for uninitialized decoder")
        }
    }

    func testDicomTagEnumOverloadAllReturnNilIntValuesForUninitializedDecoder() {
        let decoder = DCMDecoder()

        let intTags: [DicomTag] = [
            .rows, .columns, .bitsAllocated, .bitsStored, .samplesPerPixel, .pixelRepresentation
        ]

        for tag in intTags {
            XCTAssertNil(decoder.intValue(for: tag),
                         "intValue(for: .\(tag)) should return nil for uninitialized decoder")
        }
    }

    func testDicomTagEnumOverloadAllReturnNilDoubleValuesForUninitializedDecoder() {
        let decoder = DCMDecoder()

        let doubleTags: [DicomTag] = [
            .pixelSpacing, .sliceThickness, .windowCenter, .windowWidth,
            .rescaleSlope, .rescaleIntercept
        ]

        for tag in doubleTags {
            XCTAssertNil(decoder.doubleValue(for: tag),
                         "doubleValue(for: .\(tag)) should return nil for uninitialized decoder")
        }
    }

    // MARK: - DCMDecoder+V2API: pixelSpacingV2, windowSettingsV2, rescaleParametersV2

    func testPixelSpacingV2MatchesIndividualProperties() {
        let decoder = DCMDecoder()
        let spacing = decoder.pixelSpacingV2
        XCTAssertEqual(spacing.x, decoder.pixelWidth, "pixelSpacingV2.x should match pixelWidth")
        XCTAssertEqual(spacing.y, decoder.pixelHeight, "pixelSpacingV2.y should match pixelHeight")
        XCTAssertEqual(spacing.z, decoder.pixelDepth, "pixelSpacingV2.z should match pixelDepth")
    }

    func testWindowSettingsV2MatchesIndividualProperties() {
        let decoder = DCMDecoder()
        let settings = decoder.windowSettingsV2
        XCTAssertEqual(settings.center, decoder.windowCenter, "windowSettingsV2.center should match windowCenter")
        XCTAssertEqual(settings.width, decoder.windowWidth, "windowSettingsV2.width should match windowWidth")
    }

    func testRescaleParametersV2DefaultValues() {
        let decoder = DCMDecoder()
        let params = decoder.rescaleParametersV2
        XCTAssertEqual(params.intercept, 0.0, "Default intercept should be 0.0")
        XCTAssertEqual(params.slope, 1.0, "Default slope should be 1.0")
        XCTAssertTrue(params.isIdentity, "Default params should be identity transformation")
    }

    func testRescaleParametersV2IsIdentityImplication() {
        let decoder = DCMDecoder()
        let params = decoder.rescaleParametersV2
        if params.isIdentity {
            // Identity transformation: applying rescale should not change values
            let testValue = 500.0
            XCTAssertEqual(params.apply(to: testValue), testValue, accuracy: 0.001,
                           "Identity rescale should preserve input value")
        }
    }

    func testPixelSpacingV2DefaultValues() {
        let decoder = DCMDecoder()
        let spacing = decoder.pixelSpacingV2
        XCTAssertEqual(spacing.x, 1.0, "Default pixel spacing x should be 1.0")
        XCTAssertEqual(spacing.y, 1.0, "Default pixel spacing y should be 1.0")
        XCTAssertEqual(spacing.z, 1.0, "Default pixel spacing z should be 1.0")
    }

    func testWindowSettingsV2DefaultValues() {
        let decoder = DCMDecoder()
        let settings = decoder.windowSettingsV2
        XCTAssertEqual(settings.center, 0.0, "Default window center should be 0.0")
        XCTAssertEqual(settings.width, 0.0, "Default window width should be 0.0")
    }

    private func makeTemporaryDICOMWithPatientName(_ patientName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata_keys_\(UUID().uuidString).dcm")
        var data = Data()
        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        func appendHeader(group: UInt16, element: UInt16, vr: String, length: Int) {
            data.append(contentsOf: withUnsafeBytes(of: group.littleEndian) { Array($0) })
            data.append(contentsOf: withUnsafeBytes(of: element.littleEndian) { Array($0) })
            data.append(contentsOf: vr.utf8)
            data.append(UInt8(length & 0xFF))
            data.append(UInt8((length >> 8) & 0xFF))
        }

        func appendUS(group: UInt16, element: UInt16, value: UInt16) {
            appendHeader(group: group, element: element, vr: "US", length: 2)
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        }

        func appendString(group: UInt16, element: UInt16, vr: String, value: String) {
            var bytes = Array(value.utf8)
            if bytes.count % 2 != 0 {
                bytes.append(vr == "UI" ? 0x00 : 0x20)
            }
            appendHeader(group: group, element: element, vr: vr, length: bytes.count)
            data.append(contentsOf: bytes)
        }

        appendString(group: 0x0010, element: 0x0010, vr: "PN", value: patientName)
        appendUS(group: 0x0028, element: 0x0010, value: 1)
        appendUS(group: 0x0028, element: 0x0011, value: 1)
        appendUS(group: 0x0028, element: 0x0002, value: 1)
        appendString(group: 0x0028, element: 0x0004, vr: "CS", value: "MONOCHROME2")
        appendUS(group: 0x0028, element: 0x0100, value: 16)
        appendUS(group: 0x0028, element: 0x0101, value: 16)
        appendUS(group: 0x0028, element: 0x0102, value: 15)
        appendUS(group: 0x0028, element: 0x0103, value: 0)

        data.append(contentsOf: [0xE0, 0x7F, 0x10, 0x00])
        data.append(contentsOf: "OW".utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: withUnsafeBytes(of: UInt32(2).littleEndian) { Array($0) })
        data.append(contentsOf: [0x00, 0x00])

        try data.write(to: url)
        return url
    }
}
