import XCTest
@testable import DicomCore

/// Tests for the newly exposed internal static methods in DCMPixelReader:
/// - computePixelMetrics (private → internal)
/// - invertMonochrome1Vectorized (private → internal)
/// - invertMonochrome1SignedVectorized (private → internal)
/// - normaliseSigned16Vectorized (private → internal)
/// - readPixels8 / readPixels16 / readPixels24 (moved to DCMPixelReader+Range.swift)
final class DCMPixelReaderInternalTests: XCTestCase {

    // MARK: - computePixelMetrics Tests

    func testComputePixelMetricsWithValidDimensions() {
        let result = DCMPixelReader.computePixelMetrics(
            width: 512,
            height: 512,
            bytesPerPixel: 2,
            context: "test",
            logger: nil
        )
        XCTAssertNotNil(result, "Valid dimensions should return metrics")
        XCTAssertEqual(result?.numPixels, 512 * 512, "numPixels should be width * height")
        XCTAssertEqual(result?.numBytes, 512 * 512 * 2, "numBytes should be numPixels * bytesPerPixel")
    }

    func testComputePixelMetricsWithZeroWidth() {
        let result = DCMPixelReader.computePixelMetrics(
            width: 0,
            height: 512,
            bytesPerPixel: 2,
            context: "test",
            logger: nil
        )
        XCTAssertNil(result, "Zero width should return nil")
    }

    func testComputePixelMetricsWithZeroHeight() {
        let result = DCMPixelReader.computePixelMetrics(
            width: 512,
            height: 0,
            bytesPerPixel: 2,
            context: "test",
            logger: nil
        )
        XCTAssertNil(result, "Zero height should return nil")
    }

    func testComputePixelMetricsWithNegativeWidth() {
        let result = DCMPixelReader.computePixelMetrics(
            width: -1,
            height: 512,
            bytesPerPixel: 2,
            context: "test",
            logger: nil
        )
        XCTAssertNil(result, "Negative width should return nil")
    }

    func testComputePixelMetricsWithNegativeHeight() {
        let result = DCMPixelReader.computePixelMetrics(
            width: 512,
            height: -1,
            bytesPerPixel: 2,
            context: "test",
            logger: nil
        )
        XCTAssertNil(result, "Negative height should return nil")
    }

    func testComputePixelMetricsExceedingMaxDimension() {
        // maxImageDimension is 65536
        let result = DCMPixelReader.computePixelMetrics(
            width: 65537,
            height: 512,
            bytesPerPixel: 2,
            context: "test",
            logger: nil
        )
        XCTAssertNil(result, "Width exceeding maxImageDimension should return nil")
    }

    func testComputePixelMetricsAtMaxDimension() {
        // Exactly at the boundary (65536 × 1 × 2 bytes = 128KB, acceptable)
        let result = DCMPixelReader.computePixelMetrics(
            width: 65536,
            height: 1,
            bytesPerPixel: 1,
            context: "test",
            logger: nil
        )
        XCTAssertNotNil(result, "Dimensions at maxImageDimension boundary should succeed")
    }

    func testComputePixelMetricsWithSmallImage() {
        let result = DCMPixelReader.computePixelMetrics(
            width: 1,
            height: 1,
            bytesPerPixel: 1,
            context: "test",
            logger: nil
        )
        XCTAssertNotNil(result, "1x1 image should succeed")
        XCTAssertEqual(result?.numPixels, 1, "numPixels should be 1")
        XCTAssertEqual(result?.numBytes, 1, "numBytes should be 1")
    }

    func testComputePixelMetricsWith8BitImage() {
        let result = DCMPixelReader.computePixelMetrics(
            width: 256,
            height: 256,
            bytesPerPixel: 1,
            context: "8-bit",
            logger: nil
        )
        XCTAssertNotNil(result, "256x256 8-bit image should succeed")
        XCTAssertEqual(result?.numPixels, 256 * 256)
        XCTAssertEqual(result?.numBytes, 256 * 256 * 1)
    }

    func testComputePixelMetricsWith24BitImage() {
        let result = DCMPixelReader.computePixelMetrics(
            width: 128,
            height: 128,
            bytesPerPixel: 3,
            context: "24-bit",
            logger: nil
        )
        XCTAssertNotNil(result, "128x128 RGB image should succeed")
        XCTAssertEqual(result?.numPixels, 128 * 128)
        XCTAssertEqual(result?.numBytes, 128 * 128 * 3)
    }

