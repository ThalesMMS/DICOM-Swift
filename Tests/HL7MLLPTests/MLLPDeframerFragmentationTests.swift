import Foundation
import XCTest
@testable import HL7MLLP

final class MLLPDeframerFragmentationTests: XCTestCase {
    func test_everySplitPoint_matchesWholeStream() throws {
        let wire = try MLLPFramer.frame(Data([0, 128, 255, 13])) + MLLPFramer.frame(Data("second".utf8))
        var whole = MLLPDeframer()
        let expected = try whole.feed(wire)
        for split in 0...wire.count {
            var parser = MLLPDeframer()
            let frames = try parser.feed(wire.prefix(split)) + parser.feed(wire.dropFirst(split))
            XCTAssertEqual(frames, expected, "split \(split)")
            XCTAssertEqual(try parser.finish().losses, [])
        }
        XCTAssertEqual(expected.map(\.sequence), [1, 2])
        XCTAssertEqual(expected.map(\.byteOffset), [0, 7])
    }

    func test_manyMessages_oneChunkAndOneByteFeeds() throws {
        let wire = try (0..<100).reduce(into: Data()) { $0 += try MLLPFramer.frame(Data("\($1)".utf8)) }
        var whole = MLLPDeframer()
        let expected = try whole.feed(wire)
        var incremental = MLLPDeframer()
        var actual: [MLLPFrame] = []
        for byte in wire { actual += try incremental.feed(Data([byte])) }
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.count, 100)
        XCTAssertEqual(incremental.lastActivityOffset, wire.count)
    }

    func test_trailerSplit_waitsForCR() throws {
        var parser = MLLPDeframer()
        XCTAssertEqual(try parser.feed(Data([11, 65, 28])), [])
        XCTAssertEqual(try parser.feed(Data()), [])
        XCTAssertEqual(parser.lastActivityOffset, 3)
        XCTAssertEqual(try parser.feed(Data([13])).first?.payload, Data([65]))
    }

    func test_junk_countedAcrossFeedsAndResetBetweenBlocks() throws {
        var limits = MLLPLimits()
        limits.maxJunkBytesBetweenBlocks = 2
        var parser = MLLPDeframer(limits: limits)
        XCTAssertEqual(try parser.feed(Data([65])), [])
        let first = try parser.feed(Data([66, 11, 28, 13]))
        XCTAssertEqual(first.first?.diagnostics, [.junkSkipped(count: 2)])
        XCTAssertEqual(first.first?.byteOffset, 2)
        XCTAssertEqual(try parser.feed(Data([67, 68, 11, 28, 13])).first?.diagnostics, [.junkSkipped(count: 2)])
        XCTAssertEqual(try parser.finish().junkSkipped, 4)
    }

    func test_junkBeyondLimit_throwsAtOffendingByte() throws {
        var limits = MLLPLimits()
        limits.maxJunkBytesBetweenBlocks = 2
        limits.recovery = .resynchronize
        var parser = MLLPDeframer(limits: limits)
        _ = try parser.feed(Data([65, 66]))
        XCTAssertThrowsError(try parser.feed(Data([67]))) {
            XCTAssertEqual(($0 as? MLLPFramingError)?.byteOffset, 2)
            XCTAssertEqual(($0 as? MLLPFramingError)?.reason, .junkLimit)
        }
    }

    func test_idleTimeout_usesSuppliedClock() throws {
        var parser = MLLPDeframer()
        _ = try parser.feed(Data([11]))
        XCTAssertFalse(parser.isIdle(since: 100, now: 159))
        XCTAssertTrue(parser.isIdle(since: 100, now: 160))
        XCTAssertFalse(parser.isIdle(since: 100, now: 99))
        XCTAssertEqual(parser.lastActivityOffset, 1)
    }
}
