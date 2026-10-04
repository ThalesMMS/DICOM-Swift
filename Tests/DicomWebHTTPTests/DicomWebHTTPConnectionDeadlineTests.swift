import XCTest
import Darwin
import Foundation
@testable import DicomWebHTTP

/// The connection deadline cuts idle or unfinished requests and stalled responses,
/// but not a response that keeps reaching a slow reader.
final class DicomWebHTTPConnectionDeadlineTests: XCTestCase {
    private static let lifetime: TimeInterval = 1

    func test_slowReader_receivesWholeResponseBeyondDeadline() async throws {
        let chunk = Data(repeating: 0x5A, count: 16 * 1024)
        let chunks = 256 // 4 MiB
        let listener = try await Self.listener { _, _ in
            let sent = DeadlineCounter()
            return .init(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: AsyncThrowingStream(unfolding: {
                sent.increment() <= chunks ? chunk : nil
            }))
        }
        let port = try await Self.start(listener)
        let started = Date()
        let (body, complete) = try await Task.detached {
            let socket = try Self.connect(port: port)
            defer { close(socket) }
            try Self.send(socket, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            // About 1 MiB/s: the transfer outlasts the deadline several times over.
            return try Self.readResponse(socket, bytesPerRead: 16 * 1024, pause: 0.015, giveUpAfter: 20)
        }.value
        let elapsed = Date().timeIntervalSince(started)
        await listener.stop()
        XCTAssertGreaterThan(elapsed, 2 * Self.lifetime, "The response ended too fast to cross the deadline")
        XCTAssertTrue(complete, "The response ended without the chunked terminator after \(elapsed) s")
        XCTAssertEqual(body, chunk.count * chunks)
    }

    func test_idleConnection_isClosedAtDeadline() async throws {
        let listener = try await Self.listener { _, _ in .init(statusCode: 204, headers: [:], body: AsyncThrowingStream { $0.finish() }) }
        let port = try await Self.start(listener)
        let closedAfter = try await Task.detached {
            let socket = try Self.connect(port: port)
            defer { close(socket) }
            return try Self.secondsUntilClosed(socket, trickle: nil, giveUpAfter: 10)
        }.value
        await listener.stop()
        XCTAssertLessThan(closedAfter, 5 * Self.lifetime, "An idle connection outlived the deadline")
    }

    func test_tricklingRequestHeaders_areCutAtDeadline() async throws {
        let listener = try await Self.listener { _, _ in .init(statusCode: 204, headers: [:], body: AsyncThrowingStream { $0.finish() }) }
        let port = try await Self.start(listener)
        let closedAfter = try await Task.detached {
            let socket = try Self.connect(port: port)
            defer { close(socket) }
            try Self.send(socket, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n")
            // One header byte every 100 ms keeps bytes flowing without ever ending the request.
            return try Self.secondsUntilClosed(socket, trickle: "X", giveUpAfter: 10)
        }.value
        await listener.stop()
        XCTAssertLessThan(closedAfter, 5 * Self.lifetime, "A request that never finished outlived the deadline")
    }

    func test_stalledReader_isCutAtDeadline() async throws {
        let cancelled = DeadlineCounter()
        let listener = try await Self.listener { _, _ in
            .init(statusCode: 200, headers: ["Content-Type": "application/octet-stream"], body: AsyncThrowingStream(unfolding: {
                Data(repeating: 0, count: 64 * 1024)
            }), cancel: { _ = cancelled.increment() })
        }
        let port = try await Self.start(listener)
        let socket = try Self.connect(port: port)
        defer { close(socket) }
        try Self.send(socket, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        // The client never reads, so the socket buffers fill and response writes stop completing.
        let started = Date()
        while cancelled.value == 0, Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = Date().timeIntervalSince(started)
        await listener.stop()
        XCTAssertLessThan(elapsed, 5 * Self.lifetime, "A response nobody reads outlived the deadline")
    }

    private static func listener(_ handler: @escaping DicomWebHTTPListener.Handler) async throws -> DicomWebHTTPListener {
        var configuration = DicomWebHTTPListenerConfiguration()
        configuration.connectionLifetime = lifetime
        return DicomWebHTTPListener(configuration: configuration, handler: handler)
    }
    private static func start(_ listener: DicomWebHTTPListener) async throws -> UInt16 {
        let root = try await listener.start()
        return UInt16(try XCTUnwrap(root.port))
    }
    private static func connect(port: UInt16) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EIO) }
        // A small receive buffer makes the reader's pace, not the kernel, decide when writes complete.
        var size: Int32 = 16 * 1024
        setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { close(socket); throw POSIXError(.ECONNREFUSED) }
        return socket
    }
    private static func send(_ socket: Int32, _ text: String) throws {
        let bytes = Array(text.utf8)
        guard Darwin.send(socket, bytes, bytes.count, 0) == bytes.count else { throw POSIXError(.EPIPE) }
    }
    /// Reads until the server closes; returns the decoded chunked body size and whether the terminator arrived.
    private static func readResponse(_ socket: Int32, bytesPerRead: Int, pause: TimeInterval,
                                     giveUpAfter limit: TimeInterval) throws -> (Int, Bool) {
        var raw = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: bytesPerRead)
        let started = Date()
        while Date().timeIntervalSince(started) < limit {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                break
            }
            raw.append(contentsOf: buffer[..<count])
            Thread.sleep(forTimeInterval: pause)
        }
        return decodeChunked(raw)
    }
    private static func decodeChunked(_ raw: [UInt8]) -> (Int, Bool) {
        let crlf: [UInt8] = [13, 10]
        func lineEnd(from start: Int) -> Int? {
            guard start + 1 < raw.count else { return nil }
            return (start..<(raw.count - 1)).first { raw[$0] == crlf[0] && raw[$0 + 1] == crlf[1] }
        }
        guard let head = (0..<max(0, raw.count - 3)).first(where: { raw[$0..<($0 + 4)].elementsEqual([13, 10, 13, 10]) }) else {
            return (0, false)
        }
        var cursor = head + 4
        var body = 0
        while let end = lineEnd(from: cursor),
              let size = Int(String(decoding: raw[cursor..<end], as: UTF8.self), radix: 16) {
            if size == 0 { return (body, true) }
            body += size
            cursor = end + 2 + size + 2
        }
        return (body, false)
    }
    /// Seconds until the server closes the connection, optionally sending one byte every 100 ms.
    private static func secondsUntilClosed(_ socket: Int32, trickle: String?, giveUpAfter limit: TimeInterval) throws -> TimeInterval {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let started = Date()
        while Date().timeIntervalSince(started) < limit {
            if let trickle {
                let bytes = Array(trickle.utf8)
                if Darwin.send(socket, bytes, bytes.count, 0) < 0 { break }
            }
            let count = recv(socket, &buffer, buffer.count, 0)
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { break }
        }
        return Date().timeIntervalSince(started)
    }
}

private final class DeadlineCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}
