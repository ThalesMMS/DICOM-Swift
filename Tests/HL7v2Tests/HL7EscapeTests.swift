import Foundation
import XCTest
@testable import HL7v2

final class HL7EscapeTests: XCTestCase {
    func test_separatorVectors_workInBothDirections() {
        let text = "|^&~\\\r"
        let escaped = "\\F\\\\S\\\\T\\\\R\\\\E\\\\X0D\\"
        XCTAssertEqual(HL7Escape.escape(text), escaped)
        XCTAssertEqual(HL7Escape.unescape(escaped).text, text)
    }
    func test_hex_usesMessageCharset() {
        XCTAssertEqual(HL7Escape.unescape("\\XE9FC\\", charset: .iso8859(1)).text, "éü")
        XCTAssertEqual(HL7Escape.unescape("\\XC3A9\\", charset: .utf8).text, "é")
        XCTAssertEqual(HL7Escape.unescape("\\X0D\\").text, "\r")
    }
    func test_markersAndUnknown_arePreserved() {
        let text = "\\H\\hi\\N\\\\Zlocal\\\\.br\\\\.sp\\\\C2842\\\\M244242\\\\Q\\"
        let result = HL7Escape.unescape(text)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.diagnostics.map(\.code), [.charsetSwitchIgnored, .charsetSwitchIgnored, .unknownEscape])
        XCTAssertFalse(result.diagnostics.map(\.detail).joined().contains("local"))
    }
    func test_malformedHexAndUnclosedEscape_arePreserved() {
        for text in ["\\XG0\\", "\\X0\\", "\\X\\", "\\Q", "\\X+A\\", "\\X+0\\", "\\X-0\\"] {
            let result = HL7Escape.unescape(text)
            XCTAssertEqual(result.text, text)
            XCTAssertEqual(result.diagnostics.first?.code, .unknownEscape)
        }
    }
    func test_opaqueEscapeContainingDelimiters_doesNotCreateFields() throws {
        let message = try HL7Parser().parse(hl7Header() + "ZZZ|\\Zfoo|bar^baz\\|next\r")
        XCTAssertEqual(message["ZZZ"]?.fields.count, 2)
        XCTAssertEqual(message["ZZZ"]?[1][1][1][1], .text("\\Zfoo|bar^baz\\"))
    }
}
