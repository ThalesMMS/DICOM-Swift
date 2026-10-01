import Foundation
import XCTest
@testable import HL7MLLP

final class MLLPDeframerLimitsTests: XCTestCase {
    func test_messageLimit_abortsBeforeAppendAndRecoversAtTrailer() throws {
        var limits = MLLPLimits()
        limits.maxMessageBytes = 2
        limits.recovery = .resynchronize
        var parser = MLLPDeframer(limits: limits)
        var frames: [MLLPFrame] = []
        for byte: UInt8 in [11, 65, 66, 67, 68, 28, 13, 11, 90, 28, 13] {
            frames += try parser.feed(Data([byte]))
            XCTAssertLessThanOrEqual(parser.bufferedBytes, 2)
        }
        XCTAssertEqual(frames.map(\.payload), [Data([90])])
        XCTAssertEqual(frames.first?.diagnostics, [.resynchronized(dropped: 7)])
        XCTAssertEqual(parser.losses, [MLLPLoss(droppedBytes: 7, reason: .messageLimit, byteOffset: 0)])
    }

    func test_messageLimit_strictErrorIncludesOffsetAndIsTerminal() throws {
        var limits = MLLPLimits()
        limits.maxMessageBytes = 2
        var parser = MLLPDeframer(limits: limits)
        _ = try parser.feed(Data([11, 65, 66]))
        XCTAssertThrowsError(try parser.feed(Data([67]))) {
            XCTAssertEqual(($0 as? MLLPFramingError)?.reason, .messageLimit)
            XCTAssertEqual(($0 as? MLLPFramingError)?.byteOffset, 3)
        }
        XCTAssertEqual(parser.bufferedBytes, 0)
        XCTAssertThrowsError(try parser.feed(Data([11, 28, 13])))
        XCTAssertThrowsError(try parser.finish())
    }

    func test_totalBufferLimit_includesReturnedFramesWithinFeed() throws {
        var limits = MLLPLimits()
        limits.maxBufferedBytes = 3
        var parser = MLLPDeframer(limits: limits)
        XCTAssertThrowsError(try parser.feed(Data([11, 65, 66, 28, 13, 11, 67, 68]))) {
            XCTAssertEqual(($0 as? MLLPFramingError)?.reason, .bufferLimit)
            XCTAssertEqual(($0 as? MLLPFramingError)?.byteOffset, 7)
        }
        XCTAssertLessThanOrEqual(parser.bufferedBytes, 3)
    }

    func test_totalBufferLimit_partialNeverExceedsCap() throws {
        var limits = MLLPLimits()
        limits.maxBufferedBytes = 2
        limits.recovery = .resynchronize
        var parser = MLLPDeframer(limits: limits)
        for byte: UInt8 in [11, 65, 66, 67, 68, 28, 13] {
            _ = try parser.feed(Data([byte]))
            XCTAssertLessThanOrEqual(parser.bufferedBytes, 2)
        }
        XCTAssertEqual(try parser.finish().losses.first?.reason, .bufferLimit)
    }

    func test_invalidFraming_strictThrowsWithOffsets() {
        for (wire, reason, offset) in [(Data([11, 65, 11]), MLLPLossReason.unexpectedStartBlock, 2),
                                       (Data([11, 65, 28, 66]), .invalidTrailer, 3)] {
            var parser = MLLPDeframer()
            XCTAssertThrowsError(try parser.feed(wire)) {
                XCTAssertEqual(($0 as? MLLPFramingError)?.reason, reason)
                XCTAssertEqual(($0 as? MLLPFramingError)?.byteOffset, offset)
            }
        }
    }

    func test_resynchronize_everySplitPreservesLossAndNextFrame() throws {
        for bad in [Data([11, 65]), Data([11, 65, 28]), Data([11, 65, 28, 66, 28, 13])] {
            let wire = bad + Data([11, 90, 28, 13])
            for split in 0...wire.count {
                var limits = MLLPLimits()
                limits.recovery = .resynchronize
                var parser = MLLPDeframer(limits: limits)
                let frames = try parser.feed(wire.prefix(split)) + parser.feed(wire.dropFirst(split))
                XCTAssertEqual(frames.map(\.payload), [Data([90])])
                XCTAssertEqual(frames.first?.byteOffset, bad.count)
                XCTAssertEqual(frames.first?.diagnostics, [.resynchronized(dropped: bad.count)])
                XCTAssertEqual(try parser.finish().losses.first?.droppedBytes, bad.count)
            }
        }
    }

    func test_limitRecovery_newSBStartsFrame() throws {
        var limits = MLLPLimits()
        limits.maxMessageBytes = 1
        limits.recovery = .resynchronize
        var parser = MLLPDeframer(limits: limits)
        let frames = try parser.feed(Data([11, 65, 66, 67, 11, 90, 28, 13]))
        XCTAssertEqual(frames.first?.payload, Data([90]))
        XCTAssertEqual(parser.droppedBytes, 4)
    }

    func test_finish_partialAndIncompleteTrailerNeverAccepted() throws {
        for wire in [Data([11]), Data([11, 65]), Data([11, 65, 28])] {
            var strict = MLLPDeframer()
            _ = try strict.feed(wire)
            XCTAssertThrowsError(try strict.finish()) {
                XCTAssertEqual(($0 as? MLLPFramingError)?.reason, .incompleteBlock)
                XCTAssertEqual(($0 as? MLLPFramingError)?.byteOffset, wire.count)
            }
            var limits = MLLPLimits()
            limits.recovery = .resynchronize
            var recovering = MLLPDeframer(limits: limits)
            _ = try recovering.feed(wire)
            let report = try recovering.finish()
            XCTAssertEqual(report.losses, [MLLPLoss(droppedBytes: wire.count, reason: .incompleteBlock, byteOffset: 0)])
            XCTAssertEqual(try recovering.finish(), report)
            XCTAssertEqual(recovering.bufferedBytes, 0)
        }
    }

    func test_repeatedLosses_coalescedAndDiscardAtEOFFinalized() throws {
        var limits = MLLPLimits()
        limits.recovery = .resynchronize
        limits.maxMessageBytes = 0
        var parser = MLLPDeframer(limits: limits)
        for _ in 0..<100 { _ = try parser.feed(Data([11, 65, 28, 13])) }
        _ = try parser.feed(Data([11, 65, 66]))
        let report = try parser.finish()
        XCTAssertEqual(report.losses.count, 1)
        XCTAssertEqual(report.losses.first?.droppedBytes, 403)
        XCTAssertEqual(parser.droppedBytes, 403)
    }

    func test_invalidLimits_throwTypedError() {
        var limits = MLLPLimits()
        limits.maxBufferedBytes = 0
        var parser = MLLPDeframer(limits: limits)
        XCTAssertThrowsError(try parser.feed(Data([11]))) {
            XCTAssertEqual(($0 as? MLLPFramingError)?.reason, .invalidLimits)
        }
    }
}
