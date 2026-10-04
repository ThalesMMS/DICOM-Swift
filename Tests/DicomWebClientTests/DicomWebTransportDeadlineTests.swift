import DicomData
import Foundation
import Network
import XCTest
@testable import DicomWebClient

/// Inactivity timeout and total deadline apart, redirects on request, and no temporary file left behind (#2893).
final class DicomWebTransportDeadlineTests: XCTestCase {
    private var server: RoutedHTTPServer!
    private var base: URL!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        server = RoutedHTTPServer()
        base = try await server.start()
        session = URLSession(configuration: .ephemeral)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        server.stop()
        try await super.tearDown()
    }

    func test_redirectsAreRefusedOnRequestAndFollowedOtherwise() async throws {
        let transport = URLSessionDicomWebHTTPTransport(session: session)
        var request = DicomWebHTTPRequest(method: .get, url: base.appendingPathComponent("redirect"))
        request.followsRedirects = false
        let refused = try await transport.stream(request)
        refused.cancel()
        XCTAssertEqual(refused.statusCode, 302)

        request.followsRedirects = true
        let followed = try await transport.stream(request)
        var body = Data()
        for try await chunk in followed.body { body.append(chunk) }
        XCTAssertEqual(followed.statusCode, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "target")
    }

    func test_authenticationChallengeReachesTheCallerAs401() async throws {
        let transport = URLSessionDicomWebHTTPTransport(session: session)
        let response = try await transport.stream(DicomWebHTTPRequest(method: .get, url: base.appendingPathComponent("basic")))
        response.cancel()
        XCTAssertEqual(response.statusCode, 401, "no shared credential is tried, and the challenge is not a cancellation")
    }

    func test_authenticationChallengeToAStreamedBodyReachesTheCallerAs401() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stow-challenge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0x2A, count: 4096).write(to: file)
        var request = DicomWebHTTPRequest(method: .post, url: base.appendingPathComponent("basic"), timeout: 20)
        request.bodyFileURL = file
        let started = Date()
        let response = try await URLSessionDicomWebHTTPTransport(session: session).stream(request)
        response.cancel()
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the 401 arrives at once, not at the request timeout")
    }

    func test_authenticationChallengeToASegmentedBodyReachesTheCallerAs401() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stow-challenge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0x2A, count: 4096).write(to: file)
        let body = DicomWebHTTPRequestBody(segments: [.data(Data("head".utf8)), .file(file, length: 4096),
                                                      .data(Data("tail".utf8))])
        var request = DicomWebHTTPRequest(method: .post, url: base.appendingPathComponent("basic"),
                                          headers: ["Content-Length": String(body.length)], timeout: 20)
        request.streamedBody = body
        let started = Date()
        let response = try await URLSessionDicomWebHTTPTransport(session: session).stream(request)
        response.cancel()
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the body is read again at once, not at the timeout")
    }

    func test_totalDeadlineEndsAStalledRetrieveAndLeavesNoPartialFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wado-2893-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = DicomWebClientConfiguration(baseURL: base.appendingPathComponent("stall-body"), timeout: 30)
        configuration.totalDeadline = 1
        let client = DicomWebClient(configuration: configuration, transport: URLSessionDicomWebHTTPTransport(session: session))
        let started = Date()
        do {
            _ = try await client.retrieveStudy(studyInstanceUID: "2.25.2893", sink: try DicomWebFileRetrieveSink(directory: directory))
            XCTFail("a stalled body outlived its deadline")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the deadline, not the 30 s inactivity timeout, ended it")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func test_cancelledRetrieveLeavesNoPartialFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wado-2893-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = DicomWebClient(configuration: .init(baseURL: base.appendingPathComponent("stall-body"), timeout: 30),
                                    transport: URLSessionDicomWebHTTPTransport(session: session))
        let sink = try DicomWebFileRetrieveSink(directory: directory)
        let task = Task { try await client.retrieveStudy(studyInstanceUID: "2.25.2893", sink: sink) }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled retrieve completed")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func test_totalDeadlineEndsAStalledStoreAndRemovesItsStagedBody() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stow-2893-\(UUID().uuidString).dcm")
        defer { try? FileManager.default.removeItem(at: file) }
        try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.28931"]))
        ]), options: .init(transferSyntax: .explicitVRLittleEndian)).write(to: file)
        let staged = { Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("dicomweb-stow-") }) }
        let before = try staged()
        var configuration = DicomWebClientConfiguration(baseURL: base.appendingPathComponent("stall-answer"), timeout: 30)
        configuration.totalDeadline = 1
        let client = DicomWebClient(configuration: configuration, transport: URLSessionDicomWebHTTPTransport(session: session))
        do {
            _ = try await client.storeInstances(files: [file])
            XCTFail("a store without an answer outlived its deadline")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(try staged(), before, "the staged multipart body is removed")
    }
}

/// Routes by the request path's last component: `redirect` → 302 to `target`, `basic` → 401 with a Basic challenge,
/// `stall-body` → a multipart part that never ends, `stall-answer` → no answer at all.
private final class RoutedHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DicomWebTransportDeadlineTests.server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var port: UInt16 = 0

    init() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try! NWListener(using: parameters)
    }

    func start() async throws -> URL {
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                answer(path.split(separator: "?").first.map(String.init) ?? path, on: connection)
            }
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        let next = try await iterator.next()
        port = try XCTUnwrap(next)
        return URL(string: "http://127.0.0.1:\(port)/dicom-web")!
    }

    private func answer(_ path: String, on connection: NWConnection) {
        let response: String
        if path.hasSuffix("/redirect") {
            response = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/dicom-web/target\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        } else if path.hasSuffix("/target") {
            response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 6\r\nConnection: close\r\n\r\ntarget"
        } else if path.hasSuffix("/basic") {
            // The request body may still be arriving; closing with it unread would reset the connection and the
            // client would see the reset instead of the 401, so the rest of the request is read and dropped.
            let challenge = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"isis\"\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(challenge.utf8), completion: .contentProcessed { _ in })
            drain(connection)
            return
        } else if path.contains("/stall-body/") {
            response = "HTTP/1.1 200 OK\r\nContent-Type: multipart/related; type=\"application/dicom\"; boundary=B2893\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n"
            let part = "--B2893\r\nContent-Type: application/dicom\r\n\r\n" + String(repeating: "x", count: 2048)
            connection.send(content: Data((response + String(part.utf8.count, radix: 16) + "\r\n" + part + "\r\n").utf8),
                            completion: .contentProcessed { _ in })
            return
        } else {
            // stall-answer: read the request and never answer.
            drain(connection)
            return
        }
        connection.send(content: Data(response.utf8), isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] _, _, complete, error in
            if !complete, error == nil { drain(connection) }
        }
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() }; connections = [] }
    }
}
