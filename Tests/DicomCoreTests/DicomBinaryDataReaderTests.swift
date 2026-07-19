import Foundation
import XCTest
@testable import DicomCore

final class DicomBinaryDataReaderTests: XCTestCase {
    func test_unalignedLittleEndianIntegerData_rejectsTrailingBytes() {
        let storage = Data([0xFF, 0x34, 0x12, 0x78, 0x56, 0xAA])
        let unaligned = storage[1...]

        XCTAssertEqual(
            unaligned.dicomIntegerValues(as: UInt16.self, littleEndian: true),
            []
        )
    }

    func test_bigEndianIntegerData_decodesValues() {
        let data = Data([0x12, 0x34, 0x56, 0x78])

        XCTAssertEqual(
            data.dicomIntegerValues(as: UInt16.self, littleEndian: false),
            [0x1234, 0x5678]
        )
    }

    func test_bothFloatingPointWidths_decodesValues() {
        var floatBits = Float(12.5).bitPattern.littleEndian
        var doubleBits = Double(-42.25).bitPattern.bigEndian
        let floatData = withUnsafeBytes(of: &floatBits) { Data($0) }
        let doubleData = withUnsafeBytes(of: &doubleBits) { Data($0) }

        XCTAssertEqual(floatData.dicomFloat32Values(littleEndian: true), [12.5])
        XCTAssertEqual(doubleData.dicomFloat64Values(littleEndian: false), [-42.25])
    }
}
