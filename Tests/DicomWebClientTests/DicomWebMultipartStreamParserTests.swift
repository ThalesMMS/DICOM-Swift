import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

final class DicomWebMultipartStreamParserTests: XCTestCase {
    private let body = Data(("preamble\r\n--sample\r\nContent-Type: application/dicom\r\nContent-ID: <first>\r\n" +
        "Content-Location: /instances/1\r\n\r\nabc\r\n--sampleX\r\n123\r\n--sample\r\n" +
        "Content-Type: application/octet-stream\r\nContent-ID: <root>\r\nContent-Length: 0\r\n\r\n\r\n--sample--\r\nepilogue").utf8)

    private func parse(_ data: Data, sizes: [Int]) throws -> [DicomWebMultipartEvent] {
        var parser = try DicomWebMultipartStreamParser(contentType: "multipart/related; boundary=\"sample\"; start=\"<root>\"")
        var events: [DicomWebMultipartEvent] = []
        var offset = 0
        var index = 0
        while offset < data.count {
            let size = min(sizes[index % sizes.count], data.count - offset)
            events += try parser.feed(Data(data[offset..<offset + size]))
            offset += size
            index += 1
        }
        events += try parser.finish()
        return events
    }

    func test_arbitraryChunkBoundaries_preservePartsRootAndEpilogue() throws {
        let expected = try parse(body, sizes: [body.count])
        XCTAssertEqual(try parse(body, sizes: [1]), expected)
        var seed: UInt64 = 2351
        let sizes = (0..<100).map { _ -> Int in
            seed = seed &* 6364136223846793005 &+ 1
            return Int(seed % 31) + 1
        }
        XCTAssertEqual(try parse(body, sizes: sizes), expected)
        for split in 1..<body.count { XCTAssertEqual(try parse(body, sizes: [split, body.count]), expected) }
        XCTAssertTrue(expected.contains(.payload(Data("abc\r\n--sampleX\r\n123".utf8))))
        XCTAssertTrue(expected.contains(.epilogue(Data("epilogue".utf8))))
        XCTAssertEqual(expected.filter { if case .partHeaders(_, true) = $0 { return true }; return false }.count, 1)
    }

    /// Issue #2889: without Content-Length a part ends only at a whole delimiter line. Payload bytes that merely
    /// begin like a delimiter stay payload, and real delimiters with CRLF, LF and padding are found at every split.
    func test_undeclaredLength_endsOnlyAtAWholeDelimiterLine() throws {
        let payload = Data("x\r\n--b--X\r\n--bX\r\n--b \tY\r\n--b--\ttail\r\n--b".utf8) + Data([0, 0xFF, 7])
        // (line break, delimiter between the parts, closing delimiter)
        for (separator, middle, closing) in [("\r\n", "--b\r\n", "--b--\r\n"), ("\n", "--b\n", "--b--\n"),
                                             ("\r\n", "--b \t\r\n", "--b--  \r\n")] {
            let header = Data("Content-Type: application/dicom\(separator)\(separator)".utf8)
            let wire = Data("--b\(separator)".utf8) + header + payload + Data("\(separator)\(middle)".utf8) + header
                + Data("z\(separator)\(closing)".utf8)
            for size in 1...80 {
                var parser = try DicomWebMultipartStreamParser(boundary: "b")
                var bodies: [Data] = []
                var offset = 0
                while offset < wire.count {
                    let end = min(wire.count, offset + size)
                    for event in try parser.feed(Data(wire[offset..<end])) {
                        switch event {
                        case .partHeaders: bodies.append(Data())
                        case .payload(let data): bodies[bodies.count - 1] += data
                        default: break
                        }
                    }
                    offset = end
                }
                _ = try parser.finish()
                XCTAssertEqual(bodies, [payload, Data("z".utf8)], "chunk \(size), delimiter \(middle.debugDescription)")
            }
        }
    }

    func test_declaredLength_preservesBoundaryLookingPayload() throws {
        let payload = Data("before\r\n--b--\r\nafter".utf8)
        let wire = Data("--b\r\nContent-Type: application/dicom\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
            + payload + Data("\r\n--b--\r\n".utf8)
        var parser = try DicomWebMultipartStreamParser(boundary: "b")
        var result = Data()
        for byte in wire {
            for event in try parser.feed(Data([byte])) { if case .payload(let data) = event { result += data } }
        }
        _ = try parser.finish()
        XCTAssertEqual(result, payload)
    }

    func test_lfCompatibilityAndMissingFinalDelimiter() throws {
        let wire = Data("--b\nContent-Type: application/dicom\n\na\n--b--\n".utf8)
        XCTAssertEqual(try DicomWebMultipartStreamParser.parts(from: wire, contentType: "multipart/related; boundary=b").first?.body, Data("a".utf8))
        var parser = try DicomWebMultipartStreamParser(boundary: "b")
        _ = try parser.feed(Data(wire.dropLast(7)))
        XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? DicomWebMultipartStreamError, .missingFinalDelimiter) }
    }

    func test_limits_nameExceededBudget() throws {
        let wire = Data("--b\r\nContent-Type: application/dicom\r\n\r\npayload\r\n--b--\r\n".utf8)
        for (limits, name) in [
            (DicomWebMultipartLimits(maximumHeaderBytes: 4), "maximumHeaderBytes"),
            (.init(maximumPartBytes: 2), "maximumPartBytes"),
            (.init(maximumPartCount: 0), "maximumPartCount"),
            (.init(maximumTotalBytes: 8), "maximumTotalBytes")
        ] {
            var parser = try DicomWebMultipartStreamParser(boundary: "b", limits: limits)
            XCTAssertThrowsError(try parser.feed(wire)) {
                guard case .limitExceeded(let actual, _) = $0 as? DicomWebMultipartStreamError else { return XCTFail("\($0)") }
                XCTAssertEqual(actual, name)
            }
        }
    }

    func test_missingRootAndCancellation_areRejected() async throws {
        var parser = try DicomWebMultipartStreamParser(boundary: "b", start: "<missing>")
        _ = try parser.feed(Data("--b--\r\n".utf8))
        XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? DicomWebMultipartStreamError, .missingRoot) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var parser = try DicomWebMultipartStreamParser(boundary: "b")
            _ = try parser.feed(Data([1]))
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    }
}
