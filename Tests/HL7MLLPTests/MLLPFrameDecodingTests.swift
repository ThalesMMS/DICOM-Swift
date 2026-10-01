import Foundation
import XCTest
import HL7v2
@testable import HL7MLLP

final class MLLPFrameDecodingTests: XCTestCase {
    func test_corpus_framesDecodeThroughHL7Parser() throws {
        for name in ["ADT_A01_admission", "ORU_R01_lab_results"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "hl7",
                                                       subdirectory: "Fixtures/hl7kit"))
            let original = try Data(contentsOf: url)
            let payload = Data(original.map { $0 == 10 ? 13 : $0 })
            var parser = MLLPDeframer()
            let frame = try XCTUnwrap(parser.feed(MLLPFramer.frame(payload)).first)
            XCTAssertEqual(frame.payload, payload)
            let message = try frame.decodeHL7()
            XCTAssertEqual(message.segments.first?.name, "MSH")
            XCTAssertGreaterThan(message.segments.count, 1)
        }
    }

    func test_invalidUTF8_remainsBytesAndHL7ReportsCharsetFallback() throws {
        let payload = Data("MSH|^~\\&|APP|FAC|REC|FAC|20260911||ADT^A01|1|P|2.5\rPID|1||".utf8)
            + Data([255]) + Data([13])
        var parser = MLLPDeframer()
        let frame = try XCTUnwrap(parser.feed(MLLPFramer.frame(payload)).first)
        XCTAssertEqual(frame.payload, payload)
        XCTAssertEqual(frame.diagnostics, [])
        var options = HL7ParserOptions()
        options.charsetOverride = .utf8
        let message = try frame.decodeHL7(options: options)
        XCTAssertTrue(message.diagnostics.contains { $0.code == .charsetFallback })
    }
}
