import XCTest
@testable import DicomCore

final class DCMDecoderMetadataTests: XCTestCase {

    // MARK: - Tag Access Tests

    func testInfoMethodWithUninitializedDecoder() {
        let decoder = DCMDecoder()

        // Test that info returns empty string for uninitialized decoder
        let patientName = decoder.info(for: DicomTag.patientName.rawValue)
        XCTAssertEqual(patientName, "", "Uninitialized decoder should return empty string")

        let studyDate = decoder.info(for: DicomTag.studyDate.rawValue)
        XCTAssertEqual(studyDate, "", "Uninitialized decoder should return empty string")

        let modality = decoder.info(for: DicomTag.modality.rawValue)
        XCTAssertEqual(modality, "", "Uninitialized decoder should return empty string")
    }

    func testInfoMethodWithInvalidTag() {
        let decoder = DCMDecoder()

        // Test with invalid/non-existent tag
        let result = decoder.info(for: 0xFFFFFFFF)
        XCTAssertEqual(result, "", "Invalid tag should return empty string")

        // Test with zero tag
        let zeroResult = decoder.info(for: 0x00000000)
        XCTAssertEqual(zeroResult, "", "Zero tag should return empty string")
    }

    func testCommonPatientTags() {
        let decoder = DCMDecoder()

        let tags = [
            DicomTag.patientName,
            DicomTag.patientID,
            DicomTag.patientSex,
            DicomTag.patientAge,
            DicomTag.patientPosition
        ]
        XCTAssertTrue(tags.allSatisfy { decoder.info(for: $0.rawValue).isEmpty })
    }

    func testCommonStudyTags() {
        let decoder = DCMDecoder()

        let tags = [
            DicomTag.studyInstanceUID,
            DicomTag.studyDate,
            DicomTag.studyTime,
            DicomTag.studyDescription,
            DicomTag.studyID
        ]
        XCTAssertTrue(tags.allSatisfy { decoder.info(for: $0.rawValue).isEmpty })
    }

    func testCommonSeriesTags() {
        let decoder = DCMDecoder()

        let tags = [
            DicomTag.seriesInstanceUID,
            DicomTag.seriesNumber,
            DicomTag.seriesDescription,
            DicomTag.modality
        ]
        XCTAssertTrue(tags.allSatisfy { decoder.info(for: $0.rawValue).isEmpty })
    }

    func testCommonImageTags() {
        let decoder = DCMDecoder()

        let tags = [
            DicomTag.rows,
            DicomTag.columns,
            DicomTag.bitsAllocated,
            DicomTag.bitsStored,
            DicomTag.highBit,
            DicomTag.pixelRepresentation
        ]
        XCTAssertTrue(tags.allSatisfy { decoder.info(for: $0.rawValue).isEmpty })
    }

    // MARK: - Type Conversion Tests

    func testIntValueConversionWithUninitializedDecoder() {
        let decoder = DCMDecoder()

        // Test that intValue returns nil for uninitialized decoder
        let rows = decoder.intValue(for: DicomTag.rows.rawValue)
        XCTAssertNil(rows, "Uninitialized decoder should return nil for intValue")

        let columns = decoder.intValue(for: DicomTag.columns.rawValue)
        XCTAssertNil(columns, "Uninitialized decoder should return nil for intValue")

        let bitsAllocated = decoder.intValue(for: DicomTag.bitsAllocated.rawValue)
        XCTAssertNil(bitsAllocated, "Uninitialized decoder should return nil for intValue")
    }

    func testIntValueConversionWithInvalidTag() {
        let decoder = DCMDecoder()

        // Test with invalid tag
        let result = decoder.intValue(for: 0xFFFFFFFF)
        XCTAssertNil(result, "Invalid tag should return nil for intValue")
    }

    func testDoubleValueConversionWithUninitializedDecoder() {
        let decoder = DCMDecoder()

        // Test that doubleValue returns nil for uninitialized decoder
        let pixelSpacing = decoder.doubleValue(for: DicomTag.pixelSpacing.rawValue)
        XCTAssertNil(pixelSpacing, "Uninitialized decoder should return nil for doubleValue")

        let sliceThickness = decoder.doubleValue(for: DicomTag.sliceThickness.rawValue)
        XCTAssertNil(sliceThickness, "Uninitialized decoder should return nil for doubleValue")

        let rescaleSlope = decoder.doubleValue(for: DicomTag.rescaleSlope.rawValue)
        XCTAssertNil(rescaleSlope, "Uninitialized decoder should return nil for doubleValue")
    }

