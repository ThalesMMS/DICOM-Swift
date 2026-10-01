import XCTest
@testable import HL7v2

final class HL7BatchTests: XCTestCase {
    func test_join_rejectsEnvelopeSegmentsInsideMessages() throws {
        for name in ["BHS", "BTS", "FHS", "FTS"] {
            let member = Data((hl7Header() + "\(name)|1\r").utf8)
            XCTAssertNoThrow(try HL7Parser().parse(member))
            XCTAssertThrowsError(try HL7BatchDocument.join([member]), name)
        }
    }

    func test_corpus_wrappedBatches_roundTripExactly() throws {
        for url in hl7Fixtures("own") + hl7Fixtures("hl7kit") {
            if url.lastPathComponent == "bad_segment_id.hl7" { continue }
            let member = Data(try Data(contentsOf: url).map { $0 == 10 ? 13 : $0 })
            let wire = try HL7BatchDocument.join([member], fileEnvelope: true)
            let batch = try HL7BatchDocument.parse(wire)
            XCTAssertEqual(batch.messages.count, 1, url.lastPathComponent)
            XCTAssertEqual(batch.serialize(), wire)
        }
    }
    func test_file_containsMultipleBatchesAndCustomFields() throws {
        let batch = "BHS|^~\\&|CUSTOM||\r" + hl7Header() + "PID|1\rBTS|1|COMMENT\r"
        let wire = Data(("FHS|^~\\&|SENDER\r" + batch + batch + "FTS|2\r").utf8)
        let parsed = try HL7BatchDocument.parse(wire)
        XCTAssertEqual(parsed.batches.count, 2)
        XCTAssertEqual(parsed.messages.count, 2)
        XCTAssertEqual(parsed.serialize(), wire)
    }
    func test_malformedMember_recoveredWithExactLoss() throws {
        let prefix = "BHS|^~\\&\r" + hl7Header() + "PID|GOOD\r"
        let bad = hl7Header() + "bad|SECRET\r"
        let wire = Data((prefix + bad + hl7Header() + "PID|LAST\rBTS|3\r").utf8)
        XCTAssertThrowsError(try HL7BatchDocument.parse(wire))
        let parsed = try HL7BatchDocument.parse(wire, recoverMessages: true)
        XCTAssertEqual(parsed.messages.count, 2)
        let loss = try XCTUnwrap(parsed.lossReport.first)
        XCTAssertEqual(loss.index, 1)
        XCTAssertEqual(loss.byteRange, prefix.utf8.count..<(prefix.utf8.count + bad.utf8.count))
        XCTAssertEqual(loss.byteLength, bad.utf8.count)
        XCTAssertEqual(loss.code, .malformedContent)
        XCTAssertEqual(parsed.serialize(), wire)
        XCTAssertFalse(String(describing: loss).contains("SECRET"))
    }
    func test_countsAndEnvelopeOrder_rejectMismatch() throws {
        for wire in ["BHS|^~\\&\rBTS|1\r", "FHS|^~\\&\rBHS|^~\\&\rBTS|0\rFTS|2\r",
                     "BHS|^~\\&\rBHS|^~\\&\rBTS|0\r", "FHS|^~\\&\r", "BTS|0\r",
                     "BHS|^~\\&\rBTS|-1\r", "BHS|^~\\&\rBTS|0\rPID|X\r"] {
            XCTAssertThrowsError(try HL7BatchDocument.parse(Data(wire.utf8)), wire)
        }
    }
    func test_customEnvelopeDelimitersAndLenientTerminators_preserveBytes() throws {
        let wire = Data(("FHS*$%!?\r\nBHS*$%!?\r\n" + hl7Header() + "BTS*1\r\nFTS*1").utf8)
        var options = HL7ParserOptions(); options.lenientTerminators = true
        XCTAssertEqual(try HL7BatchDocument.parse(wire, options: options).serialize(), wire)
    }
    func test_recovery_doesNotSuppressLimits() throws {
        var options = HL7ParserOptions(); options.maxMessageBytes = 10
        let wire = try HL7BatchDocument.join([Data(hl7Header().utf8)])
        XCTAssertThrowsError(try HL7BatchDocument.parse(wire, options: options, recoverMessages: true)) {
            XCTAssertEqual($0 as? HL7ParseError, .limitExceeded(.messageBytes, .init()))
        }
    }
}
