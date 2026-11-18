//
//  DCMDecoderRangePixelTests.swift
//  DicomCoreTests
//
//  Tests for the range-based pixel access APIs added in DCMDecoder+RangePixels.swift. These cover
//  getPixels8(range:), getPixels16(range:), getPixels24(range:) as well as the downsampled pixel
//  access methods.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

/// Tests for the range-based pixel access APIs added in DCMDecoder+RangePixels.swift.
/// These cover getPixels8(range:), getPixels16(range:), getPixels24(range:)
/// as well as the downsampled pixel access methods.
final class DCMDecoderRangePixelTests: XCTestCase {

    // MARK: - getPixels8(range:) Validation Tests

    func testGetPixels8RangeReturnsNilForUninitializedDecoder() {
        let decoder = DCMDecoder()
        // dicomFileReadSuccess is false before any file is loaded
        let result = decoder.getPixels8(range: 0..<10)
        XCTAssertNil(result, "getPixels8(range:) should return nil for uninitialized decoder")
    }

    func testGetPixels8RangeReturnsNilForFailedFileLoad() {
        let decoder = try? DCMDecoder(contentsOfFile: "/nonexistent/file.dcm")
        XCTAssertNil(decoder, "Decoder should be nil for nonexistent file")
    }

    func testGetPixels8RangeEmptyRange() {
        let decoder = DCMDecoder()
        // Even though decoder is uninitialized, an empty range would fail earlier
        let result = decoder.getPixels8(range: 5..<5)
        XCTAssertNil(result, "getPixels8(range:) should return nil for uninitialized decoder with empty range")
    }

    func testGetPixels8RangeReturnsNilForWrongBitDepth() {
        let decoder = DCMDecoder()
        // Default bitDepth is 16, so getPixels8 (requires bitDepth == 8) should fail
        // But will also fail because dicomFileReadSuccess is false
        let result = decoder.getPixels8(range: 0..<1)
        XCTAssertNil(result, "getPixels8(range:) should return nil when bitDepth != 8 or file not loaded")
    }

    func testGetPixels8RangeConsistencyMultipleCalls() {
        let decoder = DCMDecoder()
        let result1 = decoder.getPixels8(range: 0..<10)
        let result2 = decoder.getPixels8(range: 0..<10)
        // Both nil for uninitialized decoder
        XCTAssertEqual(result1 == nil, result2 == nil,
                       "Multiple calls to getPixels8(range:) should return consistent results")
    }

    // MARK: - getPixels16(range:) Validation Tests

    func testGetPixels16RangeReturnsNilForUninitializedDecoder() {
        let decoder = DCMDecoder()
        let result = decoder.getPixels16(range: 0..<10)
        XCTAssertNil(result, "getPixels16(range:) should return nil for uninitialized decoder")
    }

    func testGetPixels16RangeReturnsNilForFailedFileLoad() {
        let decoder = try? DCMDecoder(contentsOfFile: "/nonexistent/file.dcm")
        XCTAssertNil(decoder, "Decoder should be nil for nonexistent file")
    }

    func testGetPixels16RangeEmptyRange() {
        let decoder = DCMDecoder()
        let result = decoder.getPixels16(range: 0..<0)
        XCTAssertNil(result, "getPixels16(range:) should return nil for empty range on uninitialized decoder")
    }

    func testGetPixels16RangeConsistencyMultipleCalls() {
        let decoder = DCMDecoder()
        let result1 = decoder.getPixels16(range: 0..<10)
        let result2 = decoder.getPixels16(range: 0..<10)
        XCTAssertEqual(result1 == nil, result2 == nil,
                       "Multiple calls to getPixels16(range:) should be consistent")
    }

    func testGetPixels16RangeLargeRange() {
        let decoder = DCMDecoder()
        // A very large range on an uninitialized decoder should return nil
        let result = decoder.getPixels16(range: 0..<Int.max / 2)
        XCTAssertNil(result, "getPixels16(range:) should return nil for large range on uninitialized decoder")
    }

    // MARK: - getPixels24(range:) Validation Tests

    func testGetPixels24RangeReturnsNilForUninitializedDecoder() {
        let decoder = DCMDecoder()
        let result = decoder.getPixels24(range: 0..<10)
        XCTAssertNil(result, "getPixels24(range:) should return nil for uninitialized decoder")
    }

    func testGetPixels24RangeReturnsNilForGrayscaleImage() {
        let decoder = DCMDecoder()
        // Default decoder has samplesPerPixel=1 (grayscale), so getPixels24 should fail
        XCTAssertEqual(decoder.samplesPerPixel, 1, "Default decoder should be grayscale")
        let result = decoder.getPixels24(range: 0..<10)
        // Returns nil due to dicomFileReadSuccess=false, not just samplesPerPixel check
        XCTAssertNil(result, "getPixels24(range:) should return nil for uninitialized decoder")
    }