    // MARK: - invertMonochrome1Vectorized Tests

    func test_monochrome1Vectorized8Bit_invertsPixels() {
        var pixels: [UInt8] = [0, 100, 200, 255]

        DCMPixelReader.invertMonochrome1Vectorized(buffer: &pixels, count: pixels.count)

        XCTAssertEqual(pixels, [255, 155, 55, 0])
    }

    func testInvertMonochrome1VectorizedBasic() {
        var pixels: [UInt16] = [0, 100, 32768, 65435, 65535]
        let count = pixels.count
        DCMPixelReader.invertMonochrome1Vectorized(buffer: &pixels, count: count)

        XCTAssertEqual(pixels[0], 65535, "0 should invert to 65535")
        XCTAssertEqual(pixels[1], 65435, "100 should invert to 65435")
        XCTAssertEqual(pixels[2], 32767, "32768 should invert to 32767")
        XCTAssertEqual(pixels[3], 100, "65435 should invert to 100")
        XCTAssertEqual(pixels[4], 0, "65535 should invert to 0")
    }

    func testInvertMonochrome1VectorizedIdempotent() {
        // Applying inversion twice should return to the original values
        var pixels: [UInt16] = [1000, 2000, 30000, 50000]
        let original = pixels
        DCMPixelReader.invertMonochrome1Vectorized(buffer: &pixels, count: pixels.count)
        DCMPixelReader.invertMonochrome1Vectorized(buffer: &pixels, count: pixels.count)
        XCTAssertEqual(pixels, original, "Double inversion should return original values")
    }

    func testInvertMonochrome1VectorizedSinglePixel() {
        var pixels: [UInt16] = [12345]
        DCMPixelReader.invertMonochrome1Vectorized(buffer: &pixels, count: 1)
        XCTAssertEqual(pixels[0], 65535 - 12345, "Single pixel inversion should work")
    }

    func testInvertMonochrome1VectorizedPartialCount() {
        var pixels: [UInt16] = [100, 200, 300, 400]
        // Only invert first 2 elements
        DCMPixelReader.invertMonochrome1Vectorized(buffer: &pixels, count: 2)
        XCTAssertEqual(pixels[0], 65435, "First pixel should be inverted")
        XCTAssertEqual(pixels[1], 65335, "Second pixel should be inverted")
        XCTAssertEqual(pixels[2], 300, "Third pixel should be unchanged")
        XCTAssertEqual(pixels[3], 400, "Fourth pixel should be unchanged")
    }

    func testInvertMonochrome1VectorizedFullRange() {
        // Test with all zero pixels
        var allZeros = [UInt16](repeating: 0, count: 100)
        DCMPixelReader.invertMonochrome1Vectorized(buffer: &allZeros, count: 100)
        XCTAssertTrue(allZeros.allSatisfy { $0 == 65535 }, "All zeros should invert to 65535")

        // Test with all max pixels
        var allMax = [UInt16](repeating: 65535, count: 100)
        DCMPixelReader.invertMonochrome1Vectorized(buffer: &allMax, count: 100)
        XCTAssertTrue(allMax.allSatisfy { $0 == 0 }, "All 65535 should invert to 0")
    }

    // MARK: - invertMonochrome1SignedVectorized Tests

    func testInvertMonochrome1SignedVectorizedBasic() {
        // For signed MONOCHROME1: 65535 - value (same formula as unsigned)
        var pixels: [UInt16] = [0, 1000, 32768, 64535, 65535]
        DCMPixelReader.invertMonochrome1SignedVectorized(buffer: &pixels, count: pixels.count)

        XCTAssertEqual(pixels[0], 65535, "0 should invert to 65535")
        XCTAssertEqual(pixels[1], 64535, "1000 should invert to 64535")
        XCTAssertEqual(pixels[2], 32767, "32768 should invert to 32767")
        XCTAssertEqual(pixels[3], 1000, "64535 should invert to 1000")
        XCTAssertEqual(pixels[4], 0, "65535 should invert to 0")
    }

    func testInvertMonochrome1SignedVectorizedIdempotent() {
        var pixels: [UInt16] = [5000, 10000, 20000, 40000]
        let original = pixels
        DCMPixelReader.invertMonochrome1SignedVectorized(buffer: &pixels, count: pixels.count)
        DCMPixelReader.invertMonochrome1SignedVectorized(buffer: &pixels, count: pixels.count)
        XCTAssertEqual(pixels, original, "Double inversion should return original values")
    }

