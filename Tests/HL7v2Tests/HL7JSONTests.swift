import XCTest
@testable import HL7v2

final class HL7JSONTests: XCTestCase {
    func test_untrustedRawJSON_cannotInjectMessageStructure() throws {
        for raw in ["A|B", "A~B", "A^B", "A&B", "A\rPID|INJECTED", "\\Zopaque\rPID|INJECTED\\", "\\Zopen|B"] {
            var message = try HL7Parser().parse(hl7Header() + "ZZZ|SAFE\r")
            message["ZZZ"]?[1][1][1].raw = [raw]
            let restored = try HL7JSON.decode(HL7JSON.encode(message))
            XCTAssertThrowsError(try HL7Serializer().serialize(restored), raw)
        }
    }

    func test_roundTrip_preservesAbsentEmptyNullAndLiteralQuotes() throws {
        var message = try HL7Parser().parse(hl7Header() + "ZZZ||\"\"|\\X2222\\|A^B~C&D\r")
        message["ZZZ"]?[5] = HL7Field(.absent)
        let restored = try HL7JSON.decode(HL7JSON.encode(message))
        XCTAssertEqual(restored.segments, message.segments)
        XCTAssertEqual(restored["ZZZ"]?[1][1][1][1], .empty)
        XCTAssertEqual(restored["ZZZ"]?[2][1][1][1], .null)
        XCTAssertEqual(restored["ZZZ"]?[3][1][1][1], .text("\"\""))
        XCTAssertEqual(restored["ZZZ"]?[5][1][1][1], .absent)
        XCTAssertEqual(try HL7Serializer().serialize(restored), try HL7Serializer().serialize(message))
    }
    func test_corpusJSON_preservesWire() throws {
        for url in hl7Fixtures("own") + hl7Fixtures("hl7kit") {
            if url.lastPathComponent == "bad_segment_id.hl7" { continue }
            let bytes = Data(try Data(contentsOf: url).map { $0 == 10 ? 13 : $0 })
            let message = try HL7Parser().parse(bytes)
            XCTAssertEqual(try HL7Serializer().serialize(HL7JSON.decode(HL7JSON.encode(message))), bytes,
                           url.lastPathComponent)
        }
    }
    func test_charsetOverride_preservesEffectiveEncodingThroughJSON() throws {
        let bytes = HL7Charset.iso8859(1).encode(hl7Header() + "PID|José\r")!
        var options = HL7ParserOptions(); options.charsetOverride = .iso8859(1)
        let parsed = try HL7Parser(options: options).parse(bytes)
        let restored = try HL7JSON.decode(HL7JSON.encode(parsed))
        XCTAssertEqual(restored.effectiveCharset, .iso8859(1))
        XCTAssertEqual(try HL7Serializer().serialize(restored), bytes)
    }
    func test_invalidJSON_isRejected() {
        XCTAssertThrowsError(try HL7JSON.decode(Data("{}".utf8)))
    }
}
