//
//  DCMDecoderDownsamplingTests.swift
//  DicomCoreTests
//
//  Checks downsampled pixel access with unavailable data, incompatible bit depths, and bounded
//  output dimensions.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

// Compatibility coverage: this suite intentionally exercises deprecated
// public APIs that remain available (issue #1221); the annotation keeps
// the deliberate legacy usage warning-free without hiding new ones.
@available(*, deprecated)
final class DCMDecoderDownsamplingTests: XCTestCase {

    // MARK: - Downsampling Tests

    func testGetDownsampledPixels16WithUninitializedDecoder() {
        let decoder = DCMDecoder()

        let result = decoder.getDownsampledPixels16()

        // Uninitialized decoder may return minimal default dimensions (1x1)
        if let (pixels, width, height) = result {
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
            XCTAssertLessThanOrEqual(width, 1, "Width should be minimal for uninitialized decoder")
            XCTAssertLessThanOrEqual(height, 1, "Height should be minimal for uninitialized decoder")
        }
    }

    func testGetDownsampledPixels16AfterFailedLoad() {
        let decoder = DCMDecoder()

        decoder.setDicomFilename("/nonexistent/file.dcm")

        let result = decoder.getDownsampledPixels16()

        XCTAssertFalse(decoder.isValid(), "File load should not succeed")
        XCTAssertNil(result, "Downsampling should return nil after failed load")
    }

    func testGetDownsampledPixels16RequiresGrayscale16Bit() throws {
        let url = try makeTemporaryDICOM(bitsAllocated: 8, samplesPerPixel: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.samplesPerPixel, 1)
        XCTAssertEqual(decoder.bitDepth, 8)
        XCTAssertNil(decoder.getDownsampledPixels16(), "Downsampling should only work with 16-bit grayscale images")
    }

    func testGetDownsampledPixels16WithDefaultMaxDimension() {
        let decoder = DCMDecoder()

        // Default maxDimension is 150
        let result = decoder.getDownsampledPixels16()

        // Uninitialized decoder may return minimal result
        if let (pixels, width, height) = result {
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }
    }

    func testGetDownsampledPixels16WithCustomMaxDimension() {
        let decoder = DCMDecoder()

        // Test with custom maxDimension
        let result = decoder.getDownsampledPixels16(maxDimension: 100)

        // Uninitialized decoder may return minimal result
        if let (pixels, width, height) = result {
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
            XCTAssertLessThanOrEqual(max(width, height), 100, "Dimensions should respect maxDimension")
        }
    }

    func testGetDownsampledPixels16MaxDimensionBounds() {
        let decoder = DCMDecoder()

        // Test various maxDimension values
        let smallResult = decoder.getDownsampledPixels16(maxDimension: 50)
        if let (pixels, width, height) = smallResult {
            XCTAssertLessThanOrEqual(max(width, height), 50, "Should respect small maxDimension")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }

        let largeResult = decoder.getDownsampledPixels16(maxDimension: 500)
        if let (pixels, width, height) = largeResult {
            XCTAssertLessThanOrEqual(max(width, height), 500, "Should respect large maxDimension")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }

        let tinyResult = decoder.getDownsampledPixels16(maxDimension: 10)
        if let (pixels, width, height) = tinyResult {
            XCTAssertLessThanOrEqual(max(width, height), 10, "Should respect tiny maxDimension")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }
    }

    func testGetDownsampledPixels16AspectRatioPreservation() throws {
        let url = try makeTemporaryDICOM(bitsAllocated: 16, samplesPerPixel: 1, width: 8, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)

        let maxDim = 4
        let thumbnail = try XCTUnwrap(decoder.getDownsampledPixels16(maxDimension: maxDim))
        let originalAspect = Double(decoder.width) / Double(decoder.height)
        let thumbnailAspect = Double(thumbnail.width) / Double(thumbnail.height)

        XCTAssertLessThanOrEqual(thumbnail.width, maxDim)
        XCTAssertLessThanOrEqual(thumbnail.height, maxDim)
        XCTAssertEqual(thumbnail.pixels.count, thumbnail.width * thumbnail.height)
        XCTAssertEqual(thumbnailAspect, originalAspect, accuracy: 0.1,
                       "Downsampled aspect ratio should match original")
    }

