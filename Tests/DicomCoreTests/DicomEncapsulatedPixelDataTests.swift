import XCTest
@testable import DicomCore

final class DicomEncapsulatedPixelDataTests: XCTestCase {
    @MainActor
    func test_extendedWriter_usesUnpaddedLengthsAndPaddedOffsets() async throws {
        let frames = [Data([1, 2, 3]), Data([4, 0]), Data([5])]
        let encoded = try DicomTranscoder.encapsulate(fragments: frames, forceExtendedOffsets: true)
        XCTAssertEqual(encoded.extendedOffsetTable, uint64Data([0, 12, 22]))
        XCTAssertEqual(encoded.extendedOffsetTableLengths, uint64Data([3, 2, 1]))
        let parser = DicomEncapsulatedPixelDataParser()
        let buffered = try parser.parse(
            data: encoded.pixelData, pixelDataOffset: 0, numberOfFrames: 3,
            extendedOffsetTableData: encoded.extendedOffsetTable,
            extendedOffsetTableLengthsData: encoded.extendedOffsetTableLengths
        )
        let indexed = try await parser.parse(
            source: DicomByteSource(data: encoded.pixelData), pixelDataRange: 0..<encoded.pixelData.count,
            numberOfFrames: 3, transferSyntax: .jpegBaseline,
            extendedOffsetTableData: encoded.extendedOffsetTable,
            extendedOffsetTableLengthsData: encoded.extendedOffsetTableLengths
        )
        XCTAssertTrue(buffered.basicOffsetTable.isEmpty)
        XCTAssertTrue(buffered.diagnostics.isEmpty)
        XCTAssertTrue(indexed.diagnostics.isEmpty)
        XCTAssertEqual(buffered.frameFragmentIndexes, [[0], [1], [2]])
        XCTAssertEqual(indexed.frameFragmentIndexes, buffered.frameFragmentIndexes)
        for (index, stored) in [Data([1, 2, 3, 0]), Data([4, 0]), Data([5, 0])].enumerated() {
            XCTAssertEqual(buffered.frame(index, in: encoded.pixelData)?.data, stored)
        }
    }

    func test_extendedReader_acceptsOnlyNullPaddingOrLegacyStoredLength() throws {
        for (length, pad, warning) in [(UInt64(3), UInt8(0), false), (4, 0, false),
                                        (3, 0xFF, true), (2, 0, true), (5, 0, true)] {
            let bytes = makeEncapsulatedPixelData(basicOffsetTable: [], fragments: [Data([1, 2, 3, pad])])
            let descriptor = try DicomEncapsulatedPixelDataParser().parse(
                data: bytes, pixelDataOffset: 0, numberOfFrames: 1,
                extendedOffsetTableData: uint64Data([0]), extendedOffsetTableLengthsData: uint64Data([length])
            )
            XCTAssertEqual(descriptor.diagnostics.contains { $0.severity == .warning }, warning)
            XCTAssertEqual(descriptor.frame(0, in: bytes)?.data, Data([1, 2, 3, pad]))
        }
    }

