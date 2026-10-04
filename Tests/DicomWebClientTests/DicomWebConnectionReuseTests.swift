import Foundation
import Network
import XCTest
@testable import DicomWebClient

/// Requests share the connections of the caller's session, and a body read more slowly than it arrives waits in a
/// private temporary file that is gone once the body is read, cancelled or failed.
final class DicomWebConnectionReuseTests: XCTestCase {
    private var server: KeepAliveHTTPServer!
    private var base: URL!
    private var session: URLSession!
    private var spillDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        server = KeepAliveHTTPServer()
        base = try await server.start()
        session = URLSession(configuration: .ephemeral)
        spillDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DicomWebConnectionReuseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: spillDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        server.stop()
        try? FileManager.default.removeItem(at: spillDirectory)
        try await super.tearDown()
    }

    /// 200 QIDO searches one after the other, each through a new client and transport over the same session, as the
    /// app builds them per call.
    func test_sequentialSearches_shareOneConnection() async throws {
        for _ in 0..<200 {
            let client = DicomWebClient(configuration: .init(baseURL: base, timeout: 10),
                                        transport: URLSessionDicomWebHTTPTransport(session: session))
            let page = try await client.search(parameters: .init(level: .study))
            XCTAssertTrue(page.dataSets.isEmpty)
        }
        XCTAssertEqual(server.searchCount, 200)
        XCTAssertEqual(server.acceptedConnections, 1)
    }

    func test_slowReader_spillsToAPrivateFileThatIsGoneOnceRead() async throws {
        let (body, _) = try await response(path: "large/16")
        let file = try await spillFile()
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        var offset = 0
        var mismatches = 0
        while let block = try await body.next() {
            for (index, byte) in block.enumerated() where byte != KeepAliveHTTPServer.byte(at: (offset + index) % (1 << 20)) {
                mismatches += 1
            }
            offset += block.count
        }
        XCTAssertEqual(offset, 16 << 20)
        XCTAssertEqual(mismatches, 0, "the bytes arrive in order")
        XCTAssertEqual(try spillFiles(), [])
    }

    func test_cancelledBody_removesItsSpillFile() async throws {
        let (body, _) = try await response(path: "stall/8")
        _ = try await spillFile()
        body.task.cancel()
        try await assertEndsWithError(body)
        XCTAssertEqual(try spillFiles(), [])
    }

    func test_failedBody_removesItsSpillFile() async throws {
        let (body, _) = try await response(path: "stall/8")
        _ = try await spillFile()
        server.dropConnections()
        try await assertEndsWithError(body)
        XCTAssertEqual(try spillFiles(), [])
    }

    private func response(path: String) async throws -> (DicomWebResponseBody, URLResponse) {
        let url = base.appendingPathComponent(path)
        let delegate = DicomWebRedirectDelegate(policy: .init(configuredURL: url), credentialHeaderNames: [])
        return try await session.dicomWebResponse(for: URLRequest(url: url, timeoutInterval: 10), delegate: delegate,
                                                  spillDirectory: spillDirectory)
    }

    /// Waits, without reading the body, until the part beyond the memory limit is in a file.
    private func spillFile() async throws -> URL {
        for _ in 0..<200 {
            if let file = try spillFiles().first,
               let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, size > 0 {
                return file
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(nil, "no spill file appeared within 10 seconds")
    }

    private func spillFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: spillDirectory, includingPropertiesForKeys: nil)
    }

    private func assertEndsWithError(_ body: DicomWebResponseBody) async throws {
        do {
            while try await body.next() != nil {}
            XCTFail("the body ends with the task's error")
        } catch {}
    }
}

/// An HTTP/1.1 server that keeps connections open and counts those it accepts. Paths: `studies` answers an empty
/// QIDO result; `large/N` sends N MiB; `stall/N` declares 2N MiB, sends N and then waits.
private final class KeepAliveHTTPServer: @unchecked Sendable {
    private static let block = Data((0..<(1 << 20)).map { byte(at: $0) })
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DicomWebConnectionReuseTests.server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var accepted = 0
    private var searches = 0

    var acceptedConnections: Int { lock.withLock { accepted } }
    var searchCount: Int { lock.withLock { searches } }

    static func byte(at offset: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: offset &* 31 &+ offset >> 12)
    }

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
            lock.withLock {
                connections.append(connection)
                accepted += 1
            }
            connection.start(queue: queue)
            readRequest(on: connection, received: Data())
        }
        listener.start(queue: queue)
        var iterator = ready.stream.makeAsyncIterator()
        let next = try await iterator.next()
        let port = try XCTUnwrap(next)
        return URL(string: "http://127.0.0.1:\(port)/dicom-web")!
    }

    /// Reads one request head (these requests have no body) and answers it.
    private func readRequest(on connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, complete, error in
            var received = received
            if let data { received.append(data) }
            guard let end = received.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete, error == nil { readRequest(on: connection, received: received) }
                return
            }
            let head = String(decoding: received[..<end.lowerBound], as: UTF8.self)
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            answer(target.split(separator: "?").first.map(String.init) ?? target, on: connection)
        }
    }

    private func answer(_ path: String, on connection: NWConnection) {
        let components = path.split(separator: "/")
        if path.hasSuffix("/studies") {
            lock.withLock { searches += 1 }
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/dicom+json\r\nContent-Length: 2\r\n\r\n[]"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [self] error in
                if error == nil { readRequest(on: connection, received: Data()) }
            })
        } else if components.count >= 2, let mebibytes = Int(components[components.count - 1]) {
            let stalls = components[components.count - 2] == "stall"
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                + "Content-Length: \((stalls ? 2 : 1) * mebibytes << 20)\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [self] error in
                if error == nil { send(blocks: mebibytes, on: connection, thenReads: !stalls) }
            })
        } else {
            connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8),
                            completion: .contentProcessed { [self] error in
                if error == nil { readRequest(on: connection, received: Data()) }
            })
        }
    }

    private func send(blocks remaining: Int, on connection: NWConnection, thenReads: Bool) {
        guard remaining > 0 else {
            if thenReads { readRequest(on: connection, received: Data()) }
            return
        }
        connection.send(content: Self.block, completion: .contentProcessed { [self] error in
            if error == nil { send(blocks: remaining - 1, on: connection, thenReads: thenReads) }
        })
    }

    /// Closes every open connection, so a response still being sent fails.
    func dropConnections() {
        lock.withLock { connections.forEach { $0.cancel() }; connections = [] }
    }

    func stop() {
        listener.cancel()
        dropConnections()
    }
}
