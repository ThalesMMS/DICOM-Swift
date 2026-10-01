import Foundation
import Network
import DicomCore

public struct DicomWebHTTPListenerConfiguration: Sendable {
    public var port: UInt16 = 0
    public var loopbackOnly = true
    public var bindAddress: String?
    public var tls: DicomTLSConfiguration?
    public var maximumHeaderBytes = 64 * 1024
    public var maximumBodyBytes = 1024 * 1024 * 1024
    public var maximumConnections = 32
    public var maximumWebSocketFrameBytes = 1024 * 1024
    public var maximumRequestsPerConnection = 100
    public var connectionLifetime: TimeInterval = 120
    public init() {}
}

public final class DicomWebHTTPListener: DicomWebServerTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (DicomWebHTTPRequest, AsyncThrowingStream<Data, Error>) async -> DicomWebHTTPStreamedResponse
    private let configuration: DicomWebHTTPListenerConfiguration
    private let server: DicomWebServer?
    private let handler: Handler
    private let notifications: DicomWebNotificationHub?
    private let queue = DispatchQueue(label: "DicomWebHTTP.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [UUID: DicomWebHTTPConnection] = [:]

    public init(server: DicomWebServer, configuration: DicomWebHTTPListenerConfiguration = .init()) {
        self.configuration = configuration
        self.server = server
        self.notifications = server.notifications
        handler = { await server.handleStreaming($0, body: $1) }
    }
    public init(configuration: DicomWebHTTPListenerConfiguration = .init(), handler: @escaping Handler) {
        self.configuration = configuration
        self.handler = handler
        self.server = nil
        self.notifications = nil
    }
    public func start() async throws -> URL {
        let bind = configuration.bindAddress ?? (configuration.loopbackOnly ? "127.0.0.1" : "")
        if configuration.loopbackOnly {
            do {
                _ = try DicomExposurePolicy(mode: .localOnly, requireTLS: false, requireAuthentication: false)
                    .validate(bindAddress: bind, tlsEnabled: false, authenticationConfigured: false)
            } catch { throw HTTPFailure(status: 400) }
        }
        try await server?.validateExposure(bindAddress: bind,
            tlsEnabled: configuration.tls?.mode == .enabled)
        guard configuration.maximumHeaderBytes > 0, configuration.maximumBodyBytes >= 0,
              configuration.maximumConnections > 0, configuration.maximumRequestsPerConnection > 0,
              configuration.connectionLifetime > 0 else { throw HTTPFailure(status: 400) }
        let parameters = try configuration.tls.map(DicomWebServerTLS.parameters) ?? NWParameters.tcp
        if !bind.isEmpty {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind),
                port: NWEndpoint.Port(rawValue: configuration.port)!)
        }
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: configuration.port)!)
        guard lock.withLock({ if self.listener != nil { return false }; self.listener = listener; return true }) else {
            throw HTTPFailure(status: 409)
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = HTTPListenerReady()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready.set(continuation)
                listener.stateUpdateHandler = { [configuration] state in
                    switch state {
                    case .ready:
                        guard let port = listener.port else { ready.finish(.failure(HTTPFailure(status: 500))); return }
                        let scheme = configuration.tls?.mode == .enabled ? "https" : "http"
                        ready.finish(.success(URL(string: "\(scheme)://127.0.0.1:\(port.rawValue)")!))
                    case .failed(let error): ready.finish(.failure(error))
                    case .cancelled: ready.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        } onCancel: { listener.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let session = DicomWebHTTPConnection(connection: connection, configuration: configuration, handler: handler, notifications: notifications)
        let accepted = lock.withLock {
            guard listener != nil, connections.count < configuration.maximumConnections else { return false }
            connections[id] = session
            session.start { [weak self] in _ = self?.lock.withLock { self?.connections.removeValue(forKey: id) } }
            return true
        }
        guard accepted else { connection.cancel(); return }
    }
    /// Cancels accepted connections and waits for their request and receive tasks to finish.
    public func stop() async {
        let active = lock.withLock { () -> (NWListener?, [DicomWebHTTPConnection]) in
            let result = (listener, Array(connections.values))
            listener = nil; return result
        }
        active.0?.cancel()
        for connection in active.1 { await connection.stop() }
        for connection in active.1 { await connection.waitUntilIdle() }
    }
    deinit { listener?.cancel(); for connection in connections.values { connection.cancel() } }
}

private final class HTTPListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    func set(_ continuation: CheckedContinuation<URL, Error>) { lock.withLock { self.continuation = continuation } }
    func finish(_ result: Result<URL, Error>) {
        lock.withLock { let saved = continuation; continuation = nil; saved?.resume(with: result) }
    }
}

struct HTTPFailure: Error { let status: Int }
