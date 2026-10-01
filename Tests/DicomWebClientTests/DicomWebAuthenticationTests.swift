import DicomData
import Foundation
import Network
import XCTest
@testable import DicomWebClient

/// Validated authentication modes, classified failures and the QIDO `limit=1` verification (#2894).
final class DicomWebAuthenticationTests: XCTestCase {
    private static let secret = "s3cr3t-Value"

    func test_eachModeProducesExactlyItsHeader() throws {
        XCTAssertNil(try DicomWebAuthentication.none.header())
        let basic = try XCTUnwrap(try DicomWebAuthentication.basic(username: "isis", password: Self.secret).header())
        XCTAssertEqual(basic.name, "Authorization")
        XCTAssertEqual(basic.value, "Basic " + Data("isis:\(Self.secret)".utf8).base64EncodedString())
        let key = try XCTUnwrap(try DicomWebAuthentication.apiKey(headerName: "X-API-Key", value: Self.secret).header())
        XCTAssertEqual(key.name, "X-API-Key")
        XCTAssertEqual(key.value, Self.secret)
        let bearer = try XCTUnwrap(try DicomWebAuthentication.bearer(token: Self.secret).header())
        XCTAssertEqual(bearer.name, "Authorization")
        XCTAssertEqual(bearer.value, "Bearer \(Self.secret)")

        let configuration = try DicomWebClientConfiguration(baseURL: URL(string: "https://archive.example")!,
                                                            authentication: .apiKey(headerName: "X-API-Key", value: Self.secret))
        XCTAssertEqual(configuration.headers, ["X-API-Key": Self.secret])
    }

    func test_invalidSettingsAreRefusedWithoutEchoingTheSecret() {
        let cases: [(DicomWebAuthentication, DicomWebAuthenticationError)] = [
            (.basic(username: "", password: Self.secret), .empty(.username)),
            (.basic(username: "is:is", password: Self.secret), .usernameContainsColon),
            (.basic(username: "isis", password: Self.secret + "\r\nX-Injected: 1"), .controlCharacter(.password)),
            (.apiKey(headerName: "X API Key", value: Self.secret), .invalidHeaderName),
            (.apiKey(headerName: "", value: Self.secret), .invalidHeaderName),
            (.apiKey(headerName: "Host", value: Self.secret), .reservedHeaderName("Host")),
            (.apiKey(headerName: "proxy-authorization", value: Self.secret), .reservedHeaderName("proxy-authorization")),
            (.apiKey(headerName: "X-API-Key", value: " \(Self.secret)"), .surroundingWhitespace(.apiKey)),
            (.bearer(token: Self.secret + "\u{7F}"), .controlCharacter(.token)),
            (.bearer(token: ""), .empty(.token))
        ]
        for (authentication, expected) in cases {
            XCTAssertThrowsError(try authentication.header()) { error in
                XCTAssertEqual(error as? DicomWebAuthenticationError, expected)
                XCTAssertFalse(error.localizedDescription.contains(Self.secret), "\(expected) leaks the secret")
                XCTAssertEqual(DicomWebConnectionFailure(classifying: error).kind, .credentials)
            }
        }
    }

    func test_verificationClassifiesEveryFailureAgainstALocalServer() async throws {
        let server = VerificationServer()
        let port = try await server.start()
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func verify(_ base: String, timeout: TimeInterval = 10, redirects: Bool = true) async -> DicomWebConnectionFailure? {
            var configuration = DicomWebClientConfiguration(baseURL: URL(string: base)!, timeout: timeout)
            configuration.followsRedirects = redirects
            do {
                try await DicomWebClient(configuration: configuration,
                                         transport: URLSessionDicomWebHTTPTransport(session: session)).verifyConnection()
                return nil
            } catch let failure as DicomWebConnectionFailure {
                return failure
            } catch {
                XCTFail("unclassified \(error)")
                return nil
            }
        }

        let http = "http://127.0.0.1:\(port)"
        let ok = await verify("\(http)/ok")
        XCTAssertNil(ok)
        XCTAssertEqual(server.lastQuery, "limit=1")
        let unauthorized = await verify("\(http)/unauthorized")
        XCTAssertEqual(unauthorized, .init(kind: .authentication, statusCode: 401))
        let missing = await verify("\(http)/missing")
        XCTAssertEqual(missing, .init(kind: .notFound, statusCode: 404))
        let moved = await verify("\(http)/moved", redirects: false)
        XCTAssertEqual(moved, .init(kind: .redirect, statusCode: 302))
        let garbage = await verify("\(http)/garbage")
        XCTAssertEqual(garbage?.kind, .invalidResponse)
        let slow = await verify("\(http)/slow", timeout: 1)
        XCTAssertEqual(slow?.kind, .timeout)
        let tls = await verify("https://127.0.0.1:\(port)/ok")
        XCTAssertEqual(tls?.kind, .tls)
        let closed = await verify("http://127.0.0.1:\(try await Self.closedPort())/ok")
        XCTAssertEqual(closed?.kind, .network)
    }

