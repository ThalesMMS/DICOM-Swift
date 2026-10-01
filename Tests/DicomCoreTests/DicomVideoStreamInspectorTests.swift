import Foundation
import XCTest
@testable import DicomCore

final class DicomVideoStreamInspectorTests: XCTestCase {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Video/" + name))
    }

    func test_knownCodecs_reportDimensionsAndPictureOrder() throws {
        for (name, codec) in [("known-pframes.h264", DicomVideoCodec.h264), ("known-bframes.h264", .h264),
                               ("known-high-bframes.h264", .h264), ("known-hevc.hevc", .hevc), ("known-mpeg2.m2v", .mpeg2)] {
            let stream = try Self.fixture(name)
            let value = try DicomVideoStreamInspector.inspect(stream, codec: codec)
            XCTAssertEqual(value.width, 128, name)
            XCTAssertEqual(value.height, 64, name)
            XCTAssertEqual(value.accessUnits.count, 96, name)
            XCTAssertEqual(value.accessUnits.compactMap(\.presentationIndex).sorted(), Array(0..<96), name)
            XCTAssertEqual(value.closedGOP, true, name)
            XCTAssertEqual(value.accessUnits.first?.byteRange.lowerBound, 0)
            XCTAssertEqual(value.accessUnits.last?.byteRange.upperBound, stream.count)
        }
    }

    func test_lengthPrefixes_preserveInspectedPictureOrder() throws {
        let source = try DicomVideoStreamInspector.inspect(Self.fixture("known-bframes.h264"), codec: .h264)
        for width in [4, 2] {
            var stream = Data()
            for unit in source.nalUnits {
                for shift in (0..<width).reversed() { stream.append(UInt8(truncatingIfNeeded: unit.payload.count >> (8 * shift))) }
                stream.append(unit.payload)
            }
            let value = try DicomVideoStreamInspector.inspect(stream, codec: .h264)
            XCTAssertEqual(value.framing, "length-prefixed-\(width)")
            XCTAssertEqual(value.accessUnits.map(\.presentationIndex), source.accessUnits.map(\.presentationIndex))
        }
    }

    func test_AVCCLengthResemblingStartCode_isDetectedAsLengthPrefixed() throws {
        let source = try DicomVideoStreamInspector.inspect(Self.fixture("known-bframes.h264"), codec: .h264)
        var encoded = Data()
        for nal in source.nalUnits where nal.type != 9 {
            var payload = nal.payload
            if nal.type == 7 { payload.append(Data(repeating: 0, count: 256 - payload.count)) }
            var length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
            encoded.append(payload)
        }
        XCTAssertEqual(Array(encoded.prefix(4)), [0, 0, 1, 0])
        let result = try DicomVideoStreamInspector.inspect(encoded, codec: .h264)
        XCTAssertEqual(result.framing, "length-prefixed-4")
        XCTAssertEqual(result.accessUnits.map(\.presentationIndex), source.accessUnits.map(\.presentationIndex))
    }

    func test_truncatedHeaders_refuseWithoutTrapping() throws {
        for codec in [DicomVideoCodec.h264, .hevc, .mpeg2] {
            XCTAssertThrowsError(try DicomVideoStreamInspector.inspect(Data([0, 0, 1, 0x67]), codec: codec))
        }
    }

    func test_overlappingMPEG2StartCodes_refuseWithoutTrapping() {
        XCTAssertThrowsError(try DicomVideoStreamInspector.inspect(Data([0, 0, 1, 0, 0, 1, 0xB3]), codec: .mpeg2)) {
            XCTAssertEqual($0 as? DicomVideoInspectionError, .malformedStream)
        }
    }

    func test_mpeg2_rawGOPHeader_preservesByte03AndFollowingFlags() throws {
        let stream = Data([
            0, 0, 1, 0xB3, 0x08, 0x00, 0x40, 0x13, 0xFF, 0xFF, 0xE0, 0,
            0, 0, 1, 0xB8, 0, 0, 3, 0x40,
            0, 0, 1, 0, 0, 0x08
        ])
        let result = try DicomVideoStreamInspector.inspect(stream, codec: .mpeg2)
        XCTAssertEqual(result.width, 128)
        XCTAssertEqual(result.height, 64)
        XCTAssertEqual(result.closedGOP, true)
        XCTAssertEqual(result.accessUnits.count, 1)
        XCTAssertEqual(result.accessUnits.first?.byteRange, 0..<stream.count)
    }
}
