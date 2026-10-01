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
}

private struct FileEchoTransport: DicomWebHTTPTransport {
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        guard request.bodyFileURL == nil else { throw DicomWebError(kind: .badRequest) }
        return .init(statusCode: 200, body: request.body ?? Data())
    }
}
