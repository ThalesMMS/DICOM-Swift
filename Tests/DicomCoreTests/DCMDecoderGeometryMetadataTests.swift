import XCTest
@testable import DicomCore

final class DCMDecoderGeometryMetadataTests: XCTestCase {
    // MARK: - Image Geometry Tests

    func testImagePositionAccess() {
        let decoder = DCMDecoder()

        // Test initial image position
        XCTAssertNil(decoder.imagePosition, "Initial image position should be nil")
    }

    func testImageOrientationAccess() {
        let decoder = DCMDecoder()

        // Test initial image orientation
        XCTAssertNil(decoder.imageOrientation, "Initial image orientation should be nil")
    }

    // MARK: - Geometry and Spacing Tests

    func testImagePositionPatientTagAccess() {
        let decoder = DCMDecoder()

        // Test Image Position (Patient) tag access - 0x00200032
        let position = decoder.info(for: 0x00200032)
        XCTAssertEqual(position, "", "Uninitialized decoder should return empty string for image position")
    }

    func testImageOrientationPatientTagAccess() {
        let decoder = DCMDecoder()

        // Test Image Orientation (Patient) tag access - 0x00200037
        let orientation = decoder.info(for: 0x00200037)
        XCTAssertEqual(orientation, "", "Uninitialized decoder should return empty string for image orientation")
    }

    func testSliceLocationAccess() {
        let decoder = DCMDecoder()

        // Test Slice Location tag access - 0x00201041
        let sliceLocation = decoder.info(for: 0x00201041)
        XCTAssertEqual(sliceLocation, "", "Uninitialized decoder should return empty string for slice location")

        // Test double value conversion
        let sliceLocationValue = decoder.doubleValue(for: 0x00201041)
        XCTAssertNil(sliceLocationValue, "Uninitialized decoder should return nil for slice location double value")
    }

    func testSliceThicknessAccess() {
        let decoder = DCMDecoder()

        // Test Slice Thickness tag access - 0x00180050
        let sliceThickness = decoder.info(for: 0x00180050)
        XCTAssertEqual(sliceThickness, "", "Uninitialized decoder should return empty string for slice thickness")

        // Test double value conversion
        let sliceThicknessValue = decoder.doubleValue(for: 0x00180050)
        XCTAssertNil(sliceThicknessValue, "Uninitialized decoder should return nil for slice thickness double value")
    }

    func testPixelSpacingTagAccess() {
        let decoder = DCMDecoder()

        // Test Pixel Spacing tag access - 0x00280030
        let pixelSpacing = decoder.info(for: 0x00280030)
        XCTAssertEqual(pixelSpacing, "", "Uninitialized decoder should return empty string for pixel spacing")

        // Test double value conversion
        let pixelSpacingValue = decoder.doubleValue(for: 0x00280030)
        XCTAssertNil(pixelSpacingValue, "Uninitialized decoder should return nil for pixel spacing double value")
    }

    func testPixelSpacingPropertiesConsistency() {
        let decoder = DCMDecoder()

        // Test that pixel spacing properties match convenience accessors
        let spacing = decoder.pixelSpacingV2
        XCTAssertEqual(spacing.x, decoder.pixelWidth, "Pixel spacing width should match pixelWidth property")
        XCTAssertEqual(spacing.y, decoder.pixelHeight, "Pixel spacing height should match pixelHeight property")
        XCTAssertEqual(spacing.z, decoder.pixelDepth, "Pixel spacing depth should match pixelDepth property")
    }

    func testImageDimensionsPropertiesConsistency() {
        let decoder = DCMDecoder()

        // Test that image dimensions match convenience accessors
        let dimensions = decoder.imageDimensions
        XCTAssertEqual(dimensions.width, decoder.width, "Image dimensions width should match width property")
        XCTAssertEqual(dimensions.height, decoder.height, "Image dimensions height should match height property")
    }

    func testSpacingBetweenSlicesAccess() {
        let decoder = DCMDecoder()

        // Test Spacing Between Slices tag access - 0x00180088
        let spacing = decoder.info(for: 0x00180088)
        XCTAssertEqual(spacing, "", "Uninitialized decoder should return empty string for spacing between slices")

        // Test double value conversion
        let spacingValue = decoder.doubleValue(for: 0x00180088)
        XCTAssertNil(spacingValue, "Uninitialized decoder should return nil for spacing between slices double value")
    }

    func testImageOrientationPatientComponents() {
        let decoder = DCMDecoder()

        // Image Orientation (Patient) should contain 6 values (row cosines + column cosines)
        // Test that accessing it doesn't crash
        let orientation = decoder.info(for: 0x00200037)
        XCTAssertNotNil(orientation, "Image orientation info should not be nil")
    }

    func testImagePositionPatientComponents() {
        let decoder = DCMDecoder()

        // Image Position (Patient) should contain 3 values (x, y, z)
        // Test that accessing it doesn't crash
        let position = decoder.info(for: 0x00200032)
        XCTAssertNotNil(position, "Image position info should not be nil")
    }

