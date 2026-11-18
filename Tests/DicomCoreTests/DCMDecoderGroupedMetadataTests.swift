//
//  DCMDecoderGroupedMetadataTests.swift
//  DicomCoreTests
//
//  Checks grouped metadata helpers, window settings, rescale parameters, and unloaded-decoder
//  defaults.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DCMDecoderGroupedMetadataTests: XCTestCase {
    // MARK: - Grouped Metadata Helpers Tests

    func testGroupedMetadataHelpers() {
        let decoder = DCMDecoder()

        // Test that grouped helpers match individual properties
        XCTAssertEqual(decoder.imageDimensions.width, decoder.width, "Image dimensions width should match width property")
        XCTAssertEqual(decoder.imageDimensions.height, decoder.height, "Image dimensions height should match height property")

        XCTAssertEqual(decoder.pixelSpacingV2.x, decoder.pixelWidth, "Pixel spacing width should match pixelWidth property")
        XCTAssertEqual(decoder.pixelSpacingV2.y, decoder.pixelHeight, "Pixel spacing height should match pixelHeight property")
        XCTAssertEqual(decoder.pixelSpacingV2.z, decoder.pixelDepth, "Pixel spacing depth should match pixelDepth property")

        XCTAssertEqual(decoder.windowSettingsV2.center, decoder.windowCenter, "Window settings center should match windowCenter property")
        XCTAssertEqual(decoder.windowSettingsV2.width, decoder.windowWidth, "Window settings width should match windowWidth property")

        // Test default rescale parameters (properties are private)
        XCTAssertEqual(decoder.rescaleParametersV2.intercept, 0.0, "Default rescale intercept should be 0.0")
        XCTAssertEqual(decoder.rescaleParametersV2.slope, 1.0, "Default rescale slope should be 1.0")
    }

    func testWindowSettingsPropertiesConsistency() {
        let decoder = DCMDecoder()

        // Test that window settings match convenience accessors
        let settings = decoder.windowSettingsV2
        XCTAssertEqual(settings.center, decoder.windowCenter, "Window settings center should match windowCenter property")
        XCTAssertEqual(settings.width, decoder.windowWidth, "Window settings width should match windowWidth property")
    }

    func testRescaleParametersPropertiesConsistency() {
        let decoder = DCMDecoder()

        // Test that rescale parameters have expected defaults
        let params = decoder.rescaleParametersV2
        XCTAssertEqual(params.intercept, 0.0, "Default rescale intercept should be 0.0")
        XCTAssertEqual(params.slope, 1.0, "Default rescale slope should be 1.0")
    }

    func testAllGroupedHelpersReturnValidDefaults() {
        let decoder = DCMDecoder()

        let dimensions = decoder.imageDimensions
        XCTAssertGreaterThan(dimensions.width, 0, "Image dimensions width should default to a positive value")
        XCTAssertGreaterThan(dimensions.height, 0, "Image dimensions height should default to a positive value")

        let spacing = decoder.pixelSpacingV2
        XCTAssertEqual(spacing.x, 1.0, "Pixel spacing width should default to 1.0")
        XCTAssertEqual(spacing.y, 1.0, "Pixel spacing height should default to 1.0")
        XCTAssertEqual(spacing.z, 1.0, "Pixel spacing depth should default to 1.0")

        let windowSettings = decoder.windowSettingsV2
        XCTAssertTrue(windowSettings.center.isFinite, "Window center should be finite")
        XCTAssertTrue(windowSettings.width.isFinite, "Window width should be finite")
        XCTAssertEqual(windowSettings.center, 0.0, "Window center should default to 0.0")
        XCTAssertEqual(windowSettings.width, 0.0, "Window width should default to 0.0")

        let rescaleParams = decoder.rescaleParametersV2
        XCTAssertTrue(rescaleParams.intercept.isFinite, "Rescale intercept should be finite")
        XCTAssertTrue(rescaleParams.slope.isFinite, "Rescale slope should be finite")
        XCTAssertEqual(rescaleParams.intercept, 0.0, "Rescale intercept should default to 0.0")
        XCTAssertEqual(rescaleParams.slope, 1.0, "Rescale slope should default to 1.0")
    }

    func testGroupedHelpersDefaults() {
        let decoder = DCMDecoder()

        // Test default values for grouped helpers
        let dimensions = decoder.imageDimensions
        XCTAssertGreaterThan(dimensions.width, 0, "Default image width should be positive")
        XCTAssertGreaterThan(dimensions.height, 0, "Default image height should be positive")

        let spacing = decoder.pixelSpacingV2
        XCTAssertEqual(spacing.x, 1.0, "Default pixel width should be 1.0")
        XCTAssertEqual(spacing.y, 1.0, "Default pixel height should be 1.0")
        XCTAssertEqual(spacing.z, 1.0, "Default pixel depth should be 1.0")

        let windowSettings = decoder.windowSettingsV2
        XCTAssertEqual(windowSettings.center, 0.0, "Default window center should be 0.0")
        XCTAssertEqual(windowSettings.width, 0.0, "Default window width should be 0.0")

        let rescaleParams = decoder.rescaleParametersV2
        XCTAssertEqual(rescaleParams.intercept, 0.0, "Default rescale intercept should be 0.0")
        XCTAssertEqual(rescaleParams.slope, 1.0, "Default rescale slope should be 1.0")
    }

    func testGroupedHelpersConcurrentAccess() {
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent grouped helpers access")
        expectation.expectedFulfillmentCount = 10

        // Test concurrent access to all grouped helpers
        for _ in 0..<10 {
            DispatchQueue.global().async {
                _ = decoder.imageDimensions
                _ = decoder.pixelSpacingV2
                _ = decoder.windowSettingsV2
                _ = decoder.rescaleParametersV2

                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testGroupedHelpersConsistencyAfterMultipleAccesses() {
        let decoder = DCMDecoder()

        // Access grouped helpers multiple times
        for _ in 0..<100 {
            let dims1 = decoder.imageDimensions
            let dims2 = decoder.imageDimensions
            XCTAssertEqual(dims1.width, dims2.width, "Image dimensions should be consistent")
            XCTAssertEqual(dims1.height, dims2.height, "Image dimensions should be consistent")

            let spacing1 = decoder.pixelSpacingV2
            let spacing2 = decoder.pixelSpacingV2
            XCTAssertEqual(spacing1.x, spacing2.x, "Pixel spacing should be consistent")
            XCTAssertEqual(spacing1.y, spacing2.y, "Pixel spacing should be consistent")
            XCTAssertEqual(spacing1.z, spacing2.z, "Pixel spacing should be consistent")

            let window1 = decoder.windowSettingsV2
            let window2 = decoder.windowSettingsV2
            XCTAssertEqual(window1.center, window2.center, "Window settings should be consistent")
            XCTAssertEqual(window1.width, window2.width, "Window settings should be consistent")

            let rescale1 = decoder.rescaleParametersV2
            let rescale2 = decoder.rescaleParametersV2
            XCTAssertEqual(rescale1.intercept, rescale2.intercept, "Rescale parameters should be consistent")
            XCTAssertEqual(rescale1.slope, rescale2.slope, "Rescale parameters should be consistent")
        }
    }

    // MARK: - Convenience Property Tests

    func testRescaleParametersStructure() {
        let decoder = DCMDecoder()
        let params = decoder.rescaleParametersV2

        XCTAssertEqual(params.intercept, 0.0, "Default rescale intercept should be 0.0")
        XCTAssertEqual(params.slope, 1.0, "Default rescale slope should be 1.0")
        XCTAssertTrue(params.isIdentity, "Default rescale parameters should be identity")
    }

    func testWindowSettingsStructure() {
        let decoder = DCMDecoder()
        let settings = decoder.windowSettingsV2

        XCTAssertEqual(settings.center, 0.0, "Default window center should be 0.0")
        XCTAssertEqual(settings.width, 0.0, "Default window width should be 0.0")
        XCTAssertFalse(settings.isValid, "Default window settings should be invalid until populated")
    }

    func testPixelSpacingStructure() {
        let decoder = DCMDecoder()
        let spacing = decoder.pixelSpacingV2

        XCTAssertEqual(spacing.x, 1.0, "Default pixel spacing x should be 1.0")
        XCTAssertEqual(spacing.y, 1.0, "Default pixel spacing y should be 1.0")
        XCTAssertEqual(spacing.z, 1.0, "Default pixel spacing z should be 1.0")
        XCTAssertTrue(spacing.isValid, "Default pixel spacing should be valid")
    }

    func testImageDimensionsStructure() {
        let decoder = DCMDecoder()
        let dimensions = decoder.imageDimensions

        XCTAssertEqual(dimensions.width, decoder.width, "Image dimensions width should mirror decoder width")
        XCTAssertEqual(dimensions.height, decoder.height, "Image dimensions height should mirror decoder height")
        XCTAssertGreaterThan(dimensions.width, 0, "Default image width should be positive")
        XCTAssertGreaterThan(dimensions.height, 0, "Default image height should be positive")
    }

    // MARK: - Info Dictionary Tests

    func testInfoMethodWithEmptyDecoder() {
        let decoder = DCMDecoder()

        let patientName = decoder.info(for: .patientName)
        XCTAssertEqual(patientName, "", "Info should return empty string for uninitialized decoder")

        let modality = decoder.info(for: .modality)
        XCTAssertEqual(modality, "", "Info should return empty string for uninitialized decoder")
    }

    func testIntValueMethodWithEmptyDecoder() {
        let decoder = DCMDecoder()

        let rows = decoder.intValue(for: .rows)
        XCTAssertNil(rows, "intValue should return nil for uninitialized decoder")

        let columns = decoder.intValue(for: .columns)
        XCTAssertNil(columns, "intValue should return nil for uninitialized decoder")
    }

    func testDoubleValueMethodWithEmptyDecoder() {
        let decoder = DCMDecoder()

        let pixelSpacing = decoder.doubleValue(for: .pixelSpacing)
        XCTAssertNil(pixelSpacing, "doubleValue should return nil for uninitialized decoder")

        let sliceThickness = decoder.doubleValue(for: .sliceThickness)
        XCTAssertNil(sliceThickness, "doubleValue should return nil for uninitialized decoder")
    }

    func testGetAllTagsWithEmptyDecoder() {
        let decoder = DCMDecoder()
        XCTAssertTrue(decoder.getAllTags().isEmpty, "getAllTags should return empty dictionary for uninitialized decoder")
    }

    func testGetPatientInfoWithEmptyDecoder() {
        let decoder = DCMDecoder()
        let patientInfo = decoder.getPatientInfo()

        XCTAssertNotNil(patientInfo, "getPatientInfo should return dictionary")
        XCTAssertEqual(patientInfo["Name"], "", "Patient name should be empty")
        XCTAssertEqual(patientInfo["ID"], "", "Patient ID should be empty")
        XCTAssertEqual(patientInfo["Sex"], "", "Patient sex should be empty")
        XCTAssertEqual(patientInfo["Age"], "", "Patient age should be empty")
    }

    func testGetStudyInfoWithEmptyDecoder() {
        let decoder = DCMDecoder()
        let studyInfo = decoder.getStudyInfo()

        XCTAssertNotNil(studyInfo, "getStudyInfo should return dictionary")
        XCTAssertEqual(studyInfo["StudyInstanceUID"], "", "Study Instance UID should be empty")
        XCTAssertEqual(studyInfo["StudyID"], "", "Study ID should be empty")
        XCTAssertEqual(studyInfo["StudyDate"], "", "Study date should be empty")
        XCTAssertEqual(studyInfo["StudyTime"], "", "Study time should be empty")
        XCTAssertEqual(studyInfo["StudyDescription"], "", "Study description should be empty")
        XCTAssertEqual(studyInfo["ReferringPhysician"], "", "Referring physician should be empty")
    }

    func testGetSeriesInfoWithEmptyDecoder() {
        let decoder = DCMDecoder()
        let seriesInfo = decoder.getSeriesInfo()

        XCTAssertNotNil(seriesInfo, "getSeriesInfo should return dictionary")
        XCTAssertEqual(seriesInfo["SeriesInstanceUID"], "", "Series Instance UID should be empty")
        XCTAssertEqual(seriesInfo["SeriesNumber"], "", "Series number should be empty")
        XCTAssertEqual(seriesInfo["SeriesDate"], "", "Series date should be empty")
        XCTAssertEqual(seriesInfo["SeriesTime"], "", "Series time should be empty")
        XCTAssertEqual(seriesInfo["SeriesDescription"], "", "Series description should be empty")
        XCTAssertEqual(seriesInfo["Modality"], "", "Modality should be empty")
    }

}
