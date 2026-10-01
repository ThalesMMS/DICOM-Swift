import Foundation
import XCTest
@testable import DicomCodecs

final class DicomJPEGFrameInspectorTests: XCTestCase {
    func test_quantizationTables_rejectZeroEightAndSixteenBitCoefficients() throws {
        for width in [1, 2] {
            var coefficients = Data(repeating: 1, count: 64 * width)
            func stream(_ values: Data) -> Data {
                let table = Data([0xFF, 0xDB, 0, UInt8(3 + values.count), width == 1 ? 0 : 0x10]) + values
                var frame = header(); frame[1] = 0xC1
                var scan = scan(); scan[7] = 0; scan[8] = 63
                return Data([0xFF, 0xD8]) + table + frame + scan + Data([8, 0xFF, 0xD9])
            }
            XCTAssertNoThrow(try DicomJPEGFrameInspector.inspect(stream(coefficients)))
            coefficients.replaceSubrange((63 * width)..<(64 * width), with: Data(repeating: 0, count: width))
            XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(stream(coefficients))) {
                XCTAssertEqual($0 as? DicomJPEGFrameInspector.Failure, .invalidStream)
            }
        }
    }

    func test_segmentPayloadStuffingAndPadding_preserveActualFrameEvidence() throws {
        let stream = Data([0xFF, 0xD8, 0xFF, 0xFE, 0, 6, 0xFF, 0xD9, 0xFF, 0xC1]) + header() + scan() + Data([0xFF, 0, 0xFF, 0xD0, 5, 0xFF, 0xFF, 0xD9, 0])
        let actual = try DicomJPEGFrameInspector.inspect(stream)
        XCTAssertEqual(actual.startOfFrame, 0xC3)
        XCTAssertEqual(actual.precision, 12)
        XCTAssertEqual(actual.width, 3)
        XCTAssertEqual(actual.height, 2)
        XCTAssertEqual(actual.components.map(\.identifier), [1])
        XCTAssertEqual(actual.scans.map(\.predictor), [1])
    }

    func test_allNonInterleavedScans_areInspected() throws {
        let stream = Data([0xFF, 0xD8]) + header(count: 3) + scan(id: 1) + Data([7]) + scan(id: 2, predictor: 7) + Data([8]) + scan(id: 3) + Data([9, 0xFF, 0xD9])
        let actual = try DicomJPEGFrameInspector.inspect(stream)
        XCTAssertEqual(actual.scans.map(\.predictor), [1, 7, 1])
        XCTAssertEqual(actual.components.count, 3)
        XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(Data([0xFF, 0xD8]) + header(count: 3) + scan() + Data([0xFF, 0xD9])))
    }

    func test_truncatedAndContradictoryMarkers_areRejected() {
        let good = Data([0xFF, 0xD8]) + header() + scan() + Data([8, 0xFF, 0xD9])
        for index in 0..<good.count {
            XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(Data(good.prefix(index))), "prefix \(index)")
        }
        let prefix = Data([0xFF, 0xD8]) + header()
        let eoi = Data([0xFF, 0xD9])
        // One pad byte of any value may follow EOI, as GDCM reads it (issue #2852); two may not.
        XCTAssertNoThrow(try DicomJPEGFrameInspector.inspect(good + Data([1])))
        var malformed: [Data] = [good + Data([0, 0]), good + good]
        malformed.append(prefix + header() + scan() + eoi)
        malformed.append(prefix + scan(id: 2) + eoi)
        malformed.append(prefix + scan(predictor: 0) + eoi)
        malformed.append(prefix + scan() + scan() + eoi)
        for bad in malformed {
            XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(bad))
        }
    }

    func test_invalidSOFAndSOSFields_areRejected() {
        let good = Data([0xFF, 0xD8]) + header() + scan() + Data([8, 0xFF, 0xD9])
        for (index, value): (Int, UInt8) in [(6, 1), (11, 0), (13, 0), (14, 1), (18, 7), (20, 2), (21, 1), (23, 1), (24, 12), (24, 16)] {
            var bad = good; bad[index] = value
            XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(bad), "field \(index)")
        }
    }

    func test_sliceIndexesLimitsAndUnsupportedProcesses_doNotTrapOrRepair() throws {
        let good = Data([0xFF, 0xD8]) + header() + scan() + Data([8, 0xFF, 0xD9])
        var sliced = Data([9, 9]) + good; sliced.removeFirst(2)
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(sliced), try DicomJPEGFrameInspector.inspect(good))
        XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(good, maximumEncodedBytes: good.count - 1)) { XCTAssertEqual($0 as? DicomJPEGFrameInspector.Failure, .limitExceeded) }
        // SOF2 is parsed since #2326: a sequential scan (Ss=0, Se=63) under a progressive frame is malformed, not unsupported.
        var progressive = good; progressive[3] = 0xC2
        XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(progressive)) { XCTAssertEqual($0 as? DicomJPEGFrameInspector.Failure, .invalidStream) }
        var arithmetic = good; arithmetic[3] = 0xC9
        XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(arithmetic)) { XCTAssertEqual($0 as? DicomJPEGFrameInspector.Failure, .unsupportedProcess) }
        var dnl = good; dnl[8] = 0
        XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(dnl)) { XCTAssertEqual($0 as? DicomJPEGFrameInspector.Failure, .unsupportedProcess) }
    }

    /// PS3.5 A.4: one pad byte may follow EOI; GE writes 0xFF where others write 0x00 (issue #2487).
    func test_endOfImage_toleratesOneEvenLengthPadByteOfEitherValue() throws {
        let good = Data([0xFF, 0xD8]) + header() + scan() + Data([8, 0xFF, 0xD9])
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(good + Data([0x00])).startOfFrame, 0xC3)
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(good + Data([0xFF])).startOfFrame, 0xC3)
        XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(good + Data([0xFF, 0xFF])), "two bytes are a concatenation, not padding")
        XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(good + Data([0x00, 0x00])))
    }

    private func header(count: UInt8 = 1) -> Data {
        Data([0xFF, 0xC3, 0, 8 + count * 3, 12, 0, 2, 0, 3, count] + (1...count).flatMap { [$0, 0x11, 0] })
    }
    private func scan(id: UInt8 = 1, predictor: UInt8 = 1) -> Data { Data([0xFF, 0xDA, 0, 8, 1, id, 0, predictor, 0, 0]) }
}