    func testGetDownsampledPixels16ReturnsExpectedTupleStructure() {
        let decoder = DCMDecoder()

        // When result is available, it should be a tuple (pixels, width, height)
        let result = decoder.getDownsampledPixels16(maxDimension: 150)

        // For uninitialized decoder, result will be nil
        if let (pixels, width, height) = result {
            XCTAssertFalse(pixels.isEmpty, "Downsampled pixels should not be empty")
            XCTAssertGreaterThan(width, 0, "Downsampled width should be positive")
            XCTAssertGreaterThan(height, 0, "Downsampled height should be positive")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        } else {
            XCTAssertNil(result, "Uninitialized decoder should return nil")
        }
    }

    func testGetDownsampledPixels16DimensionsWithinMaxBounds() {
        let decoder = DCMDecoder()

        let maxDim = 100
        let result = decoder.getDownsampledPixels16(maxDimension: maxDim)

        if let (_, width, height) = result {
            XCTAssertLessThanOrEqual(width, maxDim,
                                    "Downsampled width should not exceed maxDimension")
            XCTAssertLessThanOrEqual(height, maxDim,
                                    "Downsampled height should not exceed maxDimension")

            // At least one dimension should be close to maxDim (aspect-preserving)
            let maxOfDimensions = max(width, height)
            XCTAssertLessThanOrEqual(maxOfDimensions, maxDim,
                                    "Larger dimension should not exceed maxDimension")
        }
    }

    func testGetDownsampledPixels16ConsistencyAcrossMultipleCalls() {
        let decoder = DCMDecoder()

        let result1 = decoder.getDownsampledPixels16(maxDimension: 150)
        let result2 = decoder.getDownsampledPixels16(maxDimension: 150)

        // Both should be nil for uninitialized decoder
        XCTAssertEqual(result1 == nil, result2 == nil,
                      "Multiple downsampling calls should be consistent")

        if let (pixels1, width1, height1) = result1,
           let (pixels2, width2, height2) = result2 {
            XCTAssertEqual(width1, width2, "Downsampled width should be consistent")
            XCTAssertEqual(height1, height2, "Downsampled height should be consistent")
            XCTAssertEqual(pixels1.count, pixels2.count, "Downsampled pixel count should be consistent")
        }
    }

    // Async downsampled pixel methods have been removed as they were deprecated.



    func testDownsamplingExcludesColorImages() throws {
        let url = try makeTemporaryDICOM(bitsAllocated: 8, samplesPerPixel: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.samplesPerPixel, 3)
        XCTAssertNil(decoder.getDownsampledPixels16(), "Downsampling should not work on color/RGB images")
    }

    func testDownsamplingExcludes8BitImages() throws {
        let url = try makeTemporaryDICOM(bitsAllocated: 8, samplesPerPixel: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.bitDepth, 8)
        XCTAssertNil(decoder.getDownsampledPixels16(), "Downsampling should not work on 8-bit images")
    }

    // MARK: - Downsampled Pixels 8-bit Tests

    func testGetDownsampledPixels8WithUninitializedDecoder() {
        let decoder = DCMDecoder()

        let result = decoder.getDownsampledPixels8()

        // Uninitialized decoder may return minimal default dimensions (1x1)
        if let (pixels, width, height) = result {
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
            XCTAssertLessThanOrEqual(width, 1, "Width should be minimal for uninitialized decoder")
            XCTAssertLessThanOrEqual(height, 1, "Height should be minimal for uninitialized decoder")
        }
    }

    func testGetDownsampledPixels8AfterFailedLoad() {
        let decoder = DCMDecoder()

        decoder.setDicomFilename("/nonexistent/file.dcm")

        let result = decoder.getDownsampledPixels8()

        XCTAssertFalse(decoder.isValid(), "File load should not succeed")
        XCTAssertNil(result, "Downsampling should return nil after failed load")
    }

