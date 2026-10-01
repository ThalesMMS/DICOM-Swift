import DicomCore
import Foundation
import Network
import XCTest

@MainActor
final class DicomWebhookPinnedTransportTests: XCTestCase {
    func test_responseFramingSupportsLengthChunksAndConnectionClose() async throws {
        for bytes in [
            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\npong",
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;key=value\r\npo\r\n2\r\nng\r\n0\r\nTrailer: value\r\n\r\n",
            "HTTP/1.0 200 OK\r\n\r\npong"
        ] {
            let server = try RawWebhookResponseServer(response: Data(bytes.utf8))
            let url = try await server.start()
            defer { server.stop() }
            var request = DicomWebHTTPRequest(method: .post, url: url, body: Data("test".utf8), timeout: 2)
            request.connectAddress = "127.0.0.1"
            let response = try await DicomWebhookURLSessionTransport(maxResponseBytes: 4).send(request)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.body, Data("pong".utf8))
        }
    }

    func test_truncatedAmbiguousAndOversizedResponsesAreNotAcknowledged() async throws {
        for bytes in [
            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\npo",
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 4\r\n\r\npong",
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\npongs",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\npongs\r\n0\r\n\r\n"
        ] {
            let server = try RawWebhookResponseServer(response: Data(bytes.utf8))
            let url = try await server.start()
            defer { server.stop() }
            var request = DicomWebHTTPRequest(method: .post, url: url, body: Data("test".utf8), timeout: 2)
            request.connectAddress = "127.0.0.1"
            do {
                _ = try await DicomWebhookURLSessionTransport(maxResponseBytes: 4).send(request)
                XCTFail("Invalid or oversized acknowledgement was accepted")
            } catch DicomWebhookTransportError.responseTooLarge {}
            catch DicomWebhookTransportError.unknownProgress {}
        }
    }

    func test_generalURLSessionTransportRejectsPinnedRequest() async throws {
        var request = DicomWebHTTPRequest(method: .post, url: URL(string: "https://rebind.invalid")!)
        request.connectAddress = "127.0.0.1"
        do {
            _ = try await URLSessionDicomWebHTTPTransport().send(request)
            XCTFail("Transport silently ignored the pinned address")
        } catch DicomWebClientError.unsupportedConnectAddress {}
    }
}

private final class RawWebhookResponseServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Webhook.rawResponseTest")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private let response: Data

    init(response: Data) throws {
        self.response = response
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        let ready = AsyncThrowingStream<UInt16, any Error>.makeStream()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                if let port = listener.port { ready.continuation.yield(port.rawValue); ready.continuation.finish() }
                else { ready.continuation.finish(throwing: URLError(.cannotConnectToHost)) }
            case .failed(let error): ready.continuation.finish(throwing: error)
            case .cancelled: ready.continuation.finish(throwing: CancellationError())
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            lock.withLock { connections.append(connection) }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [response] _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        let port = try await iterator.next()
        return URL(string: "http://127.0.0.1:\(try XCTUnwrap(port))/hook")!
    }

    func stop() {
        listener.cancel()
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        lock.withLock { connections.forEach { $0.cancel() }; connections = [] }
    }
}