    func testDoubleValueConversionWithInvalidTag() {
        let decoder = DCMDecoder()

        // Test with invalid tag
        let result = decoder.doubleValue(for: 0xFFFFFFFF)
        XCTAssertNil(result, "Invalid tag should return nil for doubleValue")
    }

    // MARK: - Rescale Parameter Tests

    func testRescaleParameterAccess() {
        let decoder = DCMDecoder()

        // Test initial rescale parameters
        let rescaleParams = decoder.rescaleParametersV2
        XCTAssertEqual(rescaleParams.intercept, 0.0, "Default rescale intercept should be 0.0")
        XCTAssertEqual(rescaleParams.slope, 1.0, "Default rescale slope should be 1.0")
    }

    func testWindowSettingsAccess() {
        let decoder = DCMDecoder()

        // Test initial window settings
        let windowSettings = decoder.windowSettingsV2
        XCTAssertEqual(windowSettings.center, 0.0, "Default window center should be 0.0")
        XCTAssertEqual(windowSettings.width, 0.0, "Default window width should be 0.0")
    }

    func testPixelSpacingAccess() {
        let decoder = DCMDecoder()

        // Test initial pixel spacing
        let pixelSpacing = decoder.pixelSpacingV2
        XCTAssertEqual(pixelSpacing.x, 1.0, "Default pixel width should be 1.0")
        XCTAssertEqual(pixelSpacing.y, 1.0, "Default pixel height should be 1.0")
        XCTAssertEqual(pixelSpacing.z, 1.0, "Default pixel depth should be 1.0")
    }

    func testImageDimensionsAccess() {
        let decoder = DCMDecoder()

        // Test initial image dimensions
        let dimensions = decoder.imageDimensions
        XCTAssertEqual(dimensions.width, 1, "Default image width should be 1")
        XCTAssertEqual(dimensions.height, 1, "Default image height should be 1")
    }

    // MARK: - Tag Caching Tests

    func testFrequentTagAccessPerformance() {
        let decoder = DCMDecoder()

        // Access frequently cached tags multiple times
        measure {
            for _ in 0..<100 {
                _ = decoder.info(for: DicomTag.rescaleSlope.rawValue)
                _ = decoder.info(for: DicomTag.rescaleIntercept.rawValue)
                _ = decoder.info(for: DicomTag.rows.rawValue)
                _ = decoder.info(for: DicomTag.columns.rawValue)
            }
        }
    }

    func testNonCachedTagAccessPerformance() {
        let decoder = DCMDecoder()

        // Access non-cached tags multiple times
        measure {
            for _ in 0..<100 {
                _ = decoder.info(for: DicomTag.patientName.rawValue)
                _ = decoder.info(for: DicomTag.studyDate.rawValue)
                _ = decoder.info(for: DicomTag.seriesDescription.rawValue)
                _ = decoder.info(for: DicomTag.studyInstanceUID.rawValue)
            }
        }
    }

    // MARK: - Image Type Detection Tests

    func testImageTypeDetectionDefaults() {
        let decoder = DCMDecoder()

        // Test default image type flags
        XCTAssertTrue(decoder.isGrayscale, "Default should be grayscale")
        XCTAssertFalse(decoder.isColorImage, "Default should not be color")
        XCTAssertFalse(decoder.isMultiFrame, "Default should not be multi-frame")
    }

    func testPhotometricInterpretationAccess() {
        let decoder = DCMDecoder()

        // Test initial photometric interpretation
        XCTAssertEqual(decoder.photometricInterpretation, "", "Default photometric interpretation should be empty")
    }


    // MARK: - Transfer Syntax Tests

    func testTransferSyntaxDetection() {
        let decoder = DCMDecoder()

        // Test that compression flag is initially false
        XCTAssertFalse(decoder.compressedImage, "Initial compressed image flag should be false")
    }

    // MARK: - Pixel Representation Tests

    func testPixelRepresentationAccess() {
        let decoder = DCMDecoder()

        // Test pixel representation accessors
        XCTAssertEqual(decoder.pixelRepresentationTagValue, 0, "Default pixel representation should be 0 (unsigned)")
        XCTAssertFalse(decoder.isSignedPixelRepresentation, "Default should not be signed")
        XCTAssertFalse(decoder.signedImage, "Default signed image flag should be false")
    }

    // MARK: - Metadata Access Thread Safety Tests

