import XCTest

@testable import DicomCore

final class DCMTagParserTests: XCTestCase {
    func testGetNextTagPreservesLegitimateThirteenByteValueLength() {
        let data = Data([
            0x10, 0x00, 0x10, 0x00,
            0x4C, 0x4F, 0x0D, 0x00
        ]) + Data(repeating: 0x41, count: 13)
        let reader = DCMBinaryReader(data: data, littleEndian: true)
        let parser = DCMTagParser(data: data, dict: DCMDictionary(), binaryReader: reader)
        var offset = 0
        var littleEndian = true

        let tag = parser.getNextTag(
            location: &offset,
            data: data,
            littleEndian: &littleEndian,
            bigEndianTransferSyntax: false,
            explicitVR: true
        )

        XCTAssertEqual(tag, DicomTag.patientName.rawValue)
        XCTAssertEqual(parser.elementLength, 13)
        XCTAssertEqual(offset, 8)
    }
}