    func testInvertMonochrome1SignedVectorizedSingleElement() {
        var pixels: [UInt16] = [0]
        DCMPixelReader.invertMonochrome1SignedVectorized(buffer: &pixels, count: 1)
        XCTAssertEqual(pixels[0], 65535, "0 should invert to 65535")
    }

    // MARK: - readPixels16 Range Tests

    func testReadPixels16WithValidRange() {
        // Build synthetic 16-bit little-endian pixel data
        let width = 4
        let height = 4
        let numPixels = width * height
        let offset = 10
        var data = Data(count: offset + numPixels * 2)

        // Fill with known values: pixel i = UInt16(i * 100)
        for i in 0..<numPixels {
            writeLittleEndianUInt16(UInt16(i * 100), to: &data, at: offset + i * 2)
        }

        let result = DCMPixelReader.readPixels16(
            data: data,
            range: 0..<numPixels,
            width: width,
            height: height,
            offset: offset,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )

        XCTAssertNotNil(result, "Should succeed with valid range")
        XCTAssertEqual(result?.pixels16?.count, numPixels, "Should return all pixels")
        XCTAssertEqual(result?.pixels16?[0], 0, "First pixel should be 0")
        XCTAssertEqual(result?.pixels16?[1], 100, "Second pixel should be 100")
        XCTAssertEqual(result?.pixels16?[numPixels - 1], UInt16((numPixels - 1) * 100), "Last pixel value should match")
    }

    func testReadPixels16WithPartialRange() {
        let width = 10
        let height = 10
        let numPixels = width * height
        let offset = 8
        var data = Data(count: offset + numPixels * 2)

        for i in 0..<numPixels {
            writeLittleEndianUInt16(UInt16(i + 1), to: &data, at: offset + i * 2)
        }

        let rangeStart = 10
        let rangeEnd = 20
        let result = DCMPixelReader.readPixels16(
            data: data,
            range: rangeStart..<rangeEnd,
            width: width,
            height: height,
            offset: offset,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )

        XCTAssertNotNil(result, "Partial range should succeed")
        XCTAssertEqual(result?.pixels16?.count, rangeEnd - rangeStart, "Should return exactly range count pixels")
        // Pixel at index 10 should have value 11 (i+1)
        XCTAssertEqual(result?.pixels16?[0], 11, "First pixel of range should be pixel[10] = 11")
    }

    func testReadPixels16WithMonochrome1() {
        let width = 2
        let height = 2
        let offset = 0
        var data = Data(count: offset + 4 * 2)

        // Set all pixels to 0 so inversion should give 65535
        for i in 0..<4 {
            writeLittleEndianUInt16(0, to: &data, at: offset + i * 2)
        }

        let result = DCMPixelReader.readPixels16(
            data: data,
            range: 0..<4,
            width: width,
            height: height,
            offset: offset,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME1"
        )

        XCTAssertNotNil(result, "MONOCHROME1 range read should succeed")
        XCTAssertTrue(result?.pixels16?.allSatisfy { $0 == 65535 } == true,
                      "MONOCHROME1 zero pixels should be inverted to 65535")
    }

    func testReadPixels16WithOutOfBoundsRange() {
        let width = 4
        let height = 4
        let numPixels = width * height
        let offset = 0
        let data = Data(count: numPixels * 2)

        let result = DCMPixelReader.readPixels16(
            data: data,
            range: 0..<(numPixels + 1),  // One more than available
            width: width,
            height: height,
            offset: offset,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )

        XCTAssertNil(result, "Out-of-bounds range should return nil")
    }

    func testReadPixels16WithEmptyRange() {
        let data = Data(count: 100)
        let result = DCMPixelReader.readPixels16(
            data: data,
            range: 5..<5,  // Empty range
            width: 10,
            height: 10,
            offset: 0,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )
        XCTAssertNil(result, "Empty range (lower == upper) should return nil")
    }

    func testReadPixels16WithZeroDimensions() {
        let data = Data(count: 100)
        let result = DCMPixelReader.readPixels16(
            data: data,
            range: 0..<10,
            width: 0,
            height: 10,
            offset: 0,
            pixelRepresentation: 0,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )
        XCTAssertNil(result, "Zero-width image should return nil")
    }