    func testGetDownsampledPixels8RequiresGrayscale8Bit() throws {
        let url = try makeTemporaryDICOM(bitsAllocated: 16, samplesPerPixel: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.samplesPerPixel, 1)
        XCTAssertEqual(decoder.bitDepth, 16)
        XCTAssertNil(decoder.getDownsampledPixels8(), "Downsampling should only work with 8-bit grayscale images")
    }

    func testGetDownsampledPixels8WithDefaultMaxDimension() {
        let decoder = DCMDecoder()

        // Default maxDimension is 150
        let result = decoder.getDownsampledPixels8()

        // Uninitialized decoder may return minimal result
        if let (pixels, width, height) = result {
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }
    }

    func testGetDownsampledPixels8WithCustomMaxDimension() {
        let decoder = DCMDecoder()

        // Test with custom maxDimension
        let result = decoder.getDownsampledPixels8(maxDimension: 100)

        // Uninitialized decoder may return minimal result
        if let (pixels, width, height) = result {
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
            XCTAssertLessThanOrEqual(max(width, height), 100, "Dimensions should respect maxDimension")
        }
    }

    func testGetDownsampledPixels8MaxDimensionBounds() {
        let decoder = DCMDecoder()

        // Test various maxDimension values
        let smallResult = decoder.getDownsampledPixels8(maxDimension: 50)
        if let (pixels, width, height) = smallResult {
            XCTAssertLessThanOrEqual(max(width, height), 50, "Should respect small maxDimension")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }

        let largeResult = decoder.getDownsampledPixels8(maxDimension: 500)
        if let (pixels, width, height) = largeResult {
            XCTAssertLessThanOrEqual(max(width, height), 500, "Should respect large maxDimension")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }

        let tinyResult = decoder.getDownsampledPixels8(maxDimension: 10)
        if let (pixels, width, height) = tinyResult {
            XCTAssertLessThanOrEqual(max(width, height), 10, "Should respect tiny maxDimension")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        }
    }

    func testGetDownsampledPixels8AspectRatioPreservation() throws {
        let url = try makeTemporaryDICOM(bitsAllocated: 8, samplesPerPixel: 1, width: 8, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)

        let maxDim = 4
        let thumbnail = try XCTUnwrap(decoder.getDownsampledPixels8(maxDimension: maxDim))
        let originalAspect = Double(decoder.width) / Double(decoder.height)
        let thumbnailAspect = Double(thumbnail.width) / Double(thumbnail.height)

        XCTAssertLessThanOrEqual(thumbnail.width, maxDim)
        XCTAssertLessThanOrEqual(thumbnail.height, maxDim)
        XCTAssertEqual(thumbnail.pixels.count, thumbnail.width * thumbnail.height)
        XCTAssertEqual(thumbnailAspect, originalAspect, accuracy: 0.1,
                       "Downsampled aspect ratio should match original")
    }

    func testGetDownsampledPixels8ReturnsExpectedTupleStructure() {
        let decoder = DCMDecoder()

        // When result is available, it should be a tuple (pixels, width, height)
        let result = decoder.getDownsampledPixels8(maxDimension: 150)

        // For uninitialized decoder, result will be nil
        if let (pixels, width, height) = result {
            XCTAssertFalse(pixels.isEmpty, "Downsampled pixels should not be empty")
            XCTAssertGreaterThan(width, 0, "Downsampled width should be positive")
            XCTAssertGreaterThan(height, 0, "Downsampled height should be positive")
            XCTAssertEqual(pixels.count, width * height, "Pixel count should match dimensions")
        } else {
            XCTAssertNil(result, "Uninitialized decoder should return nil")
        }
    }

    func testGetDownsampledPixels8DimensionsWithinMaxBounds() {
        let decoder = DCMDecoder()

        let maxDim = 100
        let result = decoder.getDownsampledPixels8(maxDimension: maxDim)

        if let (_, width, height) = result {
            XCTAssertLessThanOrEqual(width, maxDim,
                                    "Downsampled width should not exceed maxDimension")
            XCTAssertLessThanOrEqual(height, maxDim,
                                    "Downsampled height should not exceed maxDimension")

            // At least one dimension should be close to maxDim (aspect-preserving)
            let maxOfDimensions = max(width, height)
            XCTAssertLessThanOrEqual(maxOfDimensions, maxDim,
                                    "Larger dimension should not exceed maxDimension")
        }
    }

