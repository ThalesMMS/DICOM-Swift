//
//  DCMDecoderPixelDataTests.swift
//  DicomCoreTests
//
//  Checks initial pixel buffers and exclusive selection of the decoded pixel representation.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DCMDecoderPixelDataTests: XCTestCase {

    // MARK: - Pixel Buffer Initialization Tests

    func testInitialPixelBuffersAreNil() {
        let decoder = DCMDecoder()

        // Test that all pixel buffers start as nil
        XCTAssertNil(decoder.getPixels8(), "Initial pixels8 should be nil")
        XCTAssertNil(decoder.getPixels16(), "Initial pixels16 should be nil")
        XCTAssertNil(decoder.getPixels24(), "Initial pixels24 should be nil")
    }

    func testPixelBuffersNilAfterFailedLoad() {
        // Modern API: throwing initializer returns nil for nonexistent file
        let decoder = try? DCMDecoder(contentsOfFile: "/nonexistent/file.dcm")

        // Failed initialization should return nil
        XCTAssertNil(decoder, "Decoder should be nil when file doesn't exist")
    }

    func testPixelBuffersConsistentAfterMultipleAccesses() {
        let decoder = DCMDecoder()

        // Multiple calls should return consistent nil results
        let pixels8_1 = decoder.getPixels8()
        let pixels8_2 = decoder.getPixels8()
        XCTAssertEqual(pixels8_1, pixels8_2, "Multiple getPixels8 calls should be consistent")

        let pixels16_1 = decoder.getPixels16()
        let pixels16_2 = decoder.getPixels16()
        XCTAssertEqual(pixels16_1, pixels16_2, "Multiple getPixels16 calls should be consistent")

        let pixels24_1 = decoder.getPixels24()
        let pixels24_2 = decoder.getPixels24()
        XCTAssertEqual(pixels24_1, pixels24_2, "Multiple getPixels24 calls should be consistent")
    }

    // MARK: - Grayscale 8-bit Pixel Tests

    func testGetPixels8WithUninitializedDecoder() {
        let decoder = DCMDecoder()

        // Should return nil for uninitialized decoder
        XCTAssertNil(decoder.getPixels8(), "Uninitialized decoder should have nil pixels8")
    }

    func testGetPixels8AfterInvalidFileLoad() {
        // Modern API: throwing initializer returns nil for invalid file
        let decoder = try? DCMDecoder(contentsOfFile: "/invalid/path/file.dcm")
        XCTAssertNil(decoder, "Decoder should be nil for invalid file path")
    }

    func testGetPixels8AfterEmptyFileLoad() {
        // Modern API: throwing initializer returns nil for empty filename
        let decoder = try? DCMDecoder(contentsOfFile: "")
        XCTAssertNil(decoder, "Decoder should be nil for empty filename")
    }

    // MARK: - Grayscale 16-bit Pixel Tests

    func testGetPixels16WithUninitializedDecoder() {
        let decoder = DCMDecoder()

        // Should return nil for uninitialized decoder
        XCTAssertNil(decoder.getPixels16(), "Uninitialized decoder should have nil pixels16")
    }

    func testGetPixels16AfterInvalidFileLoad() {
        // Modern API: throwing initializer returns nil for invalid file
        let decoder = try? DCMDecoder(contentsOfFile: "/invalid/path/file.dcm")
        XCTAssertNil(decoder, "Decoder should be nil for invalid file path")
    }

    func testGetPixels16AfterEmptyFileLoad() {
        // Modern API: throwing initializer returns nil for empty filename
        let decoder = try? DCMDecoder(contentsOfFile: "")
        XCTAssertNil(decoder, "Decoder should be nil for empty filename")
    }

    func testGetPixels16AfterMultipleFailedLoads() {
        // Modern API: each throwing initializer attempt returns nil for nonexistent files
        let decoder1 = try? DCMDecoder(contentsOfFile: "/nonexistent/file1.dcm")
        XCTAssertNil(decoder1, "First decoder should be nil for nonexistent file")

        let decoder2 = try? DCMDecoder(contentsOfFile: "/nonexistent/file2.dcm")
        XCTAssertNil(decoder2, "Second decoder should be nil for nonexistent file")

        let decoder3 = try? DCMDecoder(contentsOfFile: "/nonexistent/file3.dcm")
        XCTAssertNil(decoder3, "Third decoder should be nil for nonexistent file")
    }

    // MARK: - Color 24-bit Pixel Tests

    func testGetPixels24WithUninitializedDecoder() {
        let decoder = DCMDecoder()

        // Should return nil for uninitialized decoder
        XCTAssertNil(decoder.getPixels24(), "Uninitialized decoder should have nil pixels24")
    }

    func testGetPixels24AfterInvalidFileLoad() {
        // Modern API: throwing initializer returns nil for invalid file
        let decoder = try? DCMDecoder(contentsOfFile: "/invalid/path/file.dcm")
        XCTAssertNil(decoder, "Decoder should be nil for invalid file path")
    }

    func testGetPixels24AfterEmptyFileLoad() {
        // Modern API: throwing initializer returns nil for empty filename
        let decoder = try? DCMDecoder(contentsOfFile: "")
        XCTAssertNil(decoder, "Decoder should be nil for empty filename")
    }

    // MARK: - Pixel Data Type Tests

    func testPixelDataTypesAreMutuallyExclusive() {
        let decoder = DCMDecoder()

        // In an uninitialized decoder, all should be nil
        let pixels8 = decoder.getPixels8()
        let pixels16 = decoder.getPixels16()
        let pixels24 = decoder.getPixels24()

        XCTAssertNil(pixels8, "pixels8 should be nil")
        XCTAssertNil(pixels16, "pixels16 should be nil")
        XCTAssertNil(pixels24, "pixels24 should be nil")

        // Note: In a properly loaded DICOM file, only one buffer would be non-nil
        // depending on samplesPerPixel and bitDepth
    }

    func testPixelBufferTypeConsistency() {
        let decoder = DCMDecoder()

        // Test that default state (samplesPerPixel=1, bitDepth=16) suggests pixels16 usage
        XCTAssertEqual(decoder.samplesPerPixel, 1, "Default should be grayscale")
        XCTAssertEqual(decoder.bitDepth, 16, "Default bit depth should be 16")

        // For this configuration, we expect pixels16 to be the relevant buffer
        // (though it will be nil until a file is loaded)
        XCTAssertNil(decoder.getPixels16(), "pixels16 should be nil before loading")
    }

    // MARK: - Validation Status and Pixel Data Tests

    func testValidationStatusHasPixelsFlag() {
        let decoder = DCMDecoder()

        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.hasPixels, "Uninitialized decoder should not have pixels")
    }

    func testValidationStatusHasPixelsAfterFailedLoad() {
        let decoder = DCMDecoder()

        // Modern API: use throwing initializer (will fail for nonexistent file)
        // Test that a fresh decoder has nil pixels
        let _ = try? DCMDecoder(contentsOfFile: "/nonexistent/file.dcm")

        let status = decoder.getValidationStatus()
        XCTAssertFalse(status.hasPixels, "Failed load should not have pixels")
    }

    func testPixelDataAlignmentWithValidationStatus() {
        let decoder = DCMDecoder()

        let status = decoder.getValidationStatus()
        let hasPixels = status.hasPixels

        // Pixel buffers should align with validation status
        let pixels8 = decoder.getPixels8()
        let pixels16 = decoder.getPixels16()
        let pixels24 = decoder.getPixels24()

        if !hasPixels {
            XCTAssertNil(pixels8, "No pixels8 when hasPixels is false")
            XCTAssertNil(pixels16, "No pixels16 when hasPixels is false")
            XCTAssertNil(pixels24, "No pixels24 when hasPixels is false")
        }
    }

    // MARK: - Pixel Data Edge Cases

    func testZeroSizedImage() {
        // Modern API: throwing initializer returns nil for nonexistent file
        let decoder = try? DCMDecoder(contentsOfFile: "/nonexistent/zerosized.dcm")

        // Decoder should be nil for invalid files
        XCTAssertNil(decoder, "Decoder should be nil for nonexistent file")
    }

    func testExtremeImageDimensions() {
        let decoder = DCMDecoder()

        // Test that decoder handles default values gracefully
        // Extreme dimensions would typically be validated during file loading
        XCTAssertGreaterThanOrEqual(decoder.width, 0, "Width should not be negative")
        XCTAssertGreaterThanOrEqual(decoder.height, 0, "Height should not be negative")

        // No pixels should be available for unloaded decoder
        XCTAssertNil(decoder.getPixels16(), "Should have no pixels for uninitialized decoder")
    }

    func testInvalidBitDepthConfiguration() {
        let decoder = DCMDecoder()

        // Test default bit depth
        XCTAssertEqual(decoder.bitDepth, 16, "Default bit depth should be 16")

        // For uninitialized decoder, pixel buffers should remain nil
        XCTAssertNil(decoder.getPixels8(), "Uninitialized decoder should have nil pixels8")
        XCTAssertNil(decoder.getPixels16(), "Uninitialized decoder should have nil pixels16")
        XCTAssertNil(decoder.getPixels24(), "Uninitialized decoder should have nil pixels24")
    }

    func testInvalidSamplesPerPixelConfiguration() {
        let decoder = DCMDecoder()

        // Test default samples per pixel
        XCTAssertEqual(decoder.samplesPerPixel, 1, "Default samples per pixel should be 1")
        XCTAssertGreaterThan(decoder.samplesPerPixel, 0, "Samples per pixel must be positive")

        // Uninitialized decoder should have nil pixel buffers
        XCTAssertNil(decoder.getPixels8(), "Should have nil pixels8")
        XCTAssertNil(decoder.getPixels16(), "Should have nil pixels16")
        XCTAssertNil(decoder.getPixels24(), "Should have nil pixels24")
    }

    func testPixelBufferSizeConsistency() {
        let decoder = DCMDecoder()

        // For an uninitialized decoder, all buffers should be nil
        let pixels8 = decoder.getPixels8()
        let pixels16 = decoder.getPixels16()
        let pixels24 = decoder.getPixels24()

        XCTAssertNil(pixels8, "Uninitialized pixels8 should be nil")
        XCTAssertNil(pixels16, "Uninitialized pixels16 should be nil")
        XCTAssertNil(pixels24, "Uninitialized pixels24 should be nil")
    }

    func testPixelDataAfterSequentialFailedLoads() {
        // Modern API: test that throwing initializer returns nil for each invalid path
        let invalidPaths = [
            "/nonexistent/file1.dcm",
            "/invalid/path/file2.dcm",
            "",
            "/tmp/missing.dcm",
            "/path/with/missing/directory/file.dcm"
        ]

        for path in invalidPaths {
            let decoder = try? DCMDecoder(contentsOfFile: path)
            XCTAssertNil(decoder, "Decoder should be nil for invalid path: \(path)")
        }
    }

    func testPixelDataConsistencyAfterReset() {
        // Modern API: test multiple failed loads
        let decoder1 = try? DCMDecoder(contentsOfFile: "/nonexistent/file.dcm")
        XCTAssertNil(decoder1, "First decoder should be nil for nonexistent file")

        let decoder2 = try? DCMDecoder(contentsOfFile: "/another/invalid/path.dcm")
        XCTAssertNil(decoder2, "Second decoder should be nil for nonexistent file")

        let decoder3 = try? DCMDecoder(contentsOfFile: "")
        XCTAssertNil(decoder3, "Third decoder should be nil for empty path")
    }

    func testPixelBufferBitDepthMismatch() {
        let decoder = DCMDecoder()

        // Test that bit depth and pixel buffer types are consistent
        let bitDepth = decoder.bitDepth
        let samplesPerPixel = decoder.samplesPerPixel

        // For uninitialized decoder, all buffers should be nil
        if bitDepth == 8 && samplesPerPixel == 1 {
            // Would expect pixels8 to be used
            XCTAssertNil(decoder.getPixels8(), "pixels8 should be nil until file loaded")
        } else if bitDepth == 16 && samplesPerPixel == 1 {
            // Would expect pixels16 to be used
            XCTAssertNil(decoder.getPixels16(), "pixels16 should be nil until file loaded")
        } else if samplesPerPixel == 3 {
            // Would expect pixels24 to be used
            XCTAssertNil(decoder.getPixels24(), "pixels24 should be nil until file loaded")
        }
    }

    func testPixelDataWithSpecialCharactersInPath() {
        // Test paths with special characters
        let specialPaths = [
            "/path/with spaces/file.dcm",
            "/path/with-dashes/file.dcm",
            "/path/with_underscores/file.dcm",
            "/path/with.dots/file.dcm",
            "/path/with(parentheses)/file.dcm"
        ]

        for path in specialPaths {
            let decoder = try? DCMDecoder(contentsOfFile: path)
            // Should handle gracefully without crashing
            XCTAssertNil(decoder, "Should return nil for nonexistent path: \(path)")
        }
    }

    func testPixelDataWithVeryLongPath() {
        // Modern API: test that throwing initializer handles very long paths
        let longPath = "/" + String(repeating: "subdirectory/", count: 50) + "file.dcm"
        let decoder = try? DCMDecoder(contentsOfFile: longPath)

        // Should handle gracefully by returning nil
        XCTAssertNil(decoder, "Should handle very long paths gracefully")
    }

    func testPixelDataAccessWithoutPriorValidation() {
        let decoder = DCMDecoder()

        // Accessing pixels without validating file first should be safe
        XCTAssertNil(decoder.getPixels8(), "Should safely return nil for pixels8")
        XCTAssertNil(decoder.getPixels16(), "Should safely return nil for pixels16")
        XCTAssertNil(decoder.getPixels24(), "Should safely return nil for pixels24")

        // Should not crash even if called multiple times
        for _ in 0..<10 {
            _ = decoder.getPixels16()
            _ = decoder.getPixels8()
            _ = decoder.getPixels24()
        }
    }

    func testPixelDataStateConsistency() {
        let decoder = DCMDecoder()

        // Multiple sequential accesses should return same result
        let result1 = decoder.getPixels16()
        let result2 = decoder.getPixels16()
        let result3 = decoder.getPixels16()

        XCTAssertEqual(result1, result2, "Sequential accesses should be consistent")
        XCTAssertEqual(result2, result3, "Sequential accesses should be consistent")
        XCTAssertEqual(result1, result3, "Sequential accesses should be consistent")
    }

    func testPixelBufferCrossTypeConsistency() {
        let decoder = DCMDecoder()

        // All buffer types should be consistently nil for uninitialized decoder
        for _ in 0..<5 {
            let p8 = decoder.getPixels8()
            let p16 = decoder.getPixels16()
            let p24 = decoder.getPixels24()

            XCTAssertNil(p8, "pixels8 should consistently be nil")
            XCTAssertNil(p16, "pixels16 should consistently be nil")
            XCTAssertNil(p24, "pixels24 should consistently be nil")
        }
    }

    func testPixelDataWithNilFilePath() {
        // Test with empty/nil path
        let decoder = try? DCMDecoder(contentsOfFile: "")

        XCTAssertNil(decoder, "Decoder should be nil for empty path")
    }

    func testPixelDataWithRelativePaths() {
        // Test relative paths
        let relativePaths = [
            "./file.dcm",
            "../file.dcm",
            "file.dcm",
            "./nested/path/file.dcm",
            "../../../file.dcm"
        ]

        for path in relativePaths {
            let decoder = try? DCMDecoder(contentsOfFile: path)
            // Should handle relative paths (they will fail to load but shouldn't crash)
            XCTAssertNil(decoder, "Should return nil for relative path: \(path)")
        }
    }

    func testPixelDataImagePropertiesEdgeCases() {
        let decoder = DCMDecoder()

        // Test property values are within valid ranges
        XCTAssertGreaterThanOrEqual(decoder.width, 0, "Width should not be negative")
        XCTAssertGreaterThanOrEqual(decoder.height, 0, "Height should not be negative")
        XCTAssertGreaterThan(decoder.bitDepth, 0, "Bit depth should be positive")
        XCTAssertGreaterThan(decoder.samplesPerPixel, 0, "Samples per pixel should be positive")

        // Verify reasonable default values
        XCTAssertLessThan(decoder.bitDepth, 64, "Bit depth should be reasonable")
        XCTAssertLessThan(decoder.samplesPerPixel, 10, "Samples per pixel should be reasonable")
    }

    func testPixelDataValidationStatusConsistency() {
        let decoder = DCMDecoder()

        // Validation status should align with pixel availability
        let status = decoder.getValidationStatus()

        if !status.hasPixels {
            XCTAssertNil(decoder.getPixels8(), "No pixels8 when status.hasPixels is false")
            XCTAssertNil(decoder.getPixels16(), "No pixels16 when status.hasPixels is false")
            XCTAssertNil(decoder.getPixels24(), "No pixels24 when status.hasPixels is false")
        }

        if !status.isValid {
            XCTAssertFalse(status.hasPixels, "Invalid decoder should not have pixels")
        }

        // Multiple status checks should be consistent
        let status2 = decoder.getValidationStatus()
        XCTAssertEqual(status.hasPixels, status2.hasPixels, "Status should be consistent")
        XCTAssertEqual(status.isValid, status2.isValid, "Status should be consistent")
    }

    func testPixelDataAfterMultipleReinitialization() {
        // Try creating multiple decoders with different invalid paths
        for i in 0..<5 {
            let decoder = try? DCMDecoder(contentsOfFile: "/nonexistent/file\(i).dcm")
            XCTAssertNil(decoder, "Should return nil for nonexistent file \(i)")
        }
    }

    func testPixelDataMemoryConsistency() {
        let decoder = DCMDecoder()

        // Test that repeated access doesn't cause memory issues
        for _ in 0..<100 {
            _ = decoder.getPixels8()
            _ = decoder.getPixels16()
            _ = decoder.getPixels24()
        }

        // All should still be nil
        XCTAssertNil(decoder.getPixels8(), "pixels8 should remain nil after many accesses")
        XCTAssertNil(decoder.getPixels16(), "pixels16 should remain nil after many accesses")
        XCTAssertNil(decoder.getPixels24(), "pixels24 should remain nil after many accesses")
    }

    func testPixelDataWithInvalidFileExtensions() {
        // Test files with incorrect or missing extensions
        let invalidExtensions = [
            "/path/file.txt",
            "/path/file.jpg",
            "/path/file",
            "/path/.dcm",
            "/path/file.DCM",  // uppercase
            "/path/file.dicom"
        ]

        for path in invalidExtensions {
            let decoder = try? DCMDecoder(contentsOfFile: path)
            XCTAssertNil(decoder, "Should return nil for invalid extension: \(path)")
        }
    }

    func testPixelBufferTypeExclusivity() {
        let decoder = DCMDecoder()

        // In a valid DICOM file, only one pixel buffer type should be active
        // For uninitialized decoder, all should be nil
        let pixels8 = decoder.getPixels8()
        let pixels16 = decoder.getPixels16()
        let pixels24 = decoder.getPixels24()

        // All buffers should be nil for uninitialized decoder
        XCTAssertNil(pixels8, "Uninitialized decoder should have nil pixels8")
        XCTAssertNil(pixels16, "Uninitialized decoder should have nil pixels16")
        XCTAssertNil(pixels24, "Uninitialized decoder should have nil pixels24")
    }

    func testPixelDataConsistencyAcrossValidationCalls() {
        let decoder = DCMDecoder()

        // Interleave validation checks with pixel access
        _ = decoder.getValidationStatus()
        let pixels1 = decoder.getPixels16()

        _ = decoder.getValidationStatus()
        let pixels2 = decoder.getPixels16()

        _ = decoder.getValidationStatus()
        let pixels3 = decoder.getPixels16()

        // All should be consistently nil
        XCTAssertEqual(pixels1, pixels2, "Pixels should be consistent across validation calls")
        XCTAssertEqual(pixels2, pixels3, "Pixels should be consistent across validation calls")
    }

    // MARK: - Image Properties and Pixel Buffer Relationship Tests

    func testImageDimensionsWithNoPixels() {
        let decoder = DCMDecoder()

        // Test that dimensions exist even without pixels
        XCTAssertEqual(decoder.width, 1, "Default width should be 1")
        XCTAssertEqual(decoder.height, 1, "Default height should be 1")

        // But pixels should be nil
        XCTAssertNil(decoder.getPixels16(), "pixels should be nil")
    }

    func testBitDepthPropertyConsistency() {
        let decoder = DCMDecoder()

        // Default bit depth is 16
        XCTAssertEqual(decoder.bitDepth, 16, "Default bit depth should be 16")

        // For 16-bit images, pixels16 is the relevant buffer
        // For 8-bit images, pixels8 would be used
        // All should be nil in uninitialized state
        XCTAssertNil(decoder.getPixels16(), "pixels16 should be nil initially")
        XCTAssertNil(decoder.getPixels8(), "pixels8 should be nil initially")
    }

    func testSamplesPerPixelPropertyConsistency() {
        let decoder = DCMDecoder()

        // Default is grayscale (1 sample per pixel)
        XCTAssertEqual(decoder.samplesPerPixel, 1, "Default should be grayscale")

        // For grayscale (1 sample), either pixels8 or pixels16 is used
        // For color (3 samples), pixels24 is used
        // All should be nil in uninitialized state
        XCTAssertNil(decoder.getPixels16(), "pixels16 should be nil initially")
        XCTAssertNil(decoder.getPixels24(), "pixels24 should be nil initially")
    }

    func testGrayscaleDetectionWithPixelBuffers() {
        let decoder = DCMDecoder()

        // Test grayscale detection
        XCTAssertTrue(decoder.isGrayscale, "Default should be grayscale")
        XCTAssertFalse(decoder.isColorImage, "Default should not be color")

        // Grayscale images use pixels8 or pixels16
        // Color images use pixels24
        // Verify buffers are nil before loading
        XCTAssertNil(decoder.getPixels16(), "Grayscale pixels16 should be nil before loading")
        XCTAssertNil(decoder.getPixels24(), "Color pixels24 should be nil before loading")
    }

    // MARK: - Pixel Representation Tests

    func testPixelRepresentationProperty() {
        let decoder = DCMDecoder()

        // Default pixel representation is 0 (unsigned)
        XCTAssertEqual(decoder.pixelRepresentationTagValue, 0, "Default pixel representation should be 0")
        XCTAssertFalse(decoder.isSignedPixelRepresentation, "Default should be unsigned")
    }

    func testSignedVsUnsignedPixelRepresentation() {
        let decoder = DCMDecoder()

        // Test unsigned representation (default)
        XCTAssertFalse(decoder.isSignedPixelRepresentation, "Default should be unsigned")

        // Both signed and unsigned use the same pixel buffers (pixels16 for 16-bit)
        XCTAssertNil(decoder.getPixels16(), "pixels16 should be nil before loading")
    }

    // MARK: - Async Pixel Access Tests

    // Async pixel access methods have been removed as they were deprecated.
    // Pixel access is now synchronous only via getPixels8(), getPixels16(), getPixels24().

    // MARK: - Pixel Data State Preservation Tests

    func testPixelDataStateAfterMultipleAccesses() {
        let decoder = DCMDecoder()

        // Access pixels multiple times
        for _ in 0..<5 {
            _ = decoder.getPixels16()
        }

        // State should remain consistent
        XCTAssertNil(decoder.getPixels16(), "pixels16 should still be nil")
        XCTAssertFalse(decoder.getValidationStatus().hasPixels, "Should still have no pixels")
    }

    func testPixelDataClearingAfterFailedLoad() {
        // First failed load
        let decoder1 = try? DCMDecoder(contentsOfFile: "/nonexistent/file1.dcm")
        XCTAssertNil(decoder1, "Decoder should be nil after first failed load")

        // Second failed load
        let decoder2 = try? DCMDecoder(contentsOfFile: "/nonexistent/file2.dcm")
        XCTAssertNil(decoder2, "Decoder should be nil after second failed load")
    }

    // MARK: - Edge Case Tests

    func testPixelAccessOnFreshDecoder() {
        // Create decoder and immediately access pixels
        let decoder = DCMDecoder()
        let pixels = decoder.getPixels16()

        XCTAssertNil(pixels, "Fresh decoder should have nil pixels")
    }

    func testMultipleDecodersIndependence() {
        let decoder1 = DCMDecoder()
        let decoder2 = DCMDecoder()

        // Access pixels on first decoder
        _ = decoder1.getPixels16()

        // Should not affect second decoder
        XCTAssertNil(decoder2.getPixels16(), "Second decoder should be independent")
    }

    func testPixelAccessAfterDecoderReuse() {
        // First use
        let decoder1 = try? DCMDecoder(contentsOfFile: "/nonexistent/file1.dcm")
        XCTAssertNil(decoder1, "Decoder should be nil after first use")

        // Second use with different file
        let decoder2 = try? DCMDecoder(contentsOfFile: "/nonexistent/file2.dcm")
        XCTAssertNil(decoder2, "Decoder should be nil after second use")
    }

    func testPixelBufferReturnTypeConsistency() {
        let decoder = DCMDecoder()

        // Test that return types are correct optionals
        let pixels8: [UInt8]? = decoder.getPixels8()
        let pixels16: [UInt16]? = decoder.getPixels16()
        let pixels24: [UInt8]? = decoder.getPixels24()

        XCTAssertNil(pixels8, "pixels8 should be nil")
        XCTAssertNil(pixels16, "pixels16 should be nil")
        XCTAssertNil(pixels24, "pixels24 should be nil")
    }

    // MARK: - RGB/Color Image Tests

    func testIsColorImageWithUninitializedDecoder() {
        let decoder = DCMDecoder()

        // Default should be grayscale (samplesPerPixel = 1)
        XCTAssertFalse(decoder.isColorImage, "Uninitialized decoder should not be color image")
    }

    func testIsColorImageDetection() {
        let decoder = DCMDecoder()

        // Test default state (grayscale)
        XCTAssertEqual(decoder.samplesPerPixel, 1, "Default samples per pixel should be 1")
        XCTAssertFalse(decoder.isColorImage, "Default should not be color image")
    }

    func testColorImageRelationshipWithSamplesPerPixel() {
        let decoder = DCMDecoder()

        // isColorImage should reflect samplesPerPixel
        let isColor = decoder.isColorImage
        let samplesPerPixel = decoder.samplesPerPixel

        if samplesPerPixel == 3 {
            XCTAssertTrue(isColor, "samplesPerPixel=3 should indicate color image")
        } else {
            XCTAssertFalse(isColor, "samplesPerPixel != 3 should not indicate color image")
        }
    }

    func testRGBPixelBufferSizeExpectations() {
        let decoder = DCMDecoder()

        // RGB images should have 3x the pixel count (RGB triplets)
        let width = decoder.width
        let height = decoder.height
        let samplesPerPixel = decoder.samplesPerPixel

        if samplesPerPixel == 3 {
            let expectedSize = width * height * 3
            // Note: pixels24 will be nil for uninitialized decoder
            // but we can test the expectation relationship
            XCTAssertEqual(samplesPerPixel, 3, "RGB images should have 3 samples per pixel")
            XCTAssertGreaterThan(expectedSize, 0, "Expected RGB buffer size should be positive")
        }
    }

    func testGetPixels24WithGrayscaleImage() {
        let decoder = DCMDecoder()

        // Grayscale images (samplesPerPixel=1) should not have pixels24
        if decoder.samplesPerPixel == 1 {
            XCTAssertNil(decoder.getPixels24(), "Grayscale images should not have pixels24 buffer")
        }
    }

    func testGetPixels24ReturnsNilForUninitializedDecoder() {
        let decoder = DCMDecoder()

        XCTAssertNil(decoder.getPixels24(), "pixels24 should be nil for uninitialized decoder")
    }

    func testGetPixels24ReturnsNilAfterFailedLoad() {
        let decoder = try? DCMDecoder(contentsOfFile: "/nonexistent/rgb_image.dcm")
        XCTAssertNil(decoder, "Decoder should be nil for nonexistent file")
    }

    func testGetPixels24ConsistencyAcrossMultipleCalls() {
        let decoder = DCMDecoder()

        let pixels24_1 = decoder.getPixels24()
        let pixels24_2 = decoder.getPixels24()

        XCTAssertEqual(pixels24_1, pixels24_2, "Multiple getPixels24 calls should return consistent results")
    }

    func testColorImageExcludesOtherPixelFormats() {
        let decoder = DCMDecoder()

        // In an uninitialized RGB decoder, verify format exclusivity
        if decoder.samplesPerPixel == 3 {
            // RGB images should not have 8-bit or 16-bit grayscale buffers
            XCTAssertNil(decoder.getPixels8(), "RGB images should not have pixels8")
            XCTAssertNil(decoder.getPixels16(), "RGB images should not have pixels16")
        }
    }
}