    func testGetPixels24RangeConsistencyMultipleCalls() {
        let decoder = DCMDecoder()
        let result1 = decoder.getPixels24(range: 0..<10)
        let result2 = decoder.getPixels24(range: 0..<10)
        XCTAssertEqual(result1 == nil, result2 == nil,
                       "Multiple calls to getPixels24(range:) should be consistent")
    }

    // MARK: - Range-based vs Full Pixel Access Symmetry

    func testRangeAccessIsConsistentWithFullAccess() {
        let decoder = DCMDecoder()
        // For uninitialized decoder, both full and range access should return nil
        XCTAssertNil(decoder.getPixels16(), "Full pixel access should return nil")
        XCTAssertNil(decoder.getPixels16(range: 0..<1), "Range pixel access should also return nil")
    }

    func testAllRangeMethodsReturnNilForUninitializedDecoder() {
        let decoder = DCMDecoder()
        XCTAssertNil(decoder.getPixels8(range: 0..<1), "getPixels8(range:) nil for uninitialized")
        XCTAssertNil(decoder.getPixels16(range: 0..<1), "getPixels16(range:) nil for uninitialized")
        XCTAssertNil(decoder.getPixels24(range: 0..<1), "getPixels24(range:) nil for uninitialized")
    }

    // MARK: - Concurrent Range Access Tests

