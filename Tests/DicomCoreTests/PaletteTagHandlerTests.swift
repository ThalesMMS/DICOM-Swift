import XCTest
@testable import DicomCore

final class PaletteTagHandlerTests: XCTestCase {
    func test_oversizedSegmentedPalette_rejectsPayloadAndPreservesNextTag() throws {
        let words: [UInt16] = [0, 1, 7, 2, 1, 0, 0, 2, 1, 0, 0]
        XCTAssertNil(try readPalette(words: words, storedEntryCount: 2))
    }

    func test_indirectPaletteNearEncodedLimit_preservesAllEntries() throws {
        for storedEntryCount in [4, 0] {
            let entryCount = storedEntryCount == 0 ? 65_536 : storedEntryCount
            var words: [UInt16] = [0, 1, 0xABCD]
            for _ in 1..<entryCount {
                words.append(contentsOf: [2, 1, 0, 0])
            }
            XCTAssertEqual(try readPalette(words: words, storedEntryCount: storedEntryCount),
                           [UInt8](repeating: 0xAB, count: entryCount))
        }
    }

    private func readPalette(
        words: [UInt16], storedEntryCount: Int, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [UInt8]? {
        let payload = words.map(\.littleEndian).withUnsafeBytes { Data($0) }
        var data = Data([0x28, 0x00, 0x21, 0x12, 0x4F, 0x57, 0x00, 0x00])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        let nextTagOffset = data.count
        data.append(contentsOf: [0x28, 0x00, 0x10, 0x00, 0x55, 0x53, 0x02, 0x00, 0x07, 0x00])
        let reader = DCMBinaryReader(data: data, littleEndian: true)
        let parser = DCMTagParser(data: data, dict: DCMDictionary(), binaryReader: reader)
        let context = DecoderContext()
        context.redPaletteDescriptor = try XCTUnwrap(DicomLUTDescriptor(
            storedEntryCount: storedEntryCount, firstMappedValue: 0, bitsPerEntry: 16
        ), file: file, line: line)
        var offset = 0
        var littleEndian = true
        let tag = parser.getNextTag(
            location: &offset, data: data, littleEndian: &littleEndian,
            bigEndianTransferSyntax: false, explicitVR: true
        )
        XCTAssertEqual(tag, DicomTag.segmentedRedPalette.rawValue, file: file, line: line)
        XCTAssertTrue(PaletteTagHandler().handle(
            tag: tag, reader: reader, location: &offset, parser: parser, context: context,
            addInfo: { _, _ in }, addInfoInt: { _, _ in }
        ), file: file, line: line)
        XCTAssertEqual(offset, nextTagOffset, file: file, line: line)
        XCTAssertEqual(parser.getNextTag(
            location: &offset, data: data, littleEndian: &littleEndian,
            bigEndianTransferSyntax: false, explicitVR: true
        ), DicomTag.rows.rawValue, file: file, line: line)
        XCTAssertEqual(reader.readShort(location: &offset), 7, file: file, line: line)
        return context.reds
    }
}
