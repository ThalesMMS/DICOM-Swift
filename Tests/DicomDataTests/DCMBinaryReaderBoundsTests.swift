import DicomData
import Foundation
import XCTest

final class DCMBinaryReaderBoundsTests: XCTestCase {
    func test_signedIntegers_preserveSignAndAdvanceInBothByteOrders() {
        for littleEndian in [true, false] {
            for expected: Int32 in [.min, -1, 0, .max] {
                var encoded = littleEndian ? expected.littleEndian : expected.bigEndian
                let data = withUnsafeBytes(of: &encoded) { Data($0) }
                let reader = DCMBinaryReader(data: data, littleEndian: littleEndian)
                var cursor = 0
                XCTAssertEqual(reader.readInt(location: &cursor), Int(expected))
                XCTAssertEqual(cursor, 4)
            }
        }
    }

    func test_negativeAndOverflowingCursors_doNotReadOrAdvance() {
        let reader = DCMBinaryReader(data: Data([1, 2, 3, 4, 5, 6, 7, 8]), littleEndian: true)
        for initial in [-1, Int.min, Int.max, 9] {
            var cursor = initial
            XCTAssertEqual(reader.readByte(location: &cursor), 0)
            XCTAssertEqual(reader.readShort(location: &cursor), 0)
            XCTAssertEqual(reader.readInt(location: &cursor), 0)
            XCTAssertEqual(reader.readFloat(location: &cursor), 0)
            XCTAssertEqual(reader.readDouble(location: &cursor), 0)
            XCTAssertEqual(reader.readString(length: 2, location: &cursor), "")
            XCTAssertNil(reader.readLUT(length: 2, location: &cursor))
            XCTAssertEqual(cursor, initial)
        }
    }

    func test_invalidLengths_doNotAllocateOrAdvance() {
        let reader = DCMBinaryReader(data: Data([1, 2, 3, 4]), littleEndian: true)
        for length in [Int.min, -2, -1, Int.max, 6] {
            var cursor = 1
            XCTAssertEqual(reader.readString(length: length, location: &cursor), "")
            XCTAssertNil(reader.readLUT(length: length, location: &cursor))
            XCTAssertEqual(cursor, 1)
        }
    }

    func test_nonzeroDataStartIndex_usesLogicalOffsetsAndPreservesEndian() {
        let storage = Data([0xEE, 0xEE, 0x12, 0x34, 0x41, 0x42])
        let slice = storage.dropFirst(2)
        XCTAssertEqual(slice.startIndex, 2)
        let reader = DCMBinaryReader(data: slice, littleEndian: false)
        var cursor = 0
        XCTAssertEqual(reader.readShort(location: &cursor), 0x1234)
        XCTAssertEqual(reader.readString(length: 2, location: &cursor), "AB")
        XCTAssertEqual(cursor, 4)
        cursor = 0
        XCTAssertEqual(reader.readLUT(length: 4, location: &cursor), [0x12, 0x41])
        XCTAssertEqual(cursor, 4)
    }
}