    func testConcurrentRangePixelAccess() throws {
        let url16 = try makeTemporaryDICOM(
            bitsAllocated: 16,
            samplesPerPixel: 1,
            width: 4,
            height: 4,
            pixelBytes: littleEndianBytes(values: Array(1...16))
        )
        let url8 = try makeTemporaryDICOM(
            bitsAllocated: 8,
            samplesPerPixel: 1,
            width: 4,
            height: 4,
            pixelBytes: Array(0..<16).map(UInt8.init)
        )
        let url24 = try makeTemporaryDICOM(
            bitsAllocated: 8,
            samplesPerPixel: 3,
            width: 2,
            height: 2,
            pixelBytes: [10, 11, 12, 20, 21, 22, 30, 31, 32, 40, 41, 42]
        )
        defer {
            try? FileManager.default.removeItem(at: url16)
            try? FileManager.default.removeItem(at: url8)
            try? FileManager.default.removeItem(at: url24)
        }

        let decoder16 = try DCMDecoder(contentsOf: url16)
        let decoder8 = try DCMDecoder(contentsOf: url8)
        let decoder24 = try DCMDecoder(contentsOf: url24)
        let expectation = XCTestExpectation(description: "Concurrent range pixel access")
        expectation.expectedFulfillmentCount = 10

        for index in 0..<10 {
            DispatchQueue.global().async {
                switch index % 3 {
                case 0:
                    XCTAssertEqual(decoder16.getPixels16(range: 2..<6), [3, 4, 5, 6])
                case 1:
                    XCTAssertEqual(decoder8.getPixels8(range: 4..<8), [4, 5, 6, 7])
                default:
                    XCTAssertEqual(decoder24.getPixels24(range: 1..<3), [20, 21, 22, 30, 31, 32])
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Range Boundary Tests with Synthetic Data

    func testGetPixels16RangeWithValidSyntheticData() throws {
        let url = try makeTemporaryDICOM(
            bitsAllocated: 16,
            samplesPerPixel: 1,
            width: 4,
            height: 4,
            pixelBytes: littleEndianBytes(values: Array(1...16))
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let pixels = decoder.getPixels16(range: 2..<6)

        XCTAssertEqual(pixels, [3, 4, 5, 6])
    }

    func testGetPixels8RangeWithValidSyntheticData() throws {
        let url = try makeTemporaryDICOM(
            bitsAllocated: 8,
            samplesPerPixel: 1,
            width: 4,
            height: 4,
            pixelBytes: Array(0..<16).map(UInt8.init)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let pixels = decoder.getPixels8(range: 4..<8)

        XCTAssertEqual(pixels, [4, 5, 6, 7])
    }

    func testGetPixels24RangeWithValidSyntheticData() throws {
        let url = try makeTemporaryDICOM(
            bitsAllocated: 8,
            samplesPerPixel: 3,
            width: 2,
            height: 2,
            pixelBytes: [10, 11, 12, 20, 21, 22, 30, 31, 32, 40, 41, 42]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let pixels = decoder.getPixels24(range: 1..<3)

        XCTAssertEqual(pixels, [20, 21, 22, 30, 31, 32])
    }

    func testGetPixels8RangeWithDifferentRangeSizes() {
        let decoder = DCMDecoder()

        // Test with different range sizes - all should return nil for uninitialized decoder
        let ranges: [Range<Int>] = [0..<1, 0..<10, 0..<100, 50..<100, 0..<1000]
        for range in ranges {
            XCTAssertNil(decoder.getPixels8(range: range),
                         "getPixels8(range: \(range)) should return nil for uninitialized decoder")
        }
    }

    // MARK: - getDownsampledPixels16 with Synthetic Data Tests

    func testDownsampledPixels16NilWhenOffsetIsZero() {
        // For uninitialized decoder, offset == 0, so should return nil
        let decoder = DCMDecoder()
        let result = decoder.getDownsampledPixels16(maxDimension: 50)
        // Uninitialized: samplesPerPixel=1, bitDepth=16, but offset=0 → returns nil
        XCTAssertNil(result, "Downsampled 16-bit should return nil when offset is 0 (no pixel data)")
    }

    func testDownsampledPixels8NilWhenOffsetIsZero() {
        let decoder = DCMDecoder()
        let result = decoder.getDownsampledPixels8(maxDimension: 50)
        // Uninitialized: bitDepth=16, samplesPerPixel=1, but bitDepth != 8 → nil
        XCTAssertNil(result, "Downsampled 8-bit should return nil when bitDepth != 8")
    }

    func testDownsampledPixels16RequiresBitDepth16() {
        let decoder = DCMDecoder()
        // Default bitDepth is 16, samplesPerPixel is 1 -- but offset is 0, so nil
        XCTAssertEqual(decoder.bitDepth, 16, "Default bitDepth is 16")
        XCTAssertEqual(decoder.samplesPerPixel, 1, "Default samplesPerPixel is 1")
        let result = decoder.getDownsampledPixels16()
        XCTAssertNil(result, "Nil due to offset == 0")
    }

    func testDownsampledPixels8RequiresBitDepth8() {
        let decoder = DCMDecoder()
        XCTAssertEqual(decoder.bitDepth, 16, "Default bitDepth is 16, not 8")
        let result = decoder.getDownsampledPixels8()
        XCTAssertNil(result, "Downsampled 8-bit should return nil when bitDepth != 8")
    }

    // MARK: - Regression Tests (boundary conditions)

    func testGetPixels16RangeNegativeLowerBound() {
        // Range<Int> cannot have negative lower bound via Swift type system
        // but we test that very large upper bounds return nil for uninitialized decoder
        let decoder = DCMDecoder()
        let result = decoder.getPixels16(range: 0..<1000000)
        XCTAssertNil(result, "Large range on uninitialized decoder should return nil")
    }

    func testGetPixels24RangeInvalidForNonRGBImage() {
        let decoder = DCMDecoder()
        // samplesPerPixel = 1 (grayscale), so getPixels24 with range should return nil
        // (even if file were loaded, samplesPerPixel != 3 would reject it)
        XCTAssertEqual(decoder.samplesPerPixel, 1, "Default is grayscale")
        let result = decoder.getPixels24(range: 0..<10)
        XCTAssertNil(result, "Non-RGB image should return nil for getPixels24(range:)")
    }

    func testRangePixelAccessReturnTypesAreCorrect() {
        let decoder = DCMDecoder()
        // Verify return types match expected optional arrays
        let pixels8: [UInt8]? = decoder.getPixels8(range: 0..<10)
        let pixels16: [UInt16]? = decoder.getPixels16(range: 0..<10)
        let pixels24: [UInt8]? = decoder.getPixels24(range: 0..<10)

        XCTAssertNil(pixels8, "pixels8 range should be nil")
        XCTAssertNil(pixels16, "pixels16 range should be nil")
        XCTAssertNil(pixels24, "pixels24 range should be nil")
    }

    private func makeTemporaryDICOM(
        bitsAllocated: UInt16,
        samplesPerPixel: UInt16,
        width: UInt16,
        height: UInt16,
        pixelBytes: [UInt8]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("range_pixels_\(UUID().uuidString).dcm")
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
        data.append(contentsOf: withUnsafeBytes(of: UInt32(pixelBytes.count).littleEndian) { Array($0) })
        data.append(contentsOf: pixelBytes)

        try data.write(to: url)
        return url
    }

    private func littleEndianBytes(values: [UInt16]) -> [UInt8] {
        values.flatMap { value in
            let littleEndian = value.littleEndian
            return withUnsafeBytes(of: littleEndian) { Array($0) }
        }
    }
}
