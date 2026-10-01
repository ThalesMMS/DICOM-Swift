import XCTest
@testable import DicomCore
import Foundation

final class DCMDecoderSecurityTests: XCTestCase {

    // MARK: - Properties

    private var tempDirectory: URL!

    // MARK: - Setup & Teardown

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DCMSecurityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory, FileManager.default.fileExists(atPath: tempDirectory.path) {
            try FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Excessive Element Length Tests

    func test_excessiveElementLength_rejectsBeforeMaterializingPayload() throws {
        let filePath = try createDICOMWithLargeLength(length: 150 * 1024 * 1024)
        let data = try dataSetBytes(from: filePath)

        XCTAssertLessThan(data.count, 1_024, "The fixture must not materialize its claimed payload")
        assertSequenceParseError(
            .elementExceedsBounds(0x0029_1000),
            parsing: data
        )
    }

    func test_multipleExcessiveElements_rejectsFirstOutOfBoundsElement() throws {
        let filePath = try createDICOMWithMultipleLargeElements()
        let data = try dataSetBytes(from: filePath)

        XCTAssertLessThan(data.count, 1_024, "The fixture must contain headers, not large values")
        assertSequenceParseError(
            .elementExceedsBounds(0x0029_1000),
            parsing: data
        )
    }

    func test_undefinedLengthMarkerWithoutSequenceDelimiter_throwsTypedError() throws {
        let filePath = try createDICOMWithUndefinedSequenceLengthNoDelimiter()

        assertSequenceParseError(
            .missingSequenceDelimiter,
            parsing: try dataSetBytes(from: filePath)
        )
    }

    // MARK: - Huge Image Dimension Tests

    func test_pixelBufferAtMaximum_acceptsHeaderAndKeepsPixelsLazy() throws {
        let filePath = try createDICOMWithDimensions(width: 32_768, height: 32_768)

        let decoder = try DCMDecoder(contentsOf: filePath)

        XCTAssertEqual(decoder.width, 32_768)
        XCTAssertEqual(decoder.height, 32_768)
        XCTAssertEqual(
            Int64(decoder.width) * Int64(decoder.height) * Int64(decoder.bitDepth / 8),
            DCMDecoder.maxPixelBufferSize
        )
        XCTAssertTrue(decoder.pixelsNotLoaded, "Header validation must leave the pixel payload lazy")
        XCTAssertNil(decoder.pixels8)
        XCTAssertNil(decoder.pixels16)
        XCTAssertNil(decoder.pixels24)
        XCTAssertLessThan(
            try Data(contentsOf: filePath).count,
            1_024,
            "Header validation must not require materializing the 2 GiB boundary buffer"
        )
    }

    func test_maximumUInt16ImageDimensions_rejectsExcessivePixelBudget() throws {
        let filePath = try createDICOMWithDimensions(width: .max, height: .max)

        assertInvalidDICOMFormat(at: filePath)
    }

    func test_pixelBufferAboveMaximum_rejectsWithoutIntegerOverflow() throws {
        let filePath = try createDICOMWithDimensions(width: 32_769, height: 32_769)

        assertInvalidDICOMFormat(at: filePath)
    }

    // MARK: - Memory Bomb Tests

    func test_memoryBombPixelBuffer_rejectsStructuralAndLazyDecode() throws {
        let filePath = try createDICOMWithClaimedPixelData(claimedSize: 1_000_000_000)

        assertSequenceParseError(
            .elementExceedsBounds(DicomTag.pixelData.rawValue),
            parsing: try dataSetBytes(from: filePath)
        )

        let decoder = try DCMDecoder(contentsOf: filePath)

        XCTAssertTrue(decoder.pixelsNotLoaded, "Initialization must not decode the claimed pixel payload")
        XCTAssertNil(decoder.getPixels16(), "A truncated claimed payload must be rejected lazily")
    }

    func test_pixelDataSizeMismatch_doesNotProducePartialImage() throws {
        let shortFilePath = try createDICOMWithPixelData(byteCount: 1_000)
        let shortDecoder = try DCMDecoder(contentsOf: shortFilePath)

        XCTAssertEqual(shortDecoder.width * shortDecoder.height, 10_000)
        XCTAssertTrue(shortDecoder.pixelsNotLoaded, "Initialization must leave the short payload lazy")
        XCTAssertNil(shortDecoder.getPixels16(), "A short native payload must not produce a partial image")

        let completeFilePath = try createDICOMWithPixelData(byteCount: 20_000)
        let completeDecoder = try DCMDecoder(contentsOf: completeFilePath)
        let completePixels = try XCTUnwrap(completeDecoder.getPixels16())

        XCTAssertEqual(completePixels.count, 10_000, "A complete payload must still decode every declared pixel")
    }

    func test_24BitRGBMemoryBomb_rejectsFirstSizeAbovePixelBudget() throws {
        let acceptedFilePath = try createDICOMWithDimensions(
            width: 26_754,
            height: 26_754,
            bitDepth: 8,
            samplesPerPixel: 3
        )
        let acceptedDecoder = try DCMDecoder(contentsOf: acceptedFilePath)

        XCTAssertTrue(acceptedDecoder.pixelsNotLoaded)
        XCTAssertLessThan(
            Int64(acceptedDecoder.width) * Int64(acceptedDecoder.height) * 3,
            DCMDecoder.maxPixelBufferSize
        )

        let rejectedFilePath = try createDICOMWithDimensions(
            width: 26_755,
            height: 26_755,
            bitDepth: 8,
            samplesPerPixel: 3
        )

        assertInvalidDICOMFormat(at: rejectedFilePath)
    }

    // MARK: - Deeply Nested Sequence Tests

    func test_deeplyNestedSequences_aboveDefaultLimitThrowsTypedError() throws {
        let limit = DicomDataSetParseLimits.default.maximumSequenceDepth
        let filePath = try createDICOMWithDeepSequences(depth: limit + 1)
        let data = try dataSetBytes(from: filePath)

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data)) { error in
            XCTAssertEqual(
                error as? DicomDataSetParseError,
                .maximumSequenceDepthExceeded(limit: limit)
            )
        }
    }

    func test_undefinedLengthItemWithoutDelimiter_throwsTypedError() throws {
        let filePath = try createDICOMWithMissingItemDelimiter()

        assertSequenceParseError(
            .missingItemDelimiter,
            parsing: try dataSetBytes(from: filePath)
        )
    }

    func test_sequenceDepthAtDefaultLimit_parsesCompleteStructure() throws {
        let limit = DicomDataSetParseLimits.default.maximumSequenceDepth
        let filePath = try createDICOMWithDeepSequences(depth: limit)
        var dataSet = try DicomDataSetParser.dataSet(from: dataSetBytes(from: filePath))

        for depth in 0..<limit {
            let group = 0x0040 + (depth % 256)
            let items = dataSet.sequenceItems(for: group << 16 | 0x0100)
            XCTAssertEqual(items.count, 1, "Expected one item at nesting depth \(depth + 1)")
            dataSet = try XCTUnwrap(items.first).dataSet
        }
        XCTAssertTrue(dataSet.isEmpty, "The innermost item should contain no trailing elements")
    }

    // MARK: - Integer Overflow Prevention Tests

    func test_maximumHeaderValues_rejectWithoutArithmeticTrap() throws {
        let filePath = try createDICOMWithDimensions(
            width: .max,
            height: .max,
            bitDepth: .max,
            samplesPerPixel: .max
        )

        assertInvalidDICOMFormat(at: filePath)
    }

    func test_bytesPerPixelBudget_rejectsExcessiveAllocation() throws {
        let filePath = try createDICOMWithDimensions(width: 40_000, height: 40_000, bitDepth: 16)

        assertInvalidDICOMFormat(at: filePath)
    }

    func test_samplesPerPixelBudget_rejectsFirstSizeAboveMaximum() throws {
        let acceptedFilePath = try createDICOMWithDimensions(
            width: 18_918,
            height: 18_918,
            bitDepth: 16,
            samplesPerPixel: 3
        )
        let acceptedDecoder = try DCMDecoder(contentsOf: acceptedFilePath)

        XCTAssertTrue(acceptedDecoder.pixelsNotLoaded)
        XCTAssertLessThan(
            Int64(acceptedDecoder.width) * Int64(acceptedDecoder.height) * 6,
            DCMDecoder.maxPixelBufferSize
        )

        let rejectedFilePath = try createDICOMWithDimensions(
            width: 18_919,
            height: 18_919,
            bitDepth: 16,
            samplesPerPixel: 3
        )

        assertInvalidDICOMFormat(at: rejectedFilePath)
    }

    // MARK: - Undefined Length Handling Tests

    func test_undefinedLengthSequenceWithDelimiter_parsesOneItem() throws {
        let filePath = try createDICOMWithUndefinedLength()
        let dataSet = try DicomDataSetParser.dataSet(from: dataSetBytes(from: filePath))

        XCTAssertEqual(dataSet.sequenceItems(for: 0x0040_0100).count, 1)
    }

    func test_undefinedLengthSequenceWithoutDelimiter_throwsTypedError() throws {
        let filePath = try createDICOMWithUndefinedLengthNoDelimiter()

        assertSequenceParseError(
            .missingSequenceDelimiter,
            parsing: try dataSetBytes(from: filePath)
        )
    }

    func test_mixedUndefinedAndExplicitLengths_parseBothSequences() throws {
        let filePath = try createDICOMWithMixedLengths()
        let dataSet = try DicomDataSetParser.dataSet(from: dataSetBytes(from: filePath))

        XCTAssertEqual(dataSet.sequenceItems(for: 0x0040_0100).count, 1)
        XCTAssertEqual(dataSet.sequenceItems(for: 0x0040_0101).count, 1)
    }

    // MARK: - Combined Attack Scenarios

    func test_combinedAttack_rejectsFirstOutOfBoundsElement() throws {
        let filePath = try createMaliciousDICOM()

        assertSequenceParseError(
            .elementExceedsBounds(0x0029_1000),
            parsing: try dataSetBytes(from: filePath)
        )
    }

    func test_truncatedPixelData_doesNotProducePartialImage() throws {
        let filePath = try createTruncatedDICOM()
        let decoder = try DCMDecoder(contentsOf: filePath)

        XCTAssertTrue(decoder.pixelsNotLoaded, "Initialization must leave the truncated payload lazy")
        XCTAssertNil(decoder.getPixels16(), "A truncated payload must not produce partially initialized pixels")
    }

    // MARK: - Assertions

    private func assertInvalidDICOMFormat(
        at filePath: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try DCMDecoder(contentsOf: filePath), file: file, line: line) { error in
            guard case DICOMError.invalidDICOMFormat = error else {
                return XCTFail("Expected invalidDICOMFormat, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertSequenceParseError(
        _ expected: DicomSequenceValueParserError,
        parsing data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data), file: file, line: line) { error in
            XCTAssertEqual(error as? DicomSequenceValueParserError, expected, file: file, line: line)
        }
    }

    private func dataSetBytes(from filePath: URL) throws -> Data {
        let part10Data = try Data(contentsOf: filePath)
        guard part10Data.count >= 132 else {
            throw DICOMError.invalidDICOMFormat(reason: "Security fixture is missing the Part 10 preamble")
        }
        return Data(part10Data.dropFirst(132))
    }

    // MARK: - Test Utilities

    /// Creates a minimal valid DICOM file with a large element length
    private func createDICOMWithLargeLength(length: UInt32) throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("large_length.dcm")
        var data = Data()

        // DICOM preamble (128 bytes of zeros)
        data.append(Data(count: 128))

        // DICM prefix
        data.append(contentsOf: "DICM".utf8)

        // Meta Information Group Length (0002,0000)
        data.append(contentsOf: [0x02, 0x00, 0x00, 0x00])  // Tag
        data.append(contentsOf: "UL".utf8)  // VR
        data.append(contentsOf: [0x04, 0x00])  // Length
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // Value

        // Create a tag with excessive length
        // Private data element (0029,1000) encoded as UN with a 32-bit length.
        data.append(contentsOf: [0x29, 0x00, 0x00, 0x10])  // Tag
        data.append(contentsOf: "UN".utf8)  // VR

        // Length (little endian)
        let lengthBytes = withUnsafeBytes(of: length.littleEndian) { Data($0) }
        data.append(contentsOf: [0x00, 0x00])  // Reserved
        data.append(lengthBytes)

        // Don't include actual data - just claim the length

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates DICOM with multiple elements claiming large lengths
    private func createDICOMWithMultipleLargeElements() throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("multiple_large.dcm")
        var data = Data()

        // DICOM preamble and prefix
        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Add multiple elements with excessive lengths
        for i in 0..<5 {
            let group = UInt16(0x0029 + i * 2)
            data.append(contentsOf: [UInt8(group & 0xFF), UInt8(group >> 8), 0x00, 0x10])
            data.append(contentsOf: "UN".utf8)
            data.append(contentsOf: [0x00, 0x00])

            let largeLength: UInt32 = 50 * 1024 * 1024  // 50 MB each
            let lengthBytes = withUnsafeBytes(of: largeLength.littleEndian) { Data($0) }
            data.append(lengthBytes)
        }

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates a sequence with a legal undefined-length marker but no required delimiter.
    private func createDICOMWithUndefinedSequenceLengthNoDelimiter() throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("undefined_sequence_length.dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Tag with 0xFFFFFFFF length (undefined length)
        data.append(contentsOf: [0x29, 0x00, 0x00, 0x10])
        data.append(contentsOf: "SQ".utf8)  // Sequence VR
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // Undefined length

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates DICOM with specified dimensions
    private func createDICOMWithDimensions(width: UInt16, height: UInt16,
                                           bitDepth: UInt16 = 16,
                                           samplesPerPixel: UInt16 = 1) throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("dimensions_\(width)x\(height).dcm")
        var data = Data()

        // DICOM preamble and prefix
        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Columns (0028,0011) - Width
        data.append(contentsOf: [0x28, 0x00, 0x11, 0x00])
        data.append(contentsOf: "US".utf8)  // Unsigned Short
        data.append(contentsOf: [0x02, 0x00])  // Length = 2
        let widthBytes = withUnsafeBytes(of: width.littleEndian) { Data($0) }
        data.append(widthBytes)

        // Rows (0028,0010) - Height
        data.append(contentsOf: [0x28, 0x00, 0x10, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        let heightBytes = withUnsafeBytes(of: height.littleEndian) { Data($0) }
        data.append(heightBytes)

        // Bits Allocated (0028,0100)
        data.append(contentsOf: [0x28, 0x00, 0x00, 0x01])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        let bitDepthBytes = withUnsafeBytes(of: bitDepth.littleEndian) { Data($0) }
        data.append(bitDepthBytes)

        // Samples Per Pixel (0028,0002)
        data.append(contentsOf: [0x28, 0x00, 0x02, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        let samplesBytes = withUnsafeBytes(of: samplesPerPixel.littleEndian) { Data($0) }
        data.append(samplesBytes)

        // Pixel Data (7FE0,0010), with a two-byte sentinel so the decoder reaches
        // the lazy pixel handler without materializing the declared image buffer.
        data.append(contentsOf: [0xE0, 0x7F, 0x10, 0x00])
        data.append(contentsOf: "OW".utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x02, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00])

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates DICOM claiming pixel data without providing it
    private func createDICOMWithClaimedPixelData(claimedSize: UInt32) throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("claimed_pixels.dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Small valid dimensions
        data.append(contentsOf: [0x28, 0x00, 0x11, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: [0x00, 0x01])  // Width = 256

        data.append(contentsOf: [0x28, 0x00, 0x10, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: [0x00, 0x01])  // Height = 256

        // Pixel Data (7FE0,0010) with excessive claimed length
        data.append(contentsOf: [0xE0, 0x7F, 0x10, 0x00])
        data.append(contentsOf: "OW".utf8)
        data.append(contentsOf: [0x00, 0x00])
        let lengthBytes = withUnsafeBytes(of: claimedSize.littleEndian) { Data($0) }
        data.append(lengthBytes)

        // Include only a two-byte sentinel so the lazy pixel handler is reached.
        data.append(contentsOf: [0x00, 0x00])

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates DICOM with a configurable native pixel payload for 100x100 16-bit pixels.
    private func createDICOMWithPixelData(byteCount: Int) throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("pixels_\(byteCount).dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Claim 100x100 pixels
        data.append(contentsOf: [0x28, 0x00, 0x11, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: [0x64, 0x00])  // Width = 100

        data.append(contentsOf: [0x28, 0x00, 0x10, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: [0x64, 0x00])  // Height = 100

        data.append(contentsOf: [0x28, 0x00, 0x00, 0x01])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: [0x10, 0x00])  // 16 bits

        // Pixel Data
        data.append(contentsOf: [0xE0, 0x7F, 0x10, 0x00])
        data.append(contentsOf: "OW".utf8)
        data.append(contentsOf: [0x00, 0x00])
        let lengthBytes = withUnsafeBytes(of: UInt32(byteCount).littleEndian) { Data($0) }
        data.append(lengthBytes)
        data.append(Data(count: byteCount))

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates DICOM with deeply nested sequences
    private func createDICOMWithDeepSequences(depth: Int) throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("deep_sequences_\(depth).dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Create nested sequences
        for i in 0..<depth {
            let tag = UInt16(0x0040 + (i % 256))
            data.append(contentsOf: [UInt8(tag & 0xFF), UInt8(tag >> 8), 0x00, 0x01])
            data.append(contentsOf: "SQ".utf8)
            data.append(contentsOf: [0x00, 0x00])
            data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // Undefined length

            // Item tag
            data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
            data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // Undefined length
        }

        // Close all sequences
        for _ in 0..<depth {
            // Item delimiter
            data.append(contentsOf: [0xFE, 0xFF, 0x0D, 0xE0])
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

            // Sequence delimiter
            data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0])
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        }

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates an undefined-length sequence item that ends before its item delimiter.
    private func createDICOMWithMissingItemDelimiter() throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("missing_item_delimiter.dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Create sequence with undefined length and no proper termination
        data.append(contentsOf: [0x40, 0x00, 0x00, 0x01])
        data.append(contentsOf: "SQ".utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])

        // Item without proper delimiter
        data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])

        // No sequence delimiter - file just ends

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates DICOM with undefined length sequence
    private func createDICOMWithUndefinedLength() throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("undefined_length.dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Sequence with undefined length
        data.append(contentsOf: [0x40, 0x00, 0x00, 0x01])
        data.append(contentsOf: "SQ".utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])

        // Empty item with explicit length
        data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Proper sequence delimiter
        data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates DICOM with undefined length but no delimiter
    private func createDICOMWithUndefinedLengthNoDelimiter() throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("undefined_no_delimiter.dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Sequence with undefined length
        data.append(contentsOf: [0x40, 0x00, 0x00, 0x01])
        data.append(contentsOf: "SQ".utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])

        // Empty item with explicit length, leaving only the sequence delimiter missing
        data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // No delimiter - file just ends

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates DICOM with mixed length encoding
    private func createDICOMWithMixedLengths() throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("mixed_lengths.dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Explicit length sequence
        data.append(contentsOf: [0x40, 0x00, 0x00, 0x01])
        data.append(contentsOf: "SQ".utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x08, 0x00, 0x00, 0x00])  // 8-byte empty item

        // Item with explicit length
        data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Another sequence with undefined length
        data.append(contentsOf: [0x40, 0x00, 0x01, 0x01])
        data.append(contentsOf: "SQ".utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])

        // Empty item with explicit length
        data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        // Delimiter
        data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates a DICOM dataset combining excessive dimensions and an out-of-bounds private value.
    private func createMaliciousDICOM() throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("malicious.dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Attack 1: Excessive dimensions
        data.append(contentsOf: [0x28, 0x00, 0x11, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: [0xFF, 0xFF])  // Width = 65535

        data.append(contentsOf: [0x28, 0x00, 0x10, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: [0xFF, 0xFF])  // Height = 65535

        // Attack 2: Large element length
        data.append(contentsOf: [0x29, 0x00, 0x00, 0x10])
        data.append(contentsOf: "UN".utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x10])  // 256 MB

        try data.write(to: fileURL)
        return fileURL
    }

    /// Creates truncated DICOM file
    private func createTruncatedDICOM() throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent("truncated.dcm")
        var data = Data()

        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        // Claim dimensions
        data.append(contentsOf: [0x28, 0x00, 0x11, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: [0x00, 0x02])  // 512

        data.append(contentsOf: [0x28, 0x00, 0x10, 0x00])
        data.append(contentsOf: "US".utf8)
        data.append(contentsOf: [0x02, 0x00])
        data.append(contentsOf: [0x00, 0x02])  // 512

        // Pixel data tag claiming large size
        data.append(contentsOf: [0xE0, 0x7F, 0x10, 0x00])
        data.append(contentsOf: "OW".utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00, 0x08, 0x00])  // Claim 512KB

        // But only write 100 bytes
        data.append(Data(count: 100))

        try data.write(to: fileURL)
        return fileURL
    }
}
