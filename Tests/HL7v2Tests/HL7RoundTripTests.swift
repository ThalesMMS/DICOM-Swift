import Foundation
import XCTest
@testable import HL7v2

final class HL7RoundTripTests: XCTestCase {
    func test_allCRFixtures_roundTripExactly() throws {
        for url in hl7Fixtures("own") + hl7Fixtures("hl7kit") {
            if url.lastPathComponent == "bad_segment_id.hl7" { continue }
            let data = Data(try Data(contentsOf: url).map { $0 == 10 ? 13 : $0 })
            XCTAssertEqual(try HL7Serializer().serialize(HL7Parser().parse(data)), data, url.lastPathComponent)
        }
    }
    func test_LFCorpus_normalizesAndReports() throws {
        for url in hl7Fixtures("hl7kit") {
            if url.lastPathComponent == "bad_segment_id.hl7" { continue }
            let bytes = try Data(contentsOf: url)
            let message = try hl7LenientParser().parse(bytes)
            XCTAssertTrue(message.diagnostics.contains { $0.code == .terminatorNormalized })
            XCTAssertEqual(try HL7Serializer().serialize(message), Data(bytes.map { $0 == 10 ? 13 : $0 }))
        }
    }
    func test_CRLF_normalizesOncePerLine() throws {
        let text = (hl7Header() + "PID|1\r").replacingOccurrences(of: "\r", with: "\r\n")
        let message = try hl7LenientParser().parse(text)
        XCTAssertEqual(message.diagnostics.filter { $0.code == .terminatorNormalized }.count, 2)
        XCTAssertEqual(try HL7Serializer().serialize(message), Data((hl7Header() + "PID|1\r").utf8))
    }
    func test_missingFinalTerminator_isPreserved() throws {
        let bytes = Data((hl7Header() + "ZZZ|a||").utf8)
        XCTAssertEqual(try HL7Serializer().serialize(HL7Parser().parse(bytes)), bytes)
    }
    func test_trimming_isOptInAndRetainsNull() throws {
        let message = try HL7Parser().parse(hl7Header() + "ZZZ|a^^|\"\"|||\r")
        var options = HL7SerializerOptions()
        options.trimTrailingEmpty = true
        let result = try HL7Serializer(options: options).serialize(message)
        XCTAssertTrue(String(decoding: result, as: UTF8.self).hasSuffix("ZZZ|a|\"\"\r"))
    }
}
