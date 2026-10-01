import Foundation
import XCTest
@testable import DicomCore

final class DicomJPIPMessageParserTests: XCTestCase {
    func test_arbitraryChunkBoundaries_preserveMessagesAndEOR() throws {
        let messages = [
            DicomJPIPMessage(classID: 6, codestream: 128, binID: 0, offset: 0, isComplete: true, body: Data([255, 79])),
            DicomJPIPMessage(classID: 1, codestream: 128, binID: 12_345, offset: 256,
                             auxiliary: 3, body: Data(0...255))
        ]
        let wire = messages.reduce(Data()) { $0 + DicomJPIPOpenJPIPInteropTests.encode($1) } + Data([0, 2, 1, 99])
        for split in 0...wire.count {
            var parser = DicomJPIPMessageParser()
            var parsed = try parser.feed(Data(wire.prefix(split)))
            parsed += try parser.feed(Data(wire.dropFirst(split)))
            try parser.finish()
            XCTAssertEqual(parsed, messages)
            XCTAssertEqual(parser.endOfResponse?.reason, 2)
            XCTAssertEqual(parser.endOfResponse?.body, Data([99]))
        }
        var parser = DicomJPIPMessageParser()
        var parsed: [DicomJPIPMessage] = []
        for byte in wire { parsed += try parser.feed(Data([byte])) }
        try parser.finish()
        XCTAssertEqual(parsed, messages)
    }

    func test_classInheritanceAndDefaultCodestream() throws {
        var parser = DicomJPIPMessageParser()
        let messages = try parser.feed(Data([0x40, 6, 0, 1, 255, 0x30, 1, 1, 79]))
        XCTAssertEqual(messages.map(\.classID), [6, 6])
        XCTAssertEqual(messages.map(\.codestream), [0, 0])
        XCTAssertEqual(messages.map(\.offset), [0, 1])
        try parser.finish()
    }

    func test_malformedInputs_haveTypedErrors() {
        let cases: [(Data, DicomJPIPMessageError)] = [
            (Data([0x20]), .truncatedVBAS),
            (Data([0x10]), .invalidIndicator),
            (Data([0x40, 7]), .unknownClass(7)),
            (Data([0x40, 128, 0]), .overlongVBAS),
            (Data([0x40, 129]), .truncatedVBAS),
            (Data([0x40, 6, 0, 1]), .truncatedMessage),
            (Data([0, 2, 0, 1]), .messageAfterEOR),
            (Data([0, 0, 0]), .invalidEORReason(0))
        ]
        for (wire, expected) in cases {
            var parser = DicomJPIPMessageParser()
            XCTAssertThrowsError(try { _ = try parser.feed(wire); try parser.finish() }()) {
                XCTAssertEqual($0 as? DicomJPIPMessageError, expected)
            }
        }
        var parser = DicomJPIPMessageParser()
        XCTAssertNoThrow(try parser.feed(Data([0, 1, 0])))
        XCTAssertThrowsError(try parser.feed(Data([0x40]))) {
            XCTAssertEqual($0 as? DicomJPIPMessageError, .messageAfterEOR)
        }
    }

    func test_seededAdversarialCorpus_neverCrashes() throws {
        let base = DicomJPIPOpenJPIPInteropTests.encode(.init(classID: 1, codestream: 0, binID: 300,
            offset: 0, isComplete: true, auxiliary: 4, body: Data(repeating: 7, count: 32)))
        var seed: UInt64 = 0x2354
        func random() -> UInt64 { seed = seed &* 6_364_136_223_846_793_005 &+ 1; return seed }
        for iteration in 0..<2_000 {
            var wire = base
            for _ in 0..<(1 + iteration % 5) {
                wire[Int(random() % UInt64(wire.count))] = UInt8(truncatingIfNeeded: random() >> 32)
            }
            if iteration % 3 == 0 { wire = Data(wire.prefix(Int(random() % UInt64(wire.count)))) }
            var parser = DicomJPIPMessageParser(maximumMessageLength: 256, maximumBins: 16, maximumTotalBytes: 512)
            do {
                for byte in wire { _ = try parser.feed(Data([byte])) }
                try parser.finish()
            } catch { XCTAssertTrue(error is DicomJPIPMessageError, "Unexpected error: \(error)") }
        }
    }

    func test_limits_rejectBeforeAllocatingMessageBody() {
        var parser = DicomJPIPMessageParser(maximumMessageLength: 1)
        XCTAssertThrowsError(try parser.feed(Data([0x40, 6, 0, 2]))) {
            XCTAssertEqual($0 as? DicomJPIPMessageError, .messageTooLarge)
        }
        var bins = DicomJPIPMessageParser(maximumBins: 1)
        XCTAssertNoThrow(try bins.feed(Data([0x40, 6, 0, 0])))
        XCTAssertThrowsError(try bins.feed(Data([0x21, 0, 0]))) {
            XCTAssertEqual($0 as? DicomJPIPMessageError, .tooManyBins)
        }
    }
    func test_initialImplicitClassAndCodestream_defaultToZero() throws {
        var parser = DicomJPIPMessageParser()
        let message = try XCTUnwrap(parser.feed(Data([0x30, 0, 1, 42])).first)
        XCTAssertEqual(message.classID, 0)
        XCTAssertEqual(message.codestream, 0)
        XCTAssertEqual(message.body, Data([42]))
        try parser.finish()
    }

}
