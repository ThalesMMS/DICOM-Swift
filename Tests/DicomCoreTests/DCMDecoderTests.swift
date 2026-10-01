import XCTest
@testable import DicomCore

final class DCMDecoderTests: XCTestCase {

    // MARK: - Initialization Tests

    func testDecoderInitialization() {
        let decoder = DCMDecoder()

        // Test initial state
        XCTAssertFalse(decoder.dicomFound, "New decoder should not have DICM marker found")
        XCTAssertFalse(decoder.compressedImage, "New decoder should not be compressed")
        XCTAssertFalse(decoder.signedImage, "New decoder should not be signed")

        // Test initial dimensions
        XCTAssertEqual(decoder.width, 1, "Default width should be 1")
        XCTAssertEqual(decoder.height, 1, "Default height should be 1")
        XCTAssertEqual(decoder.bitDepth, 16, "Default bit depth should be 16")

        // Test initial samples and frames
        XCTAssertEqual(decoder.samplesPerPixel, 1, "Default samples per pixel should be 1")
        XCTAssertEqual(decoder.nImages, 1, "Default number of images should be 1")

        // Test initial pixel spacing
        XCTAssertEqual(decoder.pixelWidth, 1.0, "Default pixel width should be 1.0")
        XCTAssertEqual(decoder.pixelHeight, 1.0, "Default pixel height should be 1.0")
        XCTAssertEqual(decoder.pixelDepth, 1.0, "Default pixel depth should be 1.0")

        // Test initial window settings
        XCTAssertEqual(decoder.windowCenter, 0.0, "Default window center should be 0.0")
        XCTAssertEqual(decoder.windowWidth, 0.0, "Default window width should be 0.0")

        // Test initial photometric interpretation
        XCTAssertEqual(decoder.photometricInterpretation, "", "Default photometric interpretation should be empty")
    }

    func testDecoderInitialPixelBuffers() {
        let decoder = DCMDecoder()

        // Test that pixel buffers are initially nil
        XCTAssertNil(decoder.getPixels8(), "Initial pixels8 should be nil")
        XCTAssertNil(decoder.getPixels16(), "Initial pixels16 should be nil")
        XCTAssertNil(decoder.getPixels24(), "Initial pixels24 should be nil")
    }

    func testDecoderInitialValidationState() {
        let decoder = DCMDecoder()

        // Test isValid returns false initially
        XCTAssertFalse(decoder.isValid(), "New decoder should not be valid")

        // Test getValidationStatus
        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.isValid, "Initial validation status should be false")
        XCTAssertEqual(status.width, 1, "Initial status width should be 1")
        XCTAssertEqual(status.height, 1, "Initial status height should be 1")
        XCTAssertFalse(status.hasPixels, "Initial status should have no pixels")
        XCTAssertFalse(status.isCompressed, "Initial status should not be compressed")
    }


    // MARK: - Convenience Property Tests

    func testImageDimensionsProperty() {
        let decoder = DCMDecoder()
        let dimensions = decoder.imageDimensions

        XCTAssertEqual(dimensions.width, decoder.width, "imageDimensions.width should match width")
        XCTAssertEqual(dimensions.height, decoder.height, "imageDimensions.height should match height")
        XCTAssertEqual(dimensions.width, 1, "Initial dimensions width should be 1")
        XCTAssertEqual(dimensions.height, 1, "Initial dimensions height should be 1")
    }

    // Deprecated property tests removed - these APIs have been removed in v2.0.0
    // Use pixelSpacingV2, windowSettingsV2, and rescaleParametersV2 instead

    func testApplyRescaleMethod() {
        let decoder = DCMDecoder()

        // Test with default slope (1.0) and intercept (0.0)
        let value1 = decoder.applyRescale(to: 100.0)
        XCTAssertEqual(value1, 100.0, accuracy: 0.01, "Should apply default rescale correctly")

        let value2 = decoder.applyRescale(to: 0.0)
        XCTAssertEqual(value2, 0.0, accuracy: 0.01, "Should handle zero value")

        let value3 = decoder.applyRescale(to: -50.0)
        XCTAssertEqual(value3, -50.0, accuracy: 0.01, "Should handle negative value")
    }

    // MARK: - Image Type Detection Tests

    func testIsGrayscaleProperty() {
        let decoder = DCMDecoder()

        // Default should be grayscale (samplesPerPixel = 1)
        XCTAssertTrue(decoder.isGrayscale, "Default should be grayscale")
    }

    func testIsColorImageProperty() {
        let decoder = DCMDecoder()

        // Default should not be color (samplesPerPixel = 1, not 3)
        XCTAssertFalse(decoder.isColorImage, "Default should not be color")
    }

    func testIsMultiFrameProperty() {
        let decoder = DCMDecoder()

        // Default should not be multi-frame (nImages = 1)
        XCTAssertFalse(decoder.isMultiFrame, "Default should not be multi-frame")
    }

    func testPixelRepresentationProperties() {
        let decoder = DCMDecoder()

        // Test initial pixel representation
        XCTAssertEqual(decoder.pixelRepresentationTagValue, 0, "Default pixel representation should be 0 (unsigned)")
        XCTAssertFalse(decoder.isSignedPixelRepresentation, "Default should not be signed")
    }


    // MARK: - Quality Methods Tests

    func testGetQualityMetricsWithNoData() {
        let decoder = DCMDecoder()

        // Test getQualityMetrics with no pixel data
        let metrics = decoder.getQualityMetrics()
        XCTAssertNil(metrics, "getQualityMetrics should return nil with no pixel data")
    }

    // MARK: - Thread Safety Tests

    @MainActor
    func testConcurrentAccess() {
        let decoder = DCMDecoder()
        let expectation = self.expectation(description: "Concurrent access")
        expectation.expectedFulfillmentCount = 10

        // Test concurrent reads
        for _ in 0..<10 {
            DispatchQueue.global().async {
                _ = decoder.isValid()
                _ = decoder.width
                _ = decoder.height
                _ = decoder.getValidationStatus()
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0, handler: nil)
    }

    @MainActor
    func testConcurrentInfoAccess() {
        let decoder = DCMDecoder()
        let expectation = self.expectation(description: "Concurrent info access")
        expectation.expectedFulfillmentCount = 10

        // Test concurrent info method calls
        for _ in 0..<10 {
            DispatchQueue.global().async {
                _ = decoder.info(for: .patientName)
                _ = decoder.intValue(for: .rows)
                _ = decoder.doubleValue(for: .pixelSpacing)
                _ = decoder.getPatientInfo()
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0, handler: nil)
    }
}
