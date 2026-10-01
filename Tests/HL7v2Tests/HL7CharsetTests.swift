import Foundation
import XCTest
@testable import HL7v2

final class HL7CharsetTests: XCTestCase {
    func test_latin1_resolvesFromBytesBeforeDecode() throws {
        let message = try HL7Parser().parse(hl7Fixture("own/latin1.hl7"))
        XCTAssertEqual(message.charset, .iso8859(1))
        XCTAssertEqual(message["PID"]?[3][1][1][1], .text("café"))
        XCTAssertEqual(message["PID"]?[3][1][2][1], .text("Müller"))
    }
    func test_utf8_preservesUnicode() throws {
        let message = try HL7Parser().parse(hl7Fixture("own/utf8.hl7"))
        XCTAssertEqual(message.charset, .utf8)
        XCTAssertEqual(message["PID"]?[3][1][2][1], .text("患者"))
    }
    func test_unknownCharset_isByteTransparentAndReported() throws {
        let bytes = try hl7Fixture("own/unknown-charset.hl7")
        let message = try HL7Parser().parse(bytes)
        XCTAssertEqual(message.charset, .unknown("NOT-A-CHARSET"))
        XCTAssertEqual(message["PID"]?[1][1][1][1], .text("éü"))
        XCTAssertTrue(message.diagnostics.contains { $0.code == .charsetFallback })
        XCTAssertEqual(try HL7Serializer().serialize(message), bytes)
    }
    func test_repeatedCharsets_useFirstAndRecordOthers() throws {
        let message = try HL7Parser().parse(hl7Fixture("own/repeated-charsets.hl7"))
        XCTAssertEqual(message.charsetDeclarations, ["8859/1", "UNICODE UTF-8"])
        XCTAssertEqual(message.charset, .iso8859(1))
    }
    func test_legacyAlias_warns() throws {
        let message = try HL7Parser().parse(hl7Header(charset: "UNICODE") + "PID|é\r")
        XCTAssertEqual(message["PID"]?[1][1][1][1], .text("é"))
        XCTAssertTrue(message.diagnostics.contains { $0.code == .legacyCharsetAlias })
    }
    func test_allSupportedCharsets_decodeAndEncodeFoundationBytes() throws {
        let samples: [(String, String)] = [("ASCII", "ABC"), ("8859/1", "é"), ("8859/2", "Ł"),
            ("8859/3", "Ħ"), ("8859/4", "Ā"), ("8859/5", "Ж"), ("8859/6", "ش"),
            ("8859/7", "Ω"), ("8859/8", "א"), ("8859/9", "ğ"), ("8859/15", "€"), ("Windows-1252", "€")]
        for (declaration, sample) in samples {
            let charset = HL7Charset(declaration: declaration)
            let data = try XCTUnwrap((hl7Header(charset: declaration) + "PID|" + sample + "\r")
                .data(using: charset.stringEncoding), declaration)
            let message = try HL7Parser().parse(data)
            XCTAssertEqual(message["PID"]?[1][1][1][1], .text(sample), declaration)
            XCTAssertEqual(try HL7Serializer().serialize(message), data, declaration)
        }
    }
    func test_invalidUTF8_fallsBackWithoutReplacementCharacters() throws {
        let bytes = Data(hl7Header(charset: "UNICODE UTF-8").utf8) + Data([80, 73, 68, 124, 255, 13])
        let message = try HL7Parser().parse(bytes)
        XCTAssertEqual(message.effectiveCharset, .iso8859(1))
        XCTAssertTrue(message.diagnostics.contains { $0.code == .charsetFallback })
        XCTAssertEqual(try HL7Serializer().serialize(message), bytes)
    }
}