    func testReadPixels16SignedRepresentation() {
        let width = 2
        let height = 1
        let offset = 0
        var data = Data(count: 4)  // 2 pixels × 2 bytes

        // Write Int16(-1024) = 0xFC00 in little endian
        let signed: Int16 = -1024
        let unsigned = UInt16(bitPattern: signed)
        writeLittleEndianUInt16(unsigned, to: &data, at: 0)
        writeLittleEndianUInt16(0, to: &data, at: 2)

        let result = DCMPixelReader.readPixels16(
            data: data,
            range: 0..<2,
            width: width,
            height: height,
            offset: offset,
            pixelRepresentation: 1,  // Signed
            littleEndian: true,
            photometricInterpretation: "MONOCHROME2"
        )

        XCTAssertNotNil(result, "Signed representation should succeed")
        XCTAssertTrue(result?.signedImage == true, "signedImage should be true for pixelRepresentation=1")
        // -1024 normalized: Int(-1024) - Int(Int16.min) = -1024 - (-32768) = 31744
        XCTAssertEqual(result?.pixels16?[0], UInt16(31744), "Signed -1024 should normalize to 31744")
    }

    func testReadPixelsFusesSignedNormalizationAndMonochrome1Inversion() {
        let offset = 2
        let samples: [Int16] = [.min, -1, 0, .max]
        var data = Data(count: offset + samples.count * 2)
        for (index, sample) in samples.enumerated() {
            writeLittleEndianUInt16(
                UInt16(bitPattern: sample),
                to: &data,
                at: offset + index * 2
            )
        }

        let result = DCMPixelReader.readPixels(
            data: data,
            width: samples.count,
            height: 1,
            bitDepth: 16,
            samplesPerPixel: 1,
            offset: offset,
            pixelRepresentation: 1,
            littleEndian: true,
            photometricInterpretation: "MONOCHROME1"
        )

        XCTAssertTrue(result.signedImage)
        XCTAssertEqual(result.pixels16, [UInt16.max, 32768, 32767, 0])
    }

    // MARK: - readPixels8 Range Tests

    func testReadPixels8WithValidRange() {
        let width = 8
        let height = 8
        let numPixels = width * height
        let offset = 4
        var data = Data(count: offset + numPixels)

        data.withUnsafeMutableBytes { bytes in
            let ptr = bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            for i in 0..<numPixels {
                ptr[i] = UInt8(i % 256)
            }
        }

        let result = DCMPixelReader.readPixels8(
            data: data,
            range: 0..<numPixels,
            width: width,
            height: height,
            offset: offset,
            photometricInterpretation: "MONOCHROME2"
        )

        XCTAssertNotNil(result, "Valid 8-bit range read should succeed")
        XCTAssertEqual(result?.pixels8?.count, numPixels, "Should return all pixels")
        XCTAssertEqual(result?.pixels8?[0], 0, "First pixel should be 0")
        XCTAssertEqual(result?.pixels8?[1], 1, "Second pixel should be 1")
    }

    func testReadPixels8WithMonochrome1Inversion() {
        let width = 4
        let height = 1
        let offset = 0
        var data = Data(count: 4)

        data.withUnsafeMutableBytes { bytes in
            let ptr = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            ptr[0] = 0
            ptr[1] = 100
            ptr[2] = 200
            ptr[3] = 255
        }

        let result = DCMPixelReader.readPixels8(
            data: data,
            range: 0..<4,
            width: width,
            height: height,
            offset: offset,
            photometricInterpretation: "MONOCHROME1"
        )

        XCTAssertNotNil(result, "MONOCHROME1 8-bit read should succeed")
        XCTAssertEqual(result?.pixels8?[0], 255, "0 should invert to 255")
        XCTAssertEqual(result?.pixels8?[1], 155, "100 should invert to 155")
        XCTAssertEqual(result?.pixels8?[2], 55, "200 should invert to 55")
        XCTAssertEqual(result?.pixels8?[3], 0, "255 should invert to 0")
    }

