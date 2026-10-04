import Foundation
import Network
import XCTest
@testable import DicomWebClient

/// Repetition of busy, failed and dropped requests against a loopback server, and the server's diagnostics in
/// `DicomWebError`.
final class DicomWebRetryPolicyTests: XCTestCase {
    private var server: ScriptedHTTPServer!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        server = ScriptedHTTPServer()
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        server.stop()
        try await super.tearDown()
    }

    private func client(_ policy: DicomWebRetryPolicy? = nil, headers: [String: String] = [:]) async throws -> DicomWebClient {
        var configuration = DicomWebClientConfiguration(baseURL: try await server.start(), headers: headers, timeout: 10)
        if let policy { configuration.retryPolicy = policy }
        return DicomWebClient(configuration: configuration, transport: URLSessionDicomWebHTTPTransport(session: session))
    }

    private static let policy = DicomWebRetryPolicy(maximumAttempts: 3, maximumRetryAfter: 60,
                                                    initialBackoff: 0.05, maximumBackoff: 0.2)
    private static let emptySearch = ScriptedHTTPServer.Action.respond(200, ["Content-Type": "application/dicom+json"], "[]")

    func test_429WithRetryAfterInSeconds_waitsThenRepeats() async throws {
        server.script = [.respond(429, ["Retry-After": "1"], "busy"), Self.emptySearch]
        let client = try await client(Self.policy)
        let started = Date()
        let studies = try await client.searchStudies()
        XCTAssertEqual(studies, [])
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9, "the client waited the Retry-After")
    }

    func test_429WithRetryAfterAsHTTPDate_waitsThenRepeats() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = formatter.string(from: Date().addingTimeInterval(2))
        server.script = [.respond(429, ["Retry-After": date], ""), Self.emptySearch]
        let client = try await client(Self.policy)
        let started = Date()
        let page = try await client.search(parameters: .init(level: .study))
        XCTAssertEqual(page.dataSets.count, 0)
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9, "the date, whole seconds ahead, was waited")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func test_503WithoutRetryAfter_backsOffAndRepeatsARetrieve() async throws {
        server.script = [.respond(503, [:], ""), .respond(503, [:], ""),
                         .respond(200, ["Content-Type": "application/dicom"], "DICM")]
        let client = try await client(Self.policy)
        let object = try await client.retrieveInstance(studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2",
                                                       sopInstanceUID: "2.25.3")
        XCTAssertEqual(object.firstPayload, Data("DICM".utf8))
        XCTAssertEqual(server.requestCount, 3)
    }

    func test_503OnEveryAttempt_endsWithTheLastError() async throws {
        server.script = Array(repeating: .respond(503, ["Warning": "299 - \"overloaded\""], ""), count: 3)
        let client = try await client(Self.policy)
        do {
            _ = try await client.retrieveStudyMetadata(studyInstanceUID: "2.25.1")
            XCTFail("a server that stays busy was reported as a success")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertEqual(error.warning, "299 - \"overloaded\"")
        }
        XCTAssertEqual(server.requestCount, 3, "three attempts in all")
    }

    func test_closedConnection_isRepeated() async throws {
        server.script = [.truncate, Self.emptySearch]
        let client = try await client(Self.policy)
        let studies = try await client.searchStudies()
        XCTAssertEqual(studies, [])
        XCTAssertEqual(server.requestCount, 2)
    }

    func test_401_isNotRepeated() async throws {
        server.script = [.respond(401, ["WWW-Authenticate": "Bearer"], "token expired"), Self.emptySearch]
        let client = try await client(Self.policy)
        do {
            _ = try await client.searchStudies()
            XCTFail("a 401 was repeated into a success")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.kind, .unauthorized)
            XCTAssertEqual(error.bodyPreview, "token expired")
        }
        XCTAssertEqual(server.requestCount, 1)
    }

    func test_retryAfterBeyondTheCeiling_endsAndKeepsIt() async throws {
        server.script = [.respond(429, ["Retry-After": "120"], ""), Self.emptySearch]
        let client = try await client(Self.policy)
        let started = Date()
        do {
            _ = try await client.searchStudies()
            XCTFail("a Retry-After above the ceiling was waited")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertEqual(error.retryAfter, 120, "the caller can schedule its own retry")
        }
        XCTAssertEqual(server.requestCount, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func test_cancellationDuringTheWait_endsAtOnce() async throws {
        server.script = [.respond(503, ["Retry-After": "30"], ""), Self.emptySearch]
        let client = try await client(Self.policy)
        let task = Task { try await client.searchStudies() }
        let deadline = Date().addingTimeInterval(10)
        while server.requestCount == 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled wait went on to a success")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 1, "the 30 s wait ended with the cancellation")
        XCTAssertEqual(server.requestCount, 1)
    }

    func test_withoutAPolicy_nothingIsRepeated() async throws {
        server.script = [.respond(503, ["Retry-After": "1"], ""), Self.emptySearch, .truncate, Self.emptySearch]
        let client = try await client()
        XCTAssertEqual(client.configuration.retryPolicy, .none)
        do {
            _ = try await client.searchStudies()
            XCTFail("a 503 was repeated without a policy")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertEqual(error.retryAfter, 1)
        }
        XCTAssertEqual(server.requestCount, 1)
        // The second answer is consumed, so the next request meets the dropped connection.
        _ = try await client.searchStudies()
        do {
            _ = try await client.searchStudies()
            XCTFail("a dropped connection was repeated without a policy")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(server.requestCount, 3)
    }

    func test_errorDiagnostics_areBoundedAndCarryNoCredential() async throws {
        let token = "s3cr3t-token-value"
        let body = "Authorization: Bearer \(token)\n{\"Cookie\": \"session=abc\"}\nPatientName is invalid\n"
            + "echo \(token)\n" + String(repeating: "x", count: 6000)
        server.script = [.respond(400, ["Warning": "299 - \"bad query\"", "X-DICOMweb-Error-Code": "E1"], body)]
        let client = try await client(Self.policy, headers: ["Authorization": "Bearer \(token)"])
        do {
            _ = try await client.searchStudies()
            XCTFail("a 400 was accepted")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.kind, .badRequest)
            XCTAssertEqual(error.code, "E1")
            XCTAssertEqual(error.warning, "299 - \"bad query\"")
            XCTAssertNil(error.retryAfter)
            let preview = try XCTUnwrap(error.bodyPreview)
            XCTAssertFalse(preview.contains(token))
            XCTAssertFalse(preview.contains("session=abc"))
            XCTAssertTrue(preview.contains("PatientName is invalid"))
            XCTAssertLessThanOrEqual(preview.utf8.count, 4096)
            XCTAssertFalse(String(describing: error).contains("PatientName"), "a logged error carries no body")
        }
    }

    func test_retryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(DicomWebError.retryAfter("120", now: now), 120)
        XCTAssertEqual(DicomWebError.retryAfter(" 0 ", now: now), 0)
        XCTAssertEqual(DicomWebError.retryAfter("Mon, 12 Jan 1970 13:46:50 GMT", now: now), 10)
        XCTAssertEqual(DicomWebError.retryAfter("Monday, 12-Jan-70 13:46:50 GMT", now: now), 10)
        XCTAssertEqual(DicomWebError.retryAfter("Mon Jan 12 13:46:50 1970", now: now), 10)
        XCTAssertEqual(DicomWebError.retryAfter("Thu, 01 Jan 1970 00:00:00 GMT", now: now), 0, "a past date waits nothing")
        XCTAssertNil(DicomWebError.retryAfter("-5", now: now))
        XCTAssertNil(DicomWebError.retryAfter("soon", now: now))
    }
}