    func testConcurrentMetadataAccess() {
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent metadata access")
        expectation.expectedFulfillmentCount = 10

        // Test concurrent access to metadata methods
        for _ in 0..<10 {
            DispatchQueue.global().async {
                // Access various metadata methods concurrently
                _ = decoder.info(for: DicomTag.patientName.rawValue)
                _ = decoder.intValue(for: DicomTag.rows.rawValue)
                _ = decoder.doubleValue(for: DicomTag.pixelSpacing.rawValue)
                _ = decoder.rescaleParametersV2
                _ = decoder.windowSettingsV2
                _ = decoder.imageDimensions

                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testConcurrentMixedPropertyAndMethodAccess() {
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent mixed access")
        expectation.expectedFulfillmentCount = 10

        // Test concurrent access mixing properties and methods
        for i in 0..<10 {
            DispatchQueue.global().async {
                if i % 2 == 0 {
                    _ = decoder.width
                    _ = decoder.height
                    _ = decoder.bitDepth
                } else {
                    _ = decoder.info(for: DicomTag.modality.rawValue)
                    _ = decoder.intValue(for: DicomTag.bitsAllocated.rawValue)
                    _ = decoder.doubleValue(for: DicomTag.rescaleSlope.rawValue)
                }

                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Tag Constant Validation Tests

    func testDicomTagConstantsAreValid() {
        // Test that common DICOM tag constants have reasonable values
        XCTAssertGreaterThan(DicomTag.patientName.rawValue, 0, "PatientName tag should be positive")
        XCTAssertGreaterThan(DicomTag.rows.rawValue, 0, "Rows tag should be positive")
        XCTAssertGreaterThan(DicomTag.columns.rawValue, 0, "Columns tag should be positive")

        // Test specific known tag values
        XCTAssertEqual(DicomTag.patientName.rawValue, 0x00100010, "PatientName should be 0x00100010")
        XCTAssertEqual(DicomTag.rows.rawValue, 0x00280010, "Rows should be 0x00280010")
        XCTAssertEqual(DicomTag.columns.rawValue, 0x00280011, "Columns should be 0x00280011")
    }

    func testDicomTagConstantsAreUnique() {
        // Collect all tag values
        let tags = [
            DicomTag.patientName.rawValue,
            DicomTag.patientID.rawValue,
            DicomTag.studyDate.rawValue,
            DicomTag.modality.rawValue,
            DicomTag.rows.rawValue,
            DicomTag.columns.rawValue,
            DicomTag.bitsAllocated.rawValue,
            DicomTag.pixelRepresentation.rawValue
        ]

        // Verify all tags are unique
        let uniqueTags = Set(tags)
        XCTAssertEqual(tags.count, uniqueTags.count, "All DICOM tag constants should be unique")
    }

    // MARK: - Edge Case Tests

    func testNegativeTagValue() {
        let decoder = DCMDecoder()

        // Test with negative tag value (should still work as it's treated as unsigned)
        let result = decoder.info(for: -1)
        XCTAssertEqual(result, "", "Negative tag should return empty string")
    }

    func testVeryLargeTagValue() {
        let decoder = DCMDecoder()

        // Test with very large tag value
        let result = decoder.info(for: Int.max)
        XCTAssertEqual(result, "", "Very large tag should return empty string")
    }

    func testMultipleConsecutiveInfoCalls() {
        let decoder = DCMDecoder()

        // Test that multiple consecutive calls return consistent results
        let result1 = decoder.info(for: DicomTag.patientName.rawValue)
        let result2 = decoder.info(for: DicomTag.patientName.rawValue)
        let result3 = decoder.info(for: DicomTag.patientName.rawValue)

        XCTAssertEqual(result1, result2, "Consecutive calls should return same result")
        XCTAssertEqual(result2, result3, "Consecutive calls should return same result")
    }

    func testMultipleConsecutiveIntValueCalls() {
        let decoder = DCMDecoder()

        // Test that multiple consecutive calls return consistent results
        let result1 = decoder.intValue(for: DicomTag.rows.rawValue)
        let result2 = decoder.intValue(for: DicomTag.rows.rawValue)
        let result3 = decoder.intValue(for: DicomTag.rows.rawValue)

        XCTAssertEqual(result1, result2, "Consecutive calls should return same result")
        XCTAssertEqual(result2, result3, "Consecutive calls should return same result")
    }

    func testMultipleConsecutiveDoubleValueCalls() {
        let decoder = DCMDecoder()

        // Test that multiple consecutive calls return consistent results
        let result1 = decoder.doubleValue(for: DicomTag.rescaleSlope.rawValue)
        let result2 = decoder.doubleValue(for: DicomTag.rescaleSlope.rawValue)
        let result3 = decoder.doubleValue(for: DicomTag.rescaleSlope.rawValue)

        XCTAssertEqual(result1, result2, "Consecutive calls should return same result")
        XCTAssertEqual(result2, result3, "Consecutive calls should return same result")
    }

}