    func testReadPixels8WithPartialRange() {
        let width = 10
        let height = 1
        let offset = 0
        var data = Data(count: 10)

        data.withUnsafeMutableBytes { bytes in
            let ptr = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<10 {
                ptr[i] = UInt8(i * 10)
            }
        }

        let result = DCMPixelReader.readPixels8(
            data: data,
            range: 3..<7,
            width: width,
            height: height,
            offset: offset,
            photometricInterpretation: "MONOCHROME2"
        )

        XCTAssertNotNil(result, "Partial 8-bit range read should succeed")
        XCTAssertEqual(result?.pixels8?.count, 4, "Should return 4 pixels")
        XCTAssertEqual(result?.pixels8?[0], 30, "Pixel at index 3 should be 30")
        XCTAssertEqual(result?.pixels8?[1], 40, "Pixel at index 4 should be 40")
    }

    func testReadPixels8WithOutOfBoundsRange() {
        let width = 4
        let height = 4
        let data = Data(count: 16)

        let result = DCMPixelReader.readPixels8(
            data: data,
            range: 10..<20,  // Exceeds width*height = 16
            width: width,
            height: height,
            offset: 0,
            photometricInterpretation: "MONOCHROME2"
        )

        XCTAssertNil(result, "Out-of-bounds range should return nil")
    }

    func testReadPixels8WithEmptyRange() {
        let data = Data(count: 100)
        let result = DCMPixelReader.readPixels8(
            data: data,
            range: 10..<10,
            width: 10,
            height: 10,
            offset: 0,
            photometricInterpretation: "MONOCHROME2"
        )
        XCTAssertNil(result, "Empty range should return nil")
    }

    // MARK: - readPixels24 Range Tests

    func testReadPixels24WithValidRange() {
        let width = 4
        let height = 4
        let numPixels = width * height
        let bytesPerPixel = 3
        let offset = 0
        var data = Data(count: numPixels * bytesPerPixel)

        // Set first pixel to (R=10, G=20, B=30)
        data.withUnsafeMutableBytes { bytes in
            let ptr = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            ptr[0] = 10  // R
            ptr[1] = 20  // G
            ptr[2] = 30  // B
            // Fill rest with zeros
        }

        let result = DCMPixelReader.readPixels24(
            data: data,
            range: 0..<numPixels,
            width: width,
            height: height,
            offset: offset
        )

        XCTAssertNotNil(result, "Valid 24-bit range read should succeed")
        XCTAssertEqual(result?.pixels24?.count, numPixels * bytesPerPixel, "Should return 3 bytes per pixel")
        XCTAssertEqual(result?.pixels24?[0], 10, "First pixel R should be 10")
        XCTAssertEqual(result?.pixels24?[1], 20, "First pixel G should be 20")
        XCTAssertEqual(result?.pixels24?[2], 30, "First pixel B should be 30")
    }

    func testReadPixels24WithPartialRange() {
        let width = 10
        let height = 10
        let numPixels = width * height
        let offset = 0
        var data = Data(count: numPixels * 3)

        // Set pixel at index 5 to (R=50, G=60, B=70)
        data.withUnsafeMutableBytes { bytes in
            let ptr = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            ptr[5 * 3] = 50
            ptr[5 * 3 + 1] = 60
            ptr[5 * 3 + 2] = 70
        }

        let result = DCMPixelReader.readPixels24(
            data: data,
            range: 5..<10,
            width: width,
            height: height,
            offset: offset
        )

        XCTAssertNotNil(result, "Partial 24-bit range should succeed")
        XCTAssertEqual(result?.pixels24?.count, 5 * 3, "Should return 5 pixels × 3 bytes")
        XCTAssertEqual(result?.pixels24?[0], 50, "Relative pixel 0 R should be 50")
        XCTAssertEqual(result?.pixels24?[1], 60, "Relative pixel 0 G should be 60")
        XCTAssertEqual(result?.pixels24?[2], 70, "Relative pixel 0 B should be 70")
    }

    func testReadPixels24WithOutOfBoundsRange() {
        let width = 4
        let height = 4
        let data = Data(count: 16 * 3)

        let result = DCMPixelReader.readPixels24(
            data: data,
            range: 10..<20,  // Upper bound exceeds 16
            width: width,
            height: height,
            offset: 0
        )

        XCTAssertNil(result, "Out-of-bounds 24-bit range should return nil")
    }

    func testReadPixels24WithEmptyRange() {
        let data = Data(count: 100)
        let result = DCMPixelReader.readPixels24(
            data: data,
            range: 5..<5,
            width: 10,
            height: 10,
            offset: 0
        )
        XCTAssertNil(result, "Empty 24-bit range should return nil")
    }

