import Foundation
import XCTest
@testable import DicomCodecs

final class DicomRLECodecTests: XCTestCase {
    func test_literalsReplicatesAndPadding_decodeAllPlanes() throws {
        let frame = makeFrame([[2, 1, 2, 3, 254, 4], [254, 0, 2, 5, 6, 7]])
        let result = try DicomRLECodec.inspect(frame, width: 3, height: 2)
        XCTAssertEqual(result.segmentCount, 2)
        XCTAssertFalse(result.runsCrossRowBoundaries)
        XCTAssertFalse(result.literalTriples)
        XCTAssertEqual(try DicomRLECodec.decodeSegments(frame, width: 3, height: 2), [[1, 2, 3, 4, 4, 4], [0, 0, 0, 5, 6, 7]])
        let padded = makeFrame([[1, 7, 8, 0]])
        XCTAssertEqual(try DicomRLECodec.decodeSegments(padded, width: 2, height: 1), [[7, 8]])
        XCTAssertFalse(try DicomRLECodec.inspect(padded, width: 2, height: 1).oddSegmentLength)
        let odd = makeFrame([[1, 7, 8], [0, 9, 0, 10]])
        XCTAssertTrue(try DicomRLECodec.inspect(odd, width: 2, height: 1).oddSegmentLength)
        XCTAssertEqual(try DicomRLECodec.decodeSegments(odd, width: 2, height: 1), [[7, 8], [9, 10]])
    }

    func test_crossRowAndLiteralTriples_remainDecoderAcceptanceButNotEncoderConformance() throws {
        let cross = makeFrame([[3, 1, 2, 3, 4, 0]])
        XCTAssertTrue(try DicomRLECodec.inspect(cross, width: 2, height: 2).runsCrossRowBoundaries)
        XCTAssertEqual(try DicomRLECodec.decodeSegments(cross, width: 2, height: 2), [[1, 2, 3, 4]])
        let triple = makeFrame([[2, 7, 7, 7]])
        XCTAssertTrue(try DicomRLECodec.inspect(triple, width: 3, height: 1).literalTriples)
        let split = makeFrame([[1, 7, 7, 0, 7, 0]])
        XCTAssertTrue(try DicomRLECodec.inspect(split, width: 3, height: 1).literalTriples)
        XCTAssertFalse(try DicomRLECodec.inspect(split, width: 1, height: 3).literalTriples)
    }

    func test_trailingPayload_isNotSilentlyDiscarded() {
        for segment: [UInt8] in [[0, 7, 0, 8], [0, 7, 255, 8], [0, 7, 0, 0]] {
            let frame = makeFrame([segment])
            XCTAssertThrowsError(try DicomRLECodec.inspect(frame, width: 1, height: 1)) { XCTAssertEqual($0 as? DicomRLECodec.Failure, .trailingData) }
            XCTAssertThrowsError(try DicomRLECodec.decodeSegments(frame, width: 1, height: 1))
        }
    }

    func test_noOpsBeforeAndAfterSamples_remainNoOps() throws {
        for segment: [UInt8] in [[128, 0, 7, 0], [0, 7, 128, 128]] {
            XCTAssertEqual(try DicomRLECodec.decodeSegments(makeFrame([segment]), width: 1, height: 1), [[7]])
        }
    }

    func test_invalidHeadersAndPacketLengths_areRejected() {
        let valid = makeFrame([[0, 7]])
        for (offset, value) in [(0, UInt32(0)), (0, 16), (4, 66), (8, 1)] {
            var bad = valid
            bad.replaceSubrange(offset..<(offset + 4), with: withUnsafeBytes(of: value.littleEndian) { Array($0) })
            XCTAssertThrowsError(try DicomRLECodec.inspect(bad, width: 1, height: 1))
        }
        for frame in [Data(valid.prefix(63)), makeFrame([[0]]), makeFrame([[2, 7]]), makeFrame([[255, 7]])] {
            XCTAssertThrowsError(try DicomRLECodec.inspect(frame, width: 1, height: 1))
        }
        XCTAssertThrowsError(try DicomRLECodec.inspect(valid, width: 2, height: 1)) { XCTAssertEqual($0 as? DicomRLECodec.Failure, .decodedLengthMismatch) }
    }

    func test_sliceIndexesAndMaximumPacketLength_areSafe() throws {
        let frame = makeFrame([[127] + Array(UInt8(0)...127) + [0]])
        var slice = Data([9, 9]) + frame
        slice.removeFirst(2)
        XCTAssertEqual(try DicomRLECodec.decodeSegments(slice, width: 128, height: 1), [Array(UInt8(0)...127)])
        XCTAssertEqual(try DicomRLECodec.decodeSegments(makeFrame([[129, 7]]), width: 128, height: 1), [Array(repeating: 7, count: 128)])
    }

    /// Isis issue #2855: an ultrasound encoder drops the last byte of the segment. The decoder can accept a segment
    /// less than one row short, zero-filled as GDCM reads it; inspection and longer gaps stay strict.
    func test_shortSegment_isZeroFilledOnlyWhenAllowedAndWithinARow() throws {
        let short = makeFrame([[2, 7, 8, 9]])
        XCTAssertEqual(try DicomRLECodec.decodeSegments(short, width: 2, height: 2, allowShortSegments: true),
                       [[7, 8, 9, 0]])
        XCTAssertThrowsError(try DicomRLECodec.decodeSegments(short, width: 2, height: 2)) {
            XCTAssertEqual($0 as? DicomRLECodec.Failure, .decodedLengthMismatch)
        }
        XCTAssertThrowsError(try DicomRLECodec.inspect(short, width: 2, height: 2))
        // The last literal run cut off: three of its four bytes are there.
        let cut = makeFrame([[3, 7, 8, 9]])
        XCTAssertEqual(try DicomRLECodec.decodeSegments(cut, width: 2, height: 2, allowShortSegments: true),
                       [[7, 8, 9, 0]])
        XCTAssertThrowsError(try DicomRLECodec.decodeSegments(cut, width: 2, height: 2)) {
            XCTAssertEqual($0 as? DicomRLECodec.Failure, .invalidRun)
        }
        let rowShort = makeFrame([[1, 7, 8]])
        XCTAssertThrowsError(try DicomRLECodec.decodeSegments(rowShort, width: 2, height: 2, allowShortSegments: true))
    }

    func test_inputOutputAndDimensionLimits_precedeMaterialization() {
        let frame = makeFrame([[0, 7]])
        for limits in [DicomRLECodec.Limits(maximumEncodedBytes: 65), .init(maximumDecodedBytes: 0)] {
            XCTAssertThrowsError(try DicomRLECodec.inspect(frame, width: 1, height: 1, limits: limits)) { XCTAssertEqual($0 as? DicomRLECodec.Failure, .limitExceeded) }
            XCTAssertThrowsError(try DicomRLECodec.decodeSegments(frame, width: 1, height: 1, limits: limits))
        }
        XCTAssertThrowsError(try DicomRLECodec.inspect(frame, width: Int.max, height: 2)) { XCTAssertEqual($0 as? DicomRLECodec.Failure, .invalidDimensions) }
    }

    private func makeFrame(_ segments: [[UInt8]]) -> Data {
        var words: [UInt32] = [UInt32(segments.count)]
        var offset = 64
        for segment in segments { words.append(UInt32(offset)); offset += segment.count }
        words += Array(repeating: 0, count: 16 - words.count)
        var data = Data()
        for word in words { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } }
        for segment in segments { data.append(contentsOf: segment) }
        return data
    }
}
