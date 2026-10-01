import XCTest
import CoreGraphics
@testable import DicomSwiftUI

#if canImport(SwiftUI)
import SwiftUI
#endif

final class CGImageFactoryTests: XCTestCase {

    // MARK: - Valid Input Tests

    func testCreateImageWithValidInput() {
        // Create simple 2x2 grayscale image
        let pixels: [UInt8] = [0, 128, 255, 64]
        let width = 2
        let height = 2

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should create CGImage from valid input")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "CGImage width should match input")
            XCTAssertEqual(cgImage.height, height, "CGImage height should match input")
            XCTAssertEqual(cgImage.bitsPerComponent, 8, "Should use 8 bits per component")
            XCTAssertEqual(cgImage.bitsPerPixel, 8, "Grayscale should use 8 bits per pixel")
        }
    }

    func testCreateImageWithLargerDimensions() {
        // Create 10x10 image
        let width = 10
        let height = 10
        let pixelCount = width * height
        let pixels = [UInt8](repeating: 128, count: pixelCount)

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should create CGImage from larger dimensions")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match input")
            XCTAssertEqual(cgImage.height, height, "Height should match input")
        }
    }

    func testCreateImageWithVariousPixelValues() {
        // Test full range of UInt8 values
        let width = 256
        let height = 1
        let pixels = (0..<256).map { UInt8($0) }

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should handle full range of 8-bit values")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match")
            XCTAssertEqual(cgImage.height, height, "Height should match")
        }
    }

    // MARK: - Invalid Dimension Tests

    func testCreateImageWithZeroWidth() {
        let pixels: [UInt8] = [0, 128, 255, 64]
        let width = 0
        let height = 4

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNil(cgImage, "Should return nil for zero width")
    }

    func testCreateImageWithZeroHeight() {
        let pixels: [UInt8] = [0, 128, 255, 64]
        let width = 4
        let height = 0

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNil(cgImage, "Should return nil for zero height")
    }

    func testCreateImageWithNegativeWidth() {
        let pixels: [UInt8] = [0, 128, 255, 64]
        let width = -2
        let height = 2

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNil(cgImage, "Should return nil for negative width")
    }

    func testCreateImageWithNegativeHeight() {
        let pixels: [UInt8] = [0, 128, 255, 64]
        let width = 2
        let height = -2

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNil(cgImage, "Should return nil for negative height")
    }

    // MARK: - Mismatched Pixel Count Tests

    func testCreateImageWithTooFewPixels() {
        let pixels: [UInt8] = [0, 128]
        let width = 2
        let height = 2

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNil(cgImage, "Should return nil when pixel count is too small")
    }

    func testCreateImageWithTooManyPixels() {
        let pixels: [UInt8] = [0, 128, 255, 64, 200, 100]
        let width = 2
        let height = 2

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNil(cgImage, "Should return nil when pixel count is too large")
    }

    func testCreateImageWithEmptyPixelArray() {
        let pixels: [UInt8] = []
        let width = 0
        let height = 0

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNil(cgImage, "Should return nil for empty pixel array with zero dimensions")
    }

    func testCreateImageWithEmptyPixelArrayNonZeroDimensions() {
        let pixels: [UInt8] = []
        let width = 10
        let height = 10

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNil(cgImage, "Should return nil for empty pixel array with non-zero dimensions")
    }

    // MARK: - CGImage Properties Tests

    func testCGImageColorSpace() {
        let pixels: [UInt8] = [0, 128, 255, 64]
        let width = 2
        let height = 2

        guard let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height) else {
            XCTFail("Failed to create CGImage")
            return
        }

        // Verify it's a grayscale color space
        XCTAssertNotNil(cgImage.colorSpace, "CGImage should have color space")
        if let colorSpace = cgImage.colorSpace {
            XCTAssertEqual(colorSpace.numberOfComponents, 1, "Grayscale should have 1 component")
        }
    }

    func testCGImageBytesPerRow() {
        let width = 10
        let height = 10
        let pixels = [UInt8](repeating: 128, count: width * height)

        guard let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height) else {
            XCTFail("Failed to create CGImage")
            return
        }

        XCTAssertEqual(cgImage.bytesPerRow, width, "Grayscale should use width bytes per row")
    }

    // MARK: - Edge Case Tests

    func testCreateImageWithSinglePixel() {
        let pixels: [UInt8] = [128]
        let width = 1
        let height = 1

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should handle 1x1 image")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, 1, "Width should be 1")
            XCTAssertEqual(cgImage.height, 1, "Height should be 1")
        }
    }

    func testCreateImageWithWideAspectRatio() {
        // 100x1 image (wide)
        let width = 100
        let height = 1
        let pixels = [UInt8](repeating: 255, count: width * height)

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should handle wide aspect ratio")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match")
            XCTAssertEqual(cgImage.height, height, "Height should match")
        }
    }

    func testCreateImageWithTallAspectRatio() {
        // 1x100 image (tall)
        let width = 1
        let height = 100
        let pixels = [UInt8](repeating: 0, count: width * height)

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should handle tall aspect ratio")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match")
            XCTAssertEqual(cgImage.height, height, "Height should match")
        }
    }

    func testCreateImageWithLargeDimensions() {
        // Test with typical medical image dimensions
        let width = 512
        let height = 512
        let pixels = [UInt8](repeating: 128, count: width * height)

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should handle typical medical image dimensions (512x512)")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match")
            XCTAssertEqual(cgImage.height, height, "Height should match")
        }
    }

    // MARK: - SwiftUI Extension Tests

    #if canImport(SwiftUI)
    func testSwiftUIImageExtension() {
        let pixels: [UInt8] = [0, 128, 255, 64]
        let width = 2
        let height = 2

        let image = Image(dicomPixels: pixels, width: width, height: height)

        XCTAssertNotNil(image, "Should create SwiftUI Image from DICOM pixels")
    }

    func testSwiftUIImageExtensionWithInvalidDimensions() {
        let pixels: [UInt8] = [0, 128, 255, 64]
        let width = 0
        let height = 2

        let image = Image(dicomPixels: pixels, width: width, height: height)

        XCTAssertNil(image, "Should return nil for invalid dimensions")
    }

    func testSwiftUIImageExtensionWithMismatchedPixelCount() {
        let pixels: [UInt8] = [0, 128]
        let width = 2
        let height = 2

        let image = Image(dicomPixels: pixels, width: width, height: height)

        XCTAssertNil(image, "Should return nil for mismatched pixel count")
    }
    #endif

    // MARK: - Additional Edge Case Tests

    func testCreateImageWithVeryLargeDimensions() {
        // Test with very large medical image dimensions (common in high-res CT/MRI)
        let width = 2048
        let height = 2048
        let pixels = [UInt8](repeating: 128, count: width * height)

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should handle very large dimensions (2048x2048)")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match")
            XCTAssertEqual(cgImage.height, height, "Height should match")
        }
    }

    func testCreateImageWithNonSquareDimensions() {
        // Test with various aspect ratios
        let testCases: [(width: Int, height: Int)] = [
            (100, 50),   // Wide
            (50, 100),   // Tall
            (256, 512),  // Common medical aspect
            (1920, 1080) // HD aspect
        ]

        for (width, height) in testCases {
            let pixels = [UInt8](repeating: 128, count: width * height)
            let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

            XCTAssertNotNil(cgImage, "Should handle \(width)x\(height) dimensions")

            if let cgImage = cgImage {
                XCTAssertEqual(cgImage.width, width, "Width should match for \(width)x\(height)")
                XCTAssertEqual(cgImage.height, height, "Height should match for \(width)x\(height)")
            }
        }
    }

    func testCreateImageWithGradientPixels() {
        // Create gradient pattern (0 to 255)
        let width = 256
        let height = 256
        var pixels = [UInt8]()

        for _ in 0..<height {
            for x in 0..<width {
                pixels.append(UInt8(x))
            }
        }

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should create image from gradient pixels")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match")
            XCTAssertEqual(cgImage.height, height, "Height should match")
        }
    }

    func testCreateImageWithAllBlackPixels() {
        let width = 100
        let height = 100
        let pixels = [UInt8](repeating: 0, count: width * height)

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should create all-black image")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match")
            XCTAssertEqual(cgImage.height, height, "Height should match")
        }
    }

    func testCreateImageWithAllWhitePixels() {
        let width = 100
        let height = 100
        let pixels = [UInt8](repeating: 255, count: width * height)

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should create all-white image")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match")
            XCTAssertEqual(cgImage.height, height, "Height should match")
        }
    }

    func testCreateImageWithCheckerboardPattern() {
        // Create checkerboard pattern
        let width = 64
        let height = 64
        var pixels = [UInt8]()

        for y in 0..<height {
            for x in 0..<width {
                let isBlack = (x / 8 + y / 8) % 2 == 0
                pixels.append(isBlack ? 0 : 255)
            }
        }

        let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

        XCTAssertNotNil(cgImage, "Should create checkerboard pattern image")

        if let cgImage = cgImage {
            XCTAssertEqual(cgImage.width, width, "Width should match")
            XCTAssertEqual(cgImage.height, height, "Height should match")
        }
    }

    func testCreateImageMultipleTimesWithSameData() {
        // Test that creating multiple images from same data succeeds consistently
        let width = 10
        let height = 10
        let pixels = [UInt8](repeating: 128, count: width * height)

        for _ in 0..<10 {
            let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)
            XCTAssertNotNil(cgImage, "Should create image consistently")

            if let cgImage = cgImage {
                XCTAssertEqual(cgImage.width, width, "Width should match consistently")
                XCTAssertEqual(cgImage.height, height, "Height should match consistently")
            }
        }
    }

    func testCGImagePropertiesConsistency() {
        let width = 50
        let height = 50
        let pixels = [UInt8](repeating: 128, count: width * height)

        guard let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height) else {
            XCTFail("Failed to create CGImage")
            return
        }

        // Verify all expected properties
        XCTAssertEqual(cgImage.width, width, "Width property should be correct")
        XCTAssertEqual(cgImage.height, height, "Height property should be correct")
        XCTAssertEqual(cgImage.bitsPerComponent, 8, "Should use 8 bits per component")
        XCTAssertEqual(cgImage.bitsPerPixel, 8, "Should use 8 bits per pixel")
        XCTAssertEqual(cgImage.bytesPerRow, width, "Bytes per row should equal width for grayscale")
        XCTAssertNotNil(cgImage.colorSpace, "Should have color space")
        XCTAssertNotNil(cgImage.dataProvider, "Should have data provider")
    }

    func testCreateImageWithPrimeNumberDimensions() {
        // Test with prime number dimensions (edge case for some algorithms)
        let primeDimensions: [(width: Int, height: Int)] = [
            (3, 3),
            (7, 7),
            (11, 11),
            (13, 17),
            (31, 37)
        ]

        for (width, height) in primeDimensions {
            let pixels = [UInt8](repeating: 128, count: width * height)
            let cgImage = CGImageFactory.createImage(from: pixels, width: width, height: height)

            XCTAssertNotNil(cgImage, "Should handle prime dimensions \(width)x\(height)")

            if let cgImage = cgImage {
                XCTAssertEqual(cgImage.width, width, "Width should match for prime dimensions")
                XCTAssertEqual(cgImage.height, height, "Height should match for prime dimensions")
            }
        }
    }
}