    func test_slicedEncapsulation_preservesLogicalFrameOffsets() throws {
        let bytes = makeEncapsulatedPixelData(basicOffsetTable: [0, 10],
                                             fragments: [Data([1, 2]), Data([3, 4])])
        let storage = Data(repeating: 0xCC, count: 19) + bytes
        let slice = storage[19...]
        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: slice, pixelDataOffset: 0, numberOfFrames: 2
        )
        XCTAssertEqual(descriptor.frame(1, in: slice)?.data, Data([3, 4]))
    }

    func testParserMapsFramesFromBasicOffsetTable() throws {
        let first = Data([0x10, 0x11])
        let second = Data([0x20, 0x21])
        let pixelData = makeEncapsulatedPixelData(
            basicOffsetTable: [0, UInt32(itemLength(for: first))],
            fragments: [first, second]
        )

        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: 2
        )

        XCTAssertEqual(descriptor.basicOffsetTable.offsets, [0, UInt32(itemLength(for: first))])
        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0], [1]])
        XCTAssertEqual(descriptor.frame(1, in: pixelData)?.data, second)
    }

    func testParserMapsOneFragmentPerFrameWithoutBasicOffsetTable() throws {
        let first = Data([0x31, 0x32])
        let second = Data([0x41, 0x42])
        let pixelData = makeEncapsulatedPixelData(
            basicOffsetTable: [],
            fragments: [first, second]
        )

        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: 2
        )

        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0], [1]])
        XCTAssertEqual(descriptor.frame(0, in: pixelData)?.data, first)
        XCTAssertTrue(diagnosticText(descriptor).contains("Basic Offset Table is empty"))
    }

    func testParserUsesExtendedOffsetTableForMultiFragmentFrame() throws {
        let firstA = Data([0x51, 0x52])
        let firstB = Data([0x53, 0x54])
        let second = Data([0x61, 0x62])
        let secondFrameOffset = UInt64(itemLength(for: firstA) + itemLength(for: firstB))
        let pixelData = makeEncapsulatedPixelData(
            basicOffsetTable: [],
            fragments: [firstA, firstB, second]
        )

        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: 2,
            extendedOffsetTableData: uint64Data([0, secondFrameOffset]),
            extendedOffsetTableLengthsData: uint64Data([UInt64(firstA.count + firstB.count), UInt64(second.count)])
        )

        XCTAssertEqual(descriptor.extendedOffsetTable?.offsets, [0, secondFrameOffset])
        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0, 1], [2]])
        XCTAssertEqual(descriptor.frame(0, in: pixelData)?.data, firstA + firstB)
        XCTAssertEqual(descriptor.frame(1, in: pixelData)?.data, second)
    }

    func testFrameAssemblesManyFragmentsByteForByte() throws {
        let fragments = (0..<64).map { fragmentIndex in
            Data((0..<257).map { byteIndex in
                UInt8(truncatingIfNeeded: fragmentIndex &+ byteIndex)
            })
        }
        let pixelData = makeEncapsulatedPixelData(basicOffsetTable: [0], fragments: fragments)
        let expected = fragments.reduce(into: Data()) { $0.append($1) }

        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: 1
        )
        let frame = try XCTUnwrap(descriptor.frame(0, in: pixelData))

        XCTAssertEqual(frame.fragmentIndexes, Array(fragments.indices))
        XCTAssertEqual(frame.fragments.map(\.length), fragments.map(\.count))
        XCTAssertEqual(frame.data, expected)
    }

    func testParserReportsInconsistentBasicOffsetTable() throws {
        let first = Data([0x71, 0x72])
        let second = Data([0x81, 0x82])
        let pixelData = makeEncapsulatedPixelData(
            basicOffsetTable: [0],
            fragments: [first, second]
        )

        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: 2
        )

        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0], [1]])
        XCTAssertTrue(diagnosticText(descriptor).contains("Basic Offset Table has 1 entries"))
    }

    func test_largeBasicAndExtendedOffsetTables_mapFramesWithParity() throws {
        let frameCount = 8_192
        let fragments = (0..<frameCount).map { index in
            Data([UInt8(truncatingIfNeeded: index), UInt8(truncatingIfNeeded: index >> 8)])
        }
        let fragmentItemLength = itemLength(for: fragments[0])
        let offsets = (0..<frameCount).map { UInt64($0 * fragmentItemLength) }
        let pixelData = makeEncapsulatedPixelData(
            basicOffsetTable: offsets.map { UInt32($0) },
            fragments: fragments
        )
        let expected = fragments.indices.map { [$0] }

        let basicDescriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: frameCount
        )
        let extendedDescriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: frameCount,
            extendedOffsetTableData: uint64Data(offsets),
            extendedOffsetTableLengthsData: uint64Data(
                Array(repeating: UInt64(fragments[0].count), count: frameCount)
            )
        )

        XCTAssertEqual(basicDescriptor.frameFragmentIndexes, expected)
        XCTAssertEqual(extendedDescriptor.frameFragmentIndexes, expected)
        XCTAssertEqual(extendedDescriptor.frameFragmentIndexes, basicDescriptor.frameFragmentIndexes)
        XCTAssertTrue(basicDescriptor.diagnostics.isEmpty)
        XCTAssertTrue(extendedDescriptor.diagnostics.isEmpty)
    }

    func test_nonIncreasingBasicOffsets_keepDiagnosticAndSafeFallback() throws {
        let fragments = [Data([0x10, 0x11]), Data([0x20, 0x21])]
        let secondOffset = UInt32(itemLength(for: fragments[0]))
        let pixelData = makeEncapsulatedPixelData(
            basicOffsetTable: [secondOffset, 0],
            fragments: fragments
        )

        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: 2
        )

        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0], [1]])
        XCTAssertTrue(diagnosticText(descriptor).contains("Offset table entries must be strictly increasing."))
        XCTAssertTrue(diagnosticText(descriptor).contains("Basic Offset Table has 2 entries for 2 frame(s)."))
    }

    func test_invalidBasicOffset_keepsDiagnosticAndSafeFallback() throws {
        let fragments = [Data([0x10, 0x11]), Data([0x20, 0x21])]
        let pixelData = makeEncapsulatedPixelData(
            basicOffsetTable: [0, 999],
            fragments: fragments
        )

        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: 2
        )

        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0], [1]])
        XCTAssertTrue(diagnosticText(descriptor).contains("Offset table entry 999 does not point to a fragment item."))
        XCTAssertTrue(diagnosticText(descriptor).contains("Basic Offset Table has 2 entries for 2 frame(s)."))
    }

    func test_invalidExtendedOffset_keepsDiagnosticsAndFallsBackToBasicTable() throws {
        let fragments = [Data([0x10, 0x11]), Data([0x20, 0x21])]
        let secondOffset = UInt32(itemLength(for: fragments[0]))
        let pixelData = makeEncapsulatedPixelData(
            basicOffsetTable: [0, secondOffset],
            fragments: fragments
        )

        let descriptor = try DicomEncapsulatedPixelDataParser().parse(
            data: pixelData,
            pixelDataOffset: 0,
            numberOfFrames: 2,
            extendedOffsetTableData: uint64Data([0, 999]),
            extendedOffsetTableLengthsData: uint64Data([2, 2])
        )

        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0], [1]])
        XCTAssertTrue(diagnosticText(descriptor).contains("Offset table entry 999 does not point to a fragment item."))
        XCTAssertTrue(diagnosticText(descriptor).contains("Extended Offset Table does not match 2 frame(s)."))
        XCTAssertFalse(diagnosticText(descriptor).contains("Basic Offset Table has"))
    }

    func testDecoderExposesEncapsulatedFrameWithoutCodecDecode() throws {
        let first = Data([0x91, 0x92])
        let second = Data([0xA1, 0xA2])
        let fileURL = try makeTemporaryCompressedDICOM(
            fragments: [first, second],
            basicOffsetTable: [0, UInt32(itemLength(for: first))]
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let decoder = try DCMDecoder(contentsOf: fileURL)
        let descriptor = try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor)
        let frame = try XCTUnwrap(decoder.getEncapsulatedFrame(1))

        XCTAssertTrue(decoder.compressedImage)
        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0], [1]])
        XCTAssertEqual(frame.fragmentIndexes, [1])
        XCTAssertEqual(frame.data, second)
    }

    private func diagnosticText(_ descriptor: DicomEncapsulatedPixelDataDescriptor) -> String {
        descriptor.diagnostics.map(\.message).joined(separator: "\n")
    }

    private func makeTemporaryCompressedDICOM(
        fragments: [Data],
        basicOffsetTable: [UInt32]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("encapsulated_pixel_data_\(UUID().uuidString).dcm")
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)

        appendElement(tag: DicomTag.transferSyntaxUID.rawValue, vr: "UI", value: ui(DicomTransferSyntax.jpegBaseline.rawValue), to: &data)
        appendElement(tag: DicomTag.samplesPerPixel.rawValue, vr: "US", value: uint16Data(1), to: &data)
        appendElement(tag: DicomTag.photometricInterpretation.rawValue, vr: "CS", value: stringData("MONOCHROME2", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.numberOfFrames.rawValue, vr: "IS", value: stringData("\(fragments.count)", padding: 0x20), to: &data)
        appendElement(tag: DicomTag.rows.rawValue, vr: "US", value: uint16Data(1), to: &data)
        appendElement(tag: DicomTag.columns.rawValue, vr: "US", value: uint16Data(1), to: &data)
        appendElement(tag: DicomTag.bitsAllocated.rawValue, vr: "US", value: uint16Data(8), to: &data)
        appendElement(tag: DicomTag.bitsStored.rawValue, vr: "US", value: uint16Data(8), to: &data)
        appendElement(tag: DicomTag.highBit.rawValue, vr: "US", value: uint16Data(7), to: &data)
        appendElement(tag: DicomTag.pixelRepresentation.rawValue, vr: "US", value: uint16Data(0), to: &data)
        appendPixelData(
            makeEncapsulatedPixelData(basicOffsetTable: basicOffsetTable, fragments: fragments),
            to: &data
        )

        try data.write(to: url)
        return url
    }

    private func makeEncapsulatedPixelData(basicOffsetTable: [UInt32], fragments: [Data]) -> Data {
        var data = Data()
        appendItem(uint32Data(basicOffsetTable), to: &data)
        for fragment in fragments {
            appendItem(fragment, to: &data)
        }
        appendTag(0xFFFEE0DD, to: &data)
        appendUInt32(0, to: &data)
        return data
    }

    private func appendPixelData(_ value: Data, to data: inout Data) {
        appendTag(DicomTag.pixelData.rawValue, to: &data)
        data.append(contentsOf: "OB".utf8)
        data.append(contentsOf: [0x00, 0x00])
        appendUInt32(0xFFFFFFFF, to: &data)
        data.append(value)
    }

    private func appendElement(tag: Int, vr: String, value: Data, to data: inout Data) {
        appendTag(tag, to: &data)
        data.append(contentsOf: vr.utf8)
        if ["OB", "OW", "OV", "SQ", "UN", "UT"].contains(vr) {
            data.append(contentsOf: [0x00, 0x00])
            appendUInt32(UInt32(value.count), to: &data)
        } else {
            appendUInt16(UInt16(value.count), to: &data)
        }
        data.append(value)
    }

    private func appendItem(_ value: Data, to data: inout Data) {
        appendTag(0xFFFEE000, to: &data)
        appendUInt32(UInt32(value.count), to: &data)
        data.append(value)
    }

    private func appendTag(_ tag: Int, to data: inout Data) {
        appendUInt16(UInt16((tag >> 16) & 0xFFFF), to: &data)
        appendUInt16(UInt16(tag & 0xFFFF), to: &data)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func uint16Data(_ value: UInt16) -> Data {
        var data = Data()
        appendUInt16(value, to: &data)
        return data
    }

    private func uint32Data(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in
            appendUInt32(value, to: &data)
        }
    }

    private func uint64Data(_ values: [UInt64]) -> Data {
        values.reduce(into: Data()) { data, value in
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 32) & 0xFF))
            data.append(UInt8((value >> 40) & 0xFF))
            data.append(UInt8((value >> 48) & 0xFF))
            data.append(UInt8((value >> 56) & 0xFF))
        }
    }

    private func ui(_ value: String) -> Data {
        stringData(value, padding: 0x00)
    }

    private func stringData(_ value: String, padding: UInt8) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 != 0 {
            data.append(padding)
        }
        return data
    }

    private func itemLength(for value: Data) -> Int {
        8 + value.count
    }
}
