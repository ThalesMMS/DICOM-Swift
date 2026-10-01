import Foundation
import XCTest
@testable import HL7v2

final class HL7ParserTests: XCTestCase {
    func test_corpus_parsesExceptMissingMSH() throws {
        let fixtures = hl7Fixtures("hl7kit")
        XCTAssertEqual(fixtures.count, 16)
        for url in fixtures {
            let bytes = try Data(contentsOf: url)
            if url.lastPathComponent == "bad_segment_id.hl7" {
                XCTAssertThrowsError(try hl7LenientParser().parse(bytes))
            } else {
                XCTAssertFalse(try hl7LenientParser().parse(bytes).segments.isEmpty, url.lastPathComponent)
            }
        }
    }
    func test_ownFixtures_parseWithDefaultLimits() throws {
        for url in hl7Fixtures("own") { XCTAssertFalse(try HL7Parser().parse(Data(contentsOf: url)).segments.isEmpty) }
    }
    func test_paths_extractRepetitionsAndSubcomponents() throws {
        let message = try HL7Parser().parse(hl7Fixture("own/structure.hl7"))
        XCTAssertEqual(message.value(at: try XCTUnwrap(HL7Path("PID-3.2.2[2]"))), .text("f"))
        XCTAssertEqual(message["PID"]?[3][1][1][2], .text("b"))
        XCTAssertNil(message.value(at: try XCTUnwrap(HL7Path("ABC-1"))))
        XCTAssertNil(HL7Path("PID-0"))
        XCTAssertNil(HL7Path("PID-3[0]"))
        XCTAssertNil(HL7Path("PID-3.1.2.3"))
        XCTAssertNil(HL7Path(""))
    }
    func test_nullEmptyAbsent_areDistinct() throws {
        let segment = try XCTUnwrap(HL7Parser().parse(hl7Fixture("own/structure.hl7"))["PID"])
        XCTAssertEqual(segment[4][1][1][1], .null)
        XCTAssertEqual(segment[5][1][1][1], .empty)
        XCTAssertEqual(segment[6][1][1][1], .empty)
        XCTAssertEqual(segment[7][1][1][1], .absent)
        XCTAssertFalse(segment[7].isPresent)
        XCTAssertTrue(segment[5].isPresent)
    }
    func test_metadata_extractsVIDAndType() throws {
        let message = try HL7Parser().parse(hl7Header(version: "2.5.1^USA"))
        XCTAssertEqual(message.version, .v2_5_1)
        XCTAssertEqual(message.messageType.code, "ADT")
        XCTAssertEqual(message.messageType.triggerEvent, "A01")
        XCTAssertEqual(message.messageType.structure, "ADT_A01")
        XCTAssertEqual(message.controlID, "CTRL")
        XCTAssertEqual(HL7Version.allCases.count, 14)
    }
    func test_unknownVersion_isPreservedAndReported() throws {
        let message = try HL7Parser().parse(hl7Header(version: "9.9"))
        XCTAssertEqual(message.version, .unknown("9.9"))
        XCTAssertTrue(message.diagnostics.contains { $0.code == .versionUnknown })
    }
    func test_customAndTruncationDelimiters_parse() throws {
        let custom = try HL7Parser().parse(hl7Fixture("own/custom.hl7"))
        XCTAssertEqual(custom.encoding.field, "#")
        XCTAssertEqual(custom["PID"]?[3][2][2][2], .text("f"))
        XCTAssertEqual(custom["PID"]?[4][1][1][1], .text("#"))
        let truncation = try HL7Parser().parse(hl7Fixture("own/truncation.hl7"))
        XCTAssertEqual(truncation.encoding.truncation, "#")
    }
    func test_conflictingDelimiters_throw() throws {
        XCTAssertThrowsError(try HL7EncodingCharacters(field: "^"))
        XCTAssertThrowsError(try HL7EncodingCharacters(escape: "a"))
        XCTAssertThrowsError(try HL7EncodingCharacters(truncation: "\r"))
        XCTAssertThrowsError(try HL7Parser().parse("MSH|^^\\&|A\r"))
    }
}