    func testReadPixels24WithZeroDimensions() {
        let data = Data(count: 100)
        let result = DCMPixelReader.readPixels24(
            data: data,
            range: 0..<5,
            width: 0,
            height: 10,
            offset: 0
        )
        XCTAssertNil(result, "Zero-width image for 24-bit range should return nil")
    }

    // MARK: - normaliseSigned16Vectorized Tests

    func testNormaliseSigned16VectorizedBasic() {
        // Create signed 16-bit data in little endian: Int16(-32768) = 0x8000
        // After normalization: Int(-32768) - Int(Int16.min) = 0
        let signedValue: Int16 = -32768
        var outputBuffer = [UInt16](repeating: 0, count: 1)
        var data = [UInt8](repeating: 0, count: 2)
        let unsigned = UInt16(bitPattern: signedValue)
        data[0] = UInt8(unsigned & 0xFF)         // low byte
        data[1] = UInt8((unsigned >> 8) & 0xFF)   // high byte

        data.withUnsafeBytes { rawPtr in
            let basePtr = rawPtr.baseAddress!
            DCMPixelReader.normaliseSigned16Vectorized(
                sourcePtr: basePtr,
                outputBuffer: &outputBuffer,
                count: 1,
                littleEndian: true
            )
        }
        XCTAssertEqual(outputBuffer[0], 0, "Int16.min (-32768) should normalize to 0")
    }

    func testNormaliseSigned16VectorizedZeroValue() {
        // Int16(0) normalized: 0 - (-32768) = 32768
        let signedValue: Int16 = 0
        var outputBuffer = [UInt16](repeating: 0, count: 1)
        var data = [UInt8](repeating: 0, count: 2)
        let unsigned = UInt16(bitPattern: signedValue)
        data[0] = UInt8(unsigned & 0xFF)
        data[1] = UInt8((unsigned >> 8) & 0xFF)

        data.withUnsafeBytes { rawPtr in
            DCMPixelReader.normaliseSigned16Vectorized(
                sourcePtr: rawPtr.baseAddress!,
                outputBuffer: &outputBuffer,
                count: 1,
                littleEndian: true
            )
        }
        XCTAssertEqual(outputBuffer[0], 32768, "Int16(0) should normalize to 32768")
    }

    func testNormaliseSigned16VectorizedMaxValue() {
        // Int16.max (32767) normalized: 32767 - (-32768) = 65535
        let signedValue: Int16 = 32767
        var outputBuffer = [UInt16](repeating: 0, count: 1)
        var data = [UInt8](repeating: 0, count: 2)
        let unsigned = UInt16(bitPattern: signedValue)
        data[0] = UInt8(unsigned & 0xFF)
        data[1] = UInt8((unsigned >> 8) & 0xFF)

        data.withUnsafeBytes { rawPtr in
            DCMPixelReader.normaliseSigned16Vectorized(
                sourcePtr: rawPtr.baseAddress!,
                outputBuffer: &outputBuffer,
                count: 1,
                littleEndian: true
            )
        }
        XCTAssertEqual(outputBuffer[0], 65535, "Int16.max (32767) should normalize to 65535")
    }

    // MARK: - Big Endian readPixels16 Tests

    func testReadPixels16BigEndian() {
        let width = 2
        let height = 1
        let offset = 0
        var data = Data(count: 4)  // 2 pixels, 2 bytes each

        // Write value 0x0100 (256) in big endian = [0x01, 0x00]
        data.withUnsafeMutableBytes { bytes in
            let ptr = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            ptr[0] = 0x01  // high byte of 256
            ptr[1] = 0x00  // low byte
            ptr[2] = 0x00
            ptr[3] = 0x10  // value 16 in big endian high-byte position
        }

        let result = DCMPixelReader.readPixels16(
            data: data,
            range: 0..<2,
            width: width,
            height: height,
            offset: offset,
            pixelRepresentation: 0,
            littleEndian: false,  // Big endian
            photometricInterpretation: "MONOCHROME2"
        )

        XCTAssertNotNil(result, "Big endian 16-bit read should succeed")
        XCTAssertEqual(result?.pixels16?[0], 256, "Big endian [0x01, 0x00] should be 256")
        XCTAssertEqual(result?.pixels16?[1], 16, "Big endian [0x00, 0x10] should be 16")
    }

    private func writeLittleEndianUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0x00FF)
        data[offset + 1] = UInt8((value >> 8) & 0x00FF)
    }
}
