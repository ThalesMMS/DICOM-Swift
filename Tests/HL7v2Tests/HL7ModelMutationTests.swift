import Foundation
import XCTest
@testable import HL7v2

final class HL7ModelMutationTests: XCTestCase {
    func test_fieldMutation_changesOnlyThatField() throws {
        let text = hl7Header() + "PID|old|\\X41\\|\\Q\\|||\rZZZ|untouched\\Zlocal\\|||\r"
        var message = try HL7Parser().parse(text)
        message["PID"]?[1] = HL7Field(.text("new|value"))
        let expected = text.replacingOccurrences(of: "PID|old|", with: "PID|new\\F\\value|")
        XCTAssertEqual(try HL7Serializer().serialize(message), Data(expected.utf8))
    }
    func test_leafMutation_retainsSiblingRawEscapes() throws {
        let text = hl7Header() + "PID|\\X41\\&old^\\Q\\~b\r"
        var message = try HL7Parser().parse(text)
        message["PID"]?[1][1][1][2] = .text("new^value")
        XCTAssertEqual(try HL7Serializer().serialize(message),
                       Data(text.replacingOccurrences(of: "&old^", with: "&new\\S\\value^").utf8))
    }
    func test_nullMutation_isNotEmptyOrLiteralQuotes() throws {
        var message = try HL7Parser().parse(hl7Header() + "PID|a|b\r")
        message["PID"]?[1] = HL7Field(.null)
        message["PID"]?[2] = HL7Field(.text("\"\""))
        let reparsed = try HL7Parser().parse(HL7Serializer().serialize(message))
        XCTAssertEqual(reparsed["PID"]?[1][1][1][1], .null)
        XCTAssertEqual(reparsed["PID"]?[2][1][1][1], .text("\"\""))
    }
    func test_unrepresentableMutation_reportsLeafPathWithoutContent() throws {
        var message = try HL7Parser().parse(hl7Header() + "PID|a\r")
        message["PID"]?[1][1][1][1] = .text("患者")
        XCTAssertThrowsError(try HL7Serializer().serialize(message)) {
            let error = $0 as? HL7SerializationError
            XCTAssertEqual(error?.diagnostic.code, .unrepresentableCharacter)
            XCTAssertEqual(error?.diagnostic.path, HL7Path(segment: "PID", field: 1, component: 1, subcomponent: 1))
            XCTAssertFalse(String(describing: $0).contains("患者"))
        }
        var options = HL7SerializerOptions()
        options.escapeUnrepresentable = true
        let output = try HL7Serializer(options: options).serialize(message)
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("\\XE682A3\\\\XE88085\\"))
    }
    func test_mutatedControlCharacters_areEscaped() throws {
        var message = try HL7Parser().parse(hl7Header() + "PID|a\r")
        message["PID"]?[1] = HL7Field(.text("a\rb\nc"))
        let data = try HL7Serializer().serialize(message)
        XCTAssertEqual(try HL7Parser().parse(data)["PID"]?[1][1][1][1], .text("a\rb\nc"))
    }
}
