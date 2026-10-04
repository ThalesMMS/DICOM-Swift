import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

final class DicomWebStreamingTransportTests: XCTestCase {
    func test_separateConnectAddressIsRefusedBeforeNetworkingWithClientError() async throws {
        var request = DicomWebHTTPRequest(method: .get, url: URL(string: "https://archive.invalid")!)
        request.connectAddress = "127.0.0.1"
        do {
            _ = try await URLSessionDicomWebHTTPTransport.shared.stream(request)
            XCTFail("separate connectAddress was silently ignored")
        } catch let error as DicomWebClientError {
            XCTAssertEqual(error, .unsupportedConnectAddress)
            XCTAssertEqual(DicomWebConnectionFailure(classifying: error).kind, .configuration)
        }
    }

    func test_compatibilityStream_readsFileBody() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = Data("synthetic request".utf8)
        try payload.write(to: file)
        var request = DicomWebHTTPRequest(method: .post, url: URL(string: "https://synthetic.example/studies")!)
        request.bodyFileURL = file
        let response = try await FileEchoTransport().stream(request)
        var received = Data()
        for try await chunk in response.body { received.append(chunk) }
        XCTAssertEqual(received, payload)
    }

    func test_compatibilityStream_rejectsFileAboveRequestLimit() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        let limit = 16
        try handle.truncate(atOffset: UInt64(limit + 1))
        try handle.close()
        var request = DicomWebHTTPRequest(method: .post, url: URL(string: "https://synthetic.example/studies")!)
        request.bodyFileURL = file
        do {
            _ = try await FileEchoTransport().stream(request, bufferingLimit: limit)
            XCTFail("An oversized file must not be buffered and sent")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.kind, .tooLarge)
        }
    }

    func test_segmentedBody_readsEverySegmentFromTheStartOfEachStream() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try content.write(to: file)
        let body = DicomWebHTTPRequestBody(segments: [.data(Data("head".utf8)), .file(file, length: 150_000),
                                                      .file(file, length: 0), .data(Data("tail".utf8))])
        let expected = Data("head".utf8) + content.prefix(150_000) + Data("tail".utf8)
        XCTAssertEqual(body.length, expected.count)
        for _ in 0..<2 {
            XCTAssertEqual(try Self.readAll(body.makeInputStream()), expected)
        }
    }

    func test_segmentedBody_aFileShorterThanItsLengthFailsTheStream() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 1, count: 10).write(to: file)
        let stream = DicomWebHTTPRequestBody(segments: [.file(file, length: 11)]).makeInputStream()
        XCTAssertThrowsError(try Self.readAll(stream))
        XCTAssertNotNil(stream.streamError)
    }

    func test_compatibilityStream_buffersASegmentedBody() async throws {
        var request = DicomWebHTTPRequest(method: .post, url: URL(string: "https://synthetic.example/studies")!)
        request.streamedBody = DicomWebHTTPRequestBody(segments: [.data(Data("synthetic ".utf8)), .data(Data("body".utf8))])
        let response = try await FileEchoTransport().stream(request)
        var received = Data()
        for try await chunk in response.body { received.append(chunk) }
        XCTAssertEqual(received, Data("synthetic body".utf8))
    }

    private static func readAll(_ stream: InputStream) throws -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CocoaError(.fileReadUnknown) }
            if count == 0 { return data }
            data.append(buffer, count: count)
        }
    }
}

private struct FileEchoTransport: DicomWebHTTPTransport {
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        guard request.bodyFileURL == nil else { throw DicomWebError(kind: .badRequest) }
        return .init(statusCode: 200, body: request.body ?? Data())
    }
}
