import Foundation
import XCTest
@testable import HL7v2

final class HL7LimitsAndRecoveryTests: XCTestCase {
    func test_messageByteLimit_throwsBeforeParsing() throws {
        var options = HL7ParserOptions()
        options.maxMessageBytes = 1024
        XCTAssertThrowsError(try HL7Parser(options: options).parse(hl7Fixture("own/oversized.hl7"))) {
            XCTAssertEqual($0 as? HL7ParseError, .limitExceeded(.messageBytes, HL7Path()))
        }
        XCTAssertThrowsError(try HL7Parser().parse(Data(repeating: 65, count: 16 * 1024 * 1024 + 1))) {
            XCTAssertEqual($0 as? HL7ParseError, .limitExceeded(.messageBytes, HL7Path()))
        }
    }
    func test_segmentLimit_countsSkippedSegmentsToo() {
        var options = HL7ParserOptions()
        options.maxSegments = 2
        options.recovery = .skipBadSegments
        XCTAssertThrowsError(try HL7Parser(options: options).parse(hl7Header() + "bad|secret\rPID|1\r")) {
            XCTAssertEqual($0 as? HL7ParseError, .limitExceeded(.segments, HL7Path()))
        }
    }
    func test_fieldLimit_reportsSegmentPath() {
        var options = HL7ParserOptions()
        options.maxFieldsPerSegment = 18
        XCTAssertThrowsError(try HL7Parser(options: options).parse(hl7Header() + "ZZZ" + String(repeating: "|", count: 19))) {
            XCTAssertEqual($0 as? HL7ParseError, .limitExceeded(.fields, HL7Path(segment: "ZZZ")))
        }
    }
    func test_repetitionLimit_reportsFieldPathAndIsNotRecovered() {
        var options = HL7ParserOptions()
        options.maxRepetitions = 2
        options.recovery = .skipBadSegments
        XCTAssertThrowsError(try HL7Parser(options: options).parse(hl7Header() + "PID|a~b~c\r")) {
            XCTAssertEqual($0 as? HL7ParseError, .limitExceeded(.repetitions, HL7Path(segment: "PID", field: 1)))
        }
    }
    func test_componentDepthLimit_reportsPath() {
        var options = HL7ParserOptions()
        options.maxComponentDepth = 2
        XCTAssertThrowsError(try HL7Parser(options: options).parse(hl7Header() + "PID|a&b\r")) {
            XCTAssertEqual($0 as? HL7ParseError, .limitExceeded(.componentDepth,
                HL7Path(segment: "PID", field: 1, component: 1, subcomponent: 1)))
        }
    }
    func test_skipBadSegments_keepsRestAndReportsOnlyLengths() throws {
        var options = HL7ParserOptions()
        options.recovery = .skipBadSegments
        let bad = "bad|SECRET"
        let message = try HL7Parser(options: options).parse(hl7Header() + bad + "\rPID|1\rZZZ|2\r")
        XCTAssertEqual(message.segments.map(\.name), ["MSH", "PID", "ZZZ"])
        XCTAssertEqual(message["PID"]?.originalLineIndex, 2)
        XCTAssertEqual(message.lossReport.count, 1)
        XCTAssertEqual(message.lossReport.first?.lineIndex, 1)
        XCTAssertEqual(message.lossReport.first?.lengths, [bad.utf8.count])
        XCTAssertFalse(String(describing: message.diagnostics).contains("SECRET"))
    }
    func test_malformedControlByte_isSkipped() throws {
        var options = HL7ParserOptions()
        options.recovery = .skipBadSegments
        let message = try HL7Parser(options: options).parse(hl7Header() + "OBX|secret\u{0}value\rPID|1\r")
        XCTAssertEqual(message.segments.map(\.name), ["MSH", "PID"])
        XCTAssertEqual(message.lossReport.count, 1)
    }
    func test_strict_reportsPathWithoutContent() {
        XCTAssertThrowsError(try HL7Parser().parse(hl7Header() + "PIDsecret\r")) {
            XCTAssertEqual($0 as? HL7ParseError, .malformed(HL7Path(segment: "PID"), lineIndex: 1))
            XCTAssertFalse(String(describing: $0).contains("secret"))
        }
    }
    func test_lenientTerminators_requireOptIn() {
        for text in [hl7Header().replacingOccurrences(of: "\r", with: "\n"),
                     hl7Header().replacingOccurrences(of: "\r", with: "\r\n")] {
            XCTAssertThrowsError(try HL7Parser().parse(text))
        }
    }
    func test_recoveryBeforeMSH_reportsDiscardedLine() throws {
        var options = HL7ParserOptions()
        options.recovery = .skipBadSegments
        let message = try HL7Parser(options: options).parse("bad|secret\r" + hl7Header())
        XCTAssertEqual(message.lossReport.first?.lineIndex, 0)
        XCTAssertEqual(message.segments.first?.originalLineIndex, 1)
    }
}