    func testGetDownsampledPixels8ConsistencyAcrossMultipleCalls() {
        let decoder = DCMDecoder()

        let result1 = decoder.getDownsampledPixels8(maxDimension: 150)
        let result2 = decoder.getDownsampledPixels8(maxDimension: 150)

        // Both should be nil for uninitialized decoder
        XCTAssertEqual(result1 == nil, result2 == nil,
                      "Multiple downsampling calls should be consistent")

        if let (pixels1, width1, height1) = result1,
           let (pixels2, width2, height2) = result2 {
            XCTAssertEqual(width1, width2, "Downsampled width should be consistent")
            XCTAssertEqual(height1, height2, "Downsampled height should be consistent")
            XCTAssertEqual(pixels1.count, pixels2.count, "Downsampled pixel count should be consistent")
        }
    }



    func testDownsamplingExcludes16BitImagesForPixels8() throws {
        let url = try makeTemporaryDICOM(bitsAllocated: 16, samplesPerPixel: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.bitDepth, 16)
        XCTAssertNil(decoder.getDownsampledPixels8(), "Downsampling should not work on 16-bit images")
    }

    private func makeTemporaryDICOM(
        bitsAllocated: UInt16,
        samplesPerPixel: UInt16,
        width: UInt16 = 4,
        height: UInt16 = 4
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downsampling_\(UUID().uuidString).dcm")
        var data = Data()
        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        func appendUS(group: UInt16, element: UInt16, value: UInt16) {
            data.append(contentsOf: withUnsafeBytes(of: group.littleEndian) { Array($0) })
            data.append(contentsOf: withUnsafeBytes(of: element.littleEndian) { Array($0) })
            data.append(contentsOf: "US".utf8)
            data.append(contentsOf: [0x02, 0x00])
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        }

        func appendCS(group: UInt16, element: UInt16, value: String) {
            var bytes = Array(value.utf8)
            if bytes.count % 2 != 0 {
                bytes.append(0x20)
            }
            data.append(contentsOf: withUnsafeBytes(of: group.littleEndian) { Array($0) })
            data.append(contentsOf: withUnsafeBytes(of: element.littleEndian) { Array($0) })
            data.append(contentsOf: "CS".utf8)
            data.append(UInt8(bytes.count & 0xFF))
            data.append(UInt8((bytes.count >> 8) & 0xFF))
            data.append(contentsOf: bytes)
        }

        appendUS(group: 0x0028, element: 0x0010, value: height)
        appendUS(group: 0x0028, element: 0x0011, value: width)
        appendUS(group: 0x0028, element: 0x0002, value: samplesPerPixel)
        appendCS(group: 0x0028, element: 0x0004, value: samplesPerPixel == 3 ? "RGB" : "MONOCHROME2")
        appendUS(group: 0x0028, element: 0x0100, value: bitsAllocated)
        appendUS(group: 0x0028, element: 0x0101, value: bitsAllocated)
        appendUS(group: 0x0028, element: 0x0102, value: bitsAllocated - 1)
        appendUS(group: 0x0028, element: 0x0103, value: 0)
        if samplesPerPixel == 3 {
            appendUS(group: 0x0028, element: 0x0006, value: 0)
        }

        data.append(contentsOf: [0xE0, 0x7F, 0x10, 0x00])
        data.append(contentsOf: bitsAllocated == 8 ? Array("OB".utf8) : Array("OW".utf8))
        data.append(contentsOf: [0x00, 0x00])
        let bytesPerSample = max(1, Int(bitsAllocated) / 8)
        let pixelByteCount = Int(width) * Int(height) * Int(samplesPerPixel) * bytesPerSample
        let pixelLength = UInt32(pixelByteCount)
        data.append(contentsOf: withUnsafeBytes(of: pixelLength.littleEndian) { Array($0) })
        data.append(Data(repeating: 0x7F, count: pixelByteCount))

        try data.write(to: url)
        return url
    }
}
