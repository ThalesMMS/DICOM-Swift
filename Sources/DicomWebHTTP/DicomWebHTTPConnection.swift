import Foundation
import Network
import DicomCore

final class DicomWebHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let configuration: DicomWebHTTPListenerConfiguration
    private let handler: DicomWebHTTPListener.Handler
    private let queue = DispatchQueue(label: "DicomWebHTTP.connection")
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private let channel = HTTPByteChannel()
    private let notifications: DicomWebNotificationHub?
    private var webSocket: DicomWebHTTPWebSocketSession?
    init(connection: NWConnection, configuration: DicomWebHTTPListenerConfiguration, handler: @escaping DicomWebHTTPListener.Handler, notifications: DicomWebNotificationHub?) {
        self.connection = connection; self.configuration = configuration; self.handler = handler
        self.notifications = notifications
    }
    func start(completion: @escaping @Sendable () -> Void) {
        connection.start(queue: queue)
        // The deadline covers waiting for and reading a request; response writes push it back,
        // so a large response to a slow reader runs as long as it progresses.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.connectionLifetime)
        timer.setEventHandler { [weak self] in self?.cancel() }
        lock.withLock { self.timer = timer }
        timer.resume()
        let receiver = Task { [self] in
            do {
                while !Task.isCancelled {
                    let (data, finished) = try await receive()
                    if let data, !data.isEmpty { try await channel.put(data) }
                    if finished { break }
                }
            } catch {}
            await channel.close()
            lock.withLock { self.task?.cancel() }
        }
        let task = Task { [self] in
            await run()
            cancel()
            await receiver.value
            completion()
        }
        lock.withLock { self.receiver = receiver; self.task = task }
    }
    func stop() async {
        let session = lock.withLock { webSocket }
        await session?.close(code: 1001)
        cancel()
    }
    func cancel() {
        lock.withLock { task?.cancel(); receiver?.cancel(); timer?.cancel(); timer = nil }
        connection.cancel()
        Task { await channel.close() }
    }
    private func extendDeadline() {
        lock.withLock { timer?.schedule(deadline: .now() + configuration.connectionLifetime) }
    }
    func waitUntilIdle() async {
        let task = lock.withLock { self.task }
        await task?.value
    }
    private func receive() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data, complete)) }
            }
        }
    }
    private func write(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func run() async {
        let reader = HTTPRequestReader(channel: channel, configuration: configuration)
        do {
            for count in 0..<configuration.maximumRequestsPerConnection {
                var localPort: UInt16?
                if case .hostPort(_, let port) = connection.currentPath?.localEndpoint { localPort = port.rawValue }
                let parsed = try await reader.request(tls: configuration.tls?.mode == .enabled, localPort: localPort)
                if parsed.expectContinue { try await write(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
                let body = AsyncThrowingStream<Data, Error>(unfolding: {
                    do { return try await reader.bodyChunk() }
                    catch is HTTPFailure { throw DicomWebHTTPBodyError.malformed }
                })
                let response = await handler(parsed.request, body)
                if response.statusCode < 400 {
                    do { while try await reader.bodyChunk() != nil {} }
                    catch { response.cancel(); throw error }
                }
                if response.statusCode == 101,
                   response.headers.first(where: { $0.key.lowercased() == "upgrade" })?.value.lowercased() == "websocket",
                   let notifications {
                    let headers = response.headers.filter { !["content-length", "transfer-encoding"].contains($0.key.lowercased()) }
                    guard headers.allSatisfy({ !$0.key.contains(where: { $0.isWhitespace || $0 == ":" }) && !$0.value.contains("\r") && !$0.value.contains("\n") }) else { throw HTTPFailure(status: 500) }
                    let head = "HTTP/1.1 101 Switching Protocols\r\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
                    let session = DicomWebHTTPWebSocketSession(connection: connection, maximumBytes: configuration.maximumWebSocketFrameBytes)
                    lock.withLock { webSocket = session; timer?.cancel(); timer = nil }
                    try await write(Data(head.utf8))
                    let ae = parsed.request.url.lastPathComponent
                    let guarded = AuthorizedWebNotificationConnection(connection: session,
                        authorize: response.authorizeNotification)
                    let id = await notifications.register(guarded, ae: ae)
                    await session.run(buffer: reader.takeBufferedBytes(), channel: channel)
                    await notifications.unregister(id, ae: ae)
                    return
                }
                let close = parsed.close || count + 1 == configuration.maximumRequestsPerConnection || response.statusCode >= 400
                var headers = response.headers.filter { !["content-length", "transfer-encoding", "connection"].contains($0.key.lowercased()) }
                // 204 and 304 end at the header block (RFC 9112 6.3); a chunked terminator would be read as the next response.
                let bodyless = response.statusCode == 204 || response.statusCode == 304
                if !bodyless { headers["Transfer-Encoding"] = "chunked" }
                headers["Connection"] = close ? "close" : "keep-alive"
                guard headers.allSatisfy({ !$0.key.contains(where: { $0.isWhitespace || $0 == ":" }) && !$0.value.contains("\r") && !$0.value.contains("\n") }) else {
                    throw HTTPFailure(status: 500)
                }
                let head = "HTTP/1.1 \(response.statusCode) \(Self.reason(response.statusCode))\r\n" + headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
                try await write(Data(head.utf8))
                extendDeadline()
                if bodyless {
                    response.cancel()
                    if close { return }
                    continue
                }
                do {
                    try await withTaskCancellationHandler {
                        for try await chunk in response.body where !chunk.isEmpty {
                            try await write(Data("\(String(chunk.count, radix: 16))\r\n".utf8))
                            try await write(chunk)
                            try await write(Data("\r\n".utf8))
                            extendDeadline()
                        }
                        try await write(Data("0\r\n\r\n".utf8))
                        extendDeadline()
                    } onCancel: { response.cancel() }
                } catch { response.cancel(); return }
                if close { return }

            }
        } catch let error as HTTPFailure {
            try? await write(Data("HTTP/1.1 \(error.status) \(Self.reason(error.status))\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        } catch {}
    }
    private static func reason(_ status: Int) -> String {
        [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
         405: "Method Not Allowed", 406: "Not Acceptable", 409: "Conflict", 413: "Payload Too Large", 415: "Unsupported Media Type",
         431: "Request Header Fields Too Large", 500: "Internal Server Error", 501: "Not Implemented"][status] ?? "Response"
    }
}

/// A single 64 KiB receive slot supplies backpressure to Network.framework.
actor HTTPByteChannel {
    private var value: Data?
    private var consumer: CheckedContinuation<Data, Error>?
    private var producer: CheckedContinuation<Void, Error>?
    private var closed = false
    func put(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        if let consumer { self.consumer = nil; consumer.resume(returning: data); return }
        value = data
        try await withCheckedThrowingContinuation { producer = $0 }
    }
    func next() async throws -> Data {
        if let value {
            self.value = nil; let saved = producer; producer = nil; saved?.resume(); return value
        }
        guard !closed else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { consumer = $0 }
    }
    func close() {
        closed = true
        consumer?.resume(throwing: CancellationError()); consumer = nil
        producer?.resume(throwing: CancellationError()); producer = nil
    }
}

private struct AuthorizedWebNotificationConnection: DicomWebNotificationConnection {
    let connection: any DicomWebNotificationConnection
    let authorize: (@Sendable (String) async throws -> Void)?
    func send(text: String) async throws {
        try await authorize?(text)
        try await connection.send(text: text)
    }
    func close() async { await connection.close() }
}