    func testGeometryTagsConsistentAccess() {
        let decoder = DCMDecoder()

        // Test that multiple accesses to geometry tags return consistent results
        let position1 = decoder.info(for: 0x00200032)
        let position2 = decoder.info(for: 0x00200032)
        XCTAssertEqual(position1, position2, "Consecutive position accesses should return same result")

        let orientation1 = decoder.info(for: 0x00200037)
        let orientation2 = decoder.info(for: 0x00200037)
        XCTAssertEqual(orientation1, orientation2, "Consecutive orientation accesses should return same result")
    }

    func testPixelAspectRatioTagAccess() {
        let decoder = DCMDecoder()

        // Test Pixel Aspect Ratio tag access - 0x00280034
        let aspectRatio = decoder.info(for: 0x00280034)
        XCTAssertEqual(aspectRatio, "", "Uninitialized decoder should return empty string for pixel aspect ratio")
    }

    func testImagePlaneGeometryTags() {
        let decoder = DCMDecoder()

        let geometryTags = [
            0x0020_0032,  // Image Position (Patient)
            0x0020_0037,  // Image Orientation (Patient)
            0x0028_0030,  // Pixel Spacing
            0x0018_0050,  // Slice Thickness
            0x0018_0088,  // Spacing Between Slices
            0x0020_1041   // Slice Location
        ]

        XCTAssertTrue(geometryTags.allSatisfy { decoder.info(for: $0).isEmpty })
    }

    func testSpatialResolutionDefaults() {
        let decoder = DCMDecoder()

        // Test default spatial resolution values
        let pixelWidth = decoder.pixelWidth
        let pixelHeight = decoder.pixelHeight
        let pixelDepth = decoder.pixelDepth

        XCTAssertEqual(pixelWidth, 1.0, "Default pixel width should be 1.0")
        XCTAssertEqual(pixelHeight, 1.0, "Default pixel height should be 1.0")
        XCTAssertEqual(pixelDepth, 1.0, "Default pixel depth should be 1.0")
    }

    func testImageDimensionsDefaults() {
        let decoder = DCMDecoder()

        // Test default image dimension values
        let width = decoder.width
        let height = decoder.height

        XCTAssertGreaterThan(width, 0, "Default width should be positive")
        XCTAssertGreaterThan(height, 0, "Default height should be positive")
    }

    func testGeometryDoubleValueConversions() {
        let decoder = DCMDecoder()

        // Test all geometry-related double value conversions
        let spacing = decoder.doubleValue(for: 0x00280030)
        let thickness = decoder.doubleValue(for: 0x00180050)
        let location = decoder.doubleValue(for: 0x00201041)
        let spacingBetweenSlices = decoder.doubleValue(for: 0x00180088)

        XCTAssertNil(spacing, "Uninitialized decoder should return nil for pixel spacing")
        XCTAssertNil(thickness, "Uninitialized decoder should return nil for slice thickness")
        XCTAssertNil(location, "Uninitialized decoder should return nil for slice location")
        XCTAssertNil(spacingBetweenSlices, "Uninitialized decoder should return nil for spacing between slices")
    }

    func testFrameOfReferenceUIDAccess() {
        let decoder = DCMDecoder()

        // Test Frame of Reference UID tag access - 0x00200052
        let frameOfReference = decoder.info(for: 0x00200052)
        XCTAssertEqual(frameOfReference, "", "Uninitialized decoder should return empty string for frame of reference UID")
    }

    func testPositionReferenceIndicatorAccess() {
        let decoder = DCMDecoder()

        // Test Position Reference Indicator tag access - 0x00201040
        let positionReference = decoder.info(for: 0x00201040)
        XCTAssertEqual(positionReference, "", "Uninitialized decoder should return empty string for position reference indicator")
    }

    func testGeometryMetadataCompleteness() {
        let decoder = DCMDecoder()

        // Verify that all essential geometry metadata accessors are available
        XCTAssertNotNil(decoder.imageDimensions, "Image dimensions should be accessible")
        XCTAssertNotNil(decoder.pixelSpacingV2, "Pixel spacing should be accessible")
        XCTAssertNotNil(decoder.width, "Width property should be accessible")
        XCTAssertNotNil(decoder.height, "Height property should be accessible")
        XCTAssertNotNil(decoder.pixelWidth, "Pixel width property should be accessible")
        XCTAssertNotNil(decoder.pixelHeight, "Pixel height property should be accessible")
        XCTAssertNotNil(decoder.pixelDepth, "Pixel depth property should be accessible")
    }

    func testConcurrentGeometryAccess() {
        let decoder = DCMDecoder()
        let expectation = XCTestExpectation(description: "Concurrent geometry access")
        expectation.expectedFulfillmentCount = 10

        // Test concurrent access to geometry-related methods
        for _ in 0..<10 {
            DispatchQueue.global().async {
                _ = decoder.info(for: 0x00200032)  // Image Position
                _ = decoder.info(for: 0x00200037)  // Image Orientation
                _ = decoder.doubleValue(for: 0x00280030)  // Pixel Spacing
                _ = decoder.pixelSpacingV2
                _ = decoder.imageDimensions

                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

}