/// Answers each request with the next scripted action, on a connection it then closes.
private final class ScriptedHTTPServer: @unchecked Sendable {
    enum Action {
        case respond(Int, [String: String], String)
        /// Sends the headers of a 200 and part of its body, then closes the connection. URLSession repeats a request
        /// whose connection closes before any answer by itself, so only a cut answer shows the client's own policy.
        case truncate
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "DicomWebRetryPolicyTests.server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var actions: [Action] = []
    private var requests = 0
    private var url: URL?

    var script: [Action] {
        get { lock.withLock { actions } }
        set { lock.withLock { actions = newValue } }
    }

    var requestCount: Int { lock.withLock { requests } }

    init() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try! NWListener(using: parameters)
    }

    func start() async throws -> URL {
        if let url = lock.withLock({ url }) { return url }
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
            readHead(on: connection, received: Data())
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        let next = try await iterator.next()
        let port = try XCTUnwrap(next)
        let url = URL(string: "http://127.0.0.1:\(port)/dicom-web")!
        lock.withLock { self.url = url }
        return url
    }

    private func readHead(on connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            let head = received + (data ?? Data())
            guard head.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil { connection.cancel() } else { readHead(on: connection, received: head) }
                return
            }
            let action = lock.withLock { () -> Action in
                requests += 1
                return actions.isEmpty ? .respond(500, [:], "unscripted") : actions.removeFirst()
            }
            switch action {
            case .truncate:
                let text = "HTTP/1.1 200 OK\r\nContent-Type: application/dicom+json\r\nContent-Length: 100\r\n\r\n[{"
                connection.send(content: Data(text.utf8), isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            case .respond(let status, let headers, let body):
                var text = "HTTP/1.1 \(status) Scripted\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
                for (name, value) in headers { text += "\(name): \(value)\r\n" }
                connection.send(content: Data((text + "\r\n" + body).utf8), isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections = [] }
    }
}
