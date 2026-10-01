import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

final class DicomWebMultipartStreamWriterTests: XCTestCase {
    func test_incrementalWriter_matchesGoldenFramingAndBuilder() throws {
        var body = Data()
        var writer = try DicomWebMultipartStreamWriter(boundary: "b")
        for payload in [Data("one".utf8), Data()] {
            try writer.beginPart(headers: [("Content-Type", "application/dicom")], contentLength: payload.count) { body += $0 }
            for byte in payload { try writer.payload(Data([byte])) { body += $0 } }
            try writer.endPart { body += $0 }
        }
        try writer.finish { body += $0 }
        let expected = "--b\r\nContent-Type: application/dicom\r\nContent-Length: 3\r\n\r\none\r\n" +
            "--b\r\nContent-Type: application/dicom\r\nContent-Length: 0\r\n\r\n\r\n--b--\r\n"
        XCTAssertEqual(body, Data(expected.utf8))
        XCTAssertEqual(body, try DicomWebSTOWMultipartBodyBuilder.build(instances: [
            .init(data: Data("one".utf8), transferSyntax: nil), .init(data: Data(), transferSyntax: nil)
        ], boundary: "b", maximumBytes: 1000))
    }

    func test_mismatchedLengthAndHeaderInjection_areRejected() throws {
        var writer = try DicomWebMultipartStreamWriter(boundary: "b")
        XCTAssertThrowsError(try writer.beginPart(headers: [("Content-Type", "application/dicom\r\nInjected: x")], contentLength: 0) { _ in })
        try writer.beginPart(headers: [("Content-Type", "application/dicom")], contentLength: 2) { _ in }
        try writer.payload(Data([1])) { _ in }
        XCTAssertThrowsError(try writer.endPart { _ in })
        XCTAssertThrowsError(try writer.payload(Data([2, 3])) { _ in })
    }

    func test_filePayload_matchesDataFramingAcrossReadBoundaries() throws {
        let payload = Data((0..<(2 * 64 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var body = Data()
        var sizes: [Int] = []
        var writer = try DicomWebMultipartStreamWriter(boundary: "file")
        try writer.beginPart(headers: [("Content-Type", "application/dicom")], contentLength: payload.count) { body += $0 }
        try writer.payload(file: handle) { sizes.append($0.count); body += $0 }
        try writer.endPart { body += $0 }
        try writer.finish { body += $0 }
        XCTAssertEqual(sizes, [64 * 1024, 64 * 1024, 17])
        XCTAssertEqual(body, try DicomWebSTOWMultipartBodyBuilder.build(
            instances: [.init(data: payload, transferSyntax: nil)], boundary: "file", maximumBytes: .max))
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }

    func test_filePayload_readAndSinkErrorsPropagate() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data(repeating: 0xA5, count: 128 * 1024)
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        var writer = try DicomWebMultipartStreamWriter(boundary: "file")
        try writer.beginPart(headers: [("Content-Type", "application/dicom")], contentLength: payload.count) { _ in }
        let sinkError = CocoaError(.fileWriteOutOfSpace)
        XCTAssertThrowsError(try writer.payload(file: handle) { _ in throw sinkError }) {
            XCTAssertEqual($0 as? CocoaError, sinkError)
        }
        try handle.close()
        XCTAssertThrowsError(try writer.payload(file: handle) { _ in XCTFail("Closed input reached sink") })
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }

    func test_filePayload_cancellationDuringWriteStopsBeforeNextRead() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data(repeating: 0xA5, count: 128 * 1024)
        try payload.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let task = Task { () throws -> (Int, UInt64) in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var writer = try DicomWebMultipartStreamWriter(boundary: "file")
            try writer.beginPart(headers: [("Content-Type", "application/dicom")], contentLength: payload.count) { _ in }
            var writes = 0
            do {
                try writer.payload(file: handle) { _ in
                    writes += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                XCTFail("Expected cancellation during write")
            } catch is CancellationError {}
            return (writes, try handle.offset())
        }
        let (writes, offset) = try await task.value
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(offset, 64 * 1024)
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }
}