    func test_qidoRepresentation_checksMIMEForQueryAndVerification() async throws {
        for contentType in [nil, "text/html", "application/octet-stream", "application/dicom+json;broken"] {
            let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!),
                transport: QIDORepresentationTransport(status: 200, contentType: contentType))
            do {
                _ = try await client.search(parameters: .init(level: .study))
                XCTFail("QIDO accepted \(contentType ?? "missing MIME")")
            } catch let error as DicomWebError {
                XCTAssertEqual(error.kind, .invalidResponse)
            }
            do {
                _ = try await client.searchStudies()
                XCTFail("Legacy QIDO accepted an incompatible MIME")
            } catch let error as DicomWebError {
                XCTAssertEqual(error.kind, .invalidResponse)
            }
            do {
                try await client.verifyConnection()
                XCTFail("Verification accepted an incompatible MIME")
            } catch let failure as DicomWebConnectionFailure {
                XCTAssertEqual(failure.kind, .invalidResponse)
            }
        }
        for (status, contentType) in [(200, "application/dicom+json" as String?),
                                      (200, "Application/JSON; charset=utf-8"), (204, nil)] {
            let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!),
                transport: QIDORepresentationTransport(status: status, contentType: contentType))
            let page = try await client.search(parameters: .init(level: .study))
            XCTAssertEqual(page.statusCode, status)
            XCTAssertEqual(page.contentType, contentType)
            XCTAssertEqual(page.dataSets.count, 0)
            let studies = try await client.searchStudies()
            XCTAssertEqual(studies.count, 0)
            try await client.verifyConnection()
        }
    }

    /// A port that was listening a moment ago and is closed now.
    private static func closedPort() async throws -> UInt16 {
        let server = VerificationServer()
        let port = try await server.start()
        server.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        return port
    }
}

/// Answers QIDO by the first path component: `ok` → `[]`, `unauthorized` → 401, `missing` → 404, `moved` → 302,
/// `garbage` → 200 with a body that is not DICOM JSON, `slow` → waits 5 s, anything else → 400.
private final class VerificationServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DicomWebAuthenticationTests.server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var query: String?

    var lastQuery: String? { lock.withLock { query } }

    init() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try! NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        let ready = AsyncThrowingStream<UInt16, any Error>.makeStream()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                if let port = listener.port { ready.continuation.yield(port.rawValue); ready.continuation.finish() }
            case .failed(let error): ready.continuation.finish(throwing: error)
            case .cancelled: ready.continuation.finish(throwing: CancellationError())
            default: break
            }
        }
        listener.newConnectionHandler = { [self] connection in
            lock.withLock { connections.append(connection) }
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, _, _ in
                let target = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ").dropFirst().first ?? ""
                let parts = target.split(separator: "?", maxSplits: 1)
                lock.withLock { query = parts.count > 1 ? String(parts[1]) : nil }
                let route = parts.first?.split(separator: "/").first.map(String.init) ?? ""
                let (status, extra, body): (String, String, String)
                switch route {
                case "ok": (status, extra, body) = ("200 OK", "Content-Type: application/dicom+json\r\n", "[]")
                case "unauthorized": (status, extra, body) = ("401 Unauthorized", "", "")
                case "missing": (status, extra, body) = ("404 Not Found", "", "")
                case "moved": (status, extra, body) = ("302 Found", "Location: /ok/studies\r\n", "")
                case "garbage": (status, extra, body) = ("200 OK", "Content-Type: text/html\r\n", "<html>login</html>")
                case "slow":
                    queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
                    return
                default: (status, extra, body) = ("400 Bad Request", "", "") // A TLS handshake, for one.
                }
                let response = "HTTP/1.1 \(status)\r\n\(extra)Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        let next = try await iterator.next()
        return try XCTUnwrap(next)
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections = [] }
    }
}

private struct QIDORepresentationTransport: DicomWebHTTPTransport {
    let status: Int
    let contentType: String?
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        .init(statusCode: status, headers: contentType.map { ["Content-Type": $0] } ?? [:],
              body: status == 204 ? Data() : Data("[]".utf8))
    }
}
