import Foundation
#if canImport(Network)
import Network
#endif

public struct DicomAuditSyslogMessage: Codable, Equatable, Sendable {
    public let priority: Int
    public let timestamp: String
    public let host: String
    public let application: String
    public let processID: String
    public let messageID: String
    public let xml: String
    public let event: DicomAuditEvent
}

public enum DicomAuditSyslogFraming {
    public static func message(_ event: DicomAuditEvent, facility: Int = 10,
                               host: String = "-", application: String = "DICOM-Swift", processID: String = "-") throws -> Data {
        guard (0...23).contains(facility), token(host, limit: 255), token(application, limit: 48),
              token(processID, limit: 128) else { throw DicomAuditError.invalidConfiguration }
        let severity: Int
        switch event.eventIdentification.eventOutcomeIndicator {
        case .success: severity = 6
        case .minorFailure: severity = 4
        case .seriousFailure: severity = 3
        case .majorFailure: severity = 2
        }
        let timestamp = ISO8601DateFormatter().string(from: event.eventIdentification.eventDateTime)
        let xml = DicomAuditMessageXML.serialize(event)
        let header = "<\(facility * 8 + severity)>1 \(timestamp) \(DicomAuditPHIMinimizer.text(host)) \(DicomAuditPHIMinimizer.text(application)) \(DicomAuditPHIMinimizer.text(processID)) DICOM - "
        return Data((header + "\u{FEFF}" + xml).utf8)
    }
    public static func frame(_ message: Data) -> Data { Data("\(message.count) ".utf8) + message }
    /// Incremental octet-counting parser, including fragmented length prefixes and coalesced frames.
    public static func extract(from buffer: inout Data, maximumBytes: Int = 4 * 1024 * 1024) throws -> [Data] {
        var result: [Data] = []
        while !buffer.isEmpty {
            guard let space = buffer.firstIndex(of: 32) else {
                guard buffer.count <= 10, buffer.allSatisfy({ (48...57).contains($0) }) else { throw DicomAuditError.invalidFrame }
                break
            }
            let prefix = buffer[..<space]
            guard !prefix.isEmpty, prefix.count <= 10, prefix.first != 48,
                  prefix.allSatisfy({ (48...57).contains($0) }),
                  let count = Int(String(decoding: prefix, as: UTF8.self)), count <= maximumBytes else {
                throw DicomAuditError.invalidFrame
            }
            let headerCount = prefix.count + 1
            guard buffer.count >= headerCount + count else { break }
            result.append(Data(buffer.dropFirst(headerCount).prefix(count)))
            buffer.removeFirst(headerCount + count)
        }
        return result
    }
    public static func parse(_ data: Data) throws -> DicomAuditSyslogMessage {
        guard let text = String(data: data, encoding: .utf8) else { throw DicomAuditError.invalidFrame }
        let parts = text.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 8, parts[0].first == "<", parts[0].hasSuffix(">1"),
              let priority = Int(parts[0].dropFirst().dropLast(2)), (0...191).contains(priority),
              ISO8601DateFormatter().date(from: parts[1]) != nil, token(parts[2], limit: 255),
              token(parts[3], limit: 48), token(parts[4], limit: 128), parts[5] == "DICOM", parts[6] == "-" else {
            throw DicomAuditError.invalidFrame
        }
        let xml = parts[7].hasPrefix("\u{FEFF}") ? String(parts[7].dropFirst()) : parts[7]
        let event = DicomAuditPHIMinimizer.minimize(try DicomAuditMessageXML.parse(Data(xml.utf8)))
        return .init(priority: priority, timestamp: parts[1], host: DicomAuditPHIMinimizer.text(parts[2]),
                     application: DicomAuditPHIMinimizer.text(parts[3]), processID: DicomAuditPHIMinimizer.text(parts[4]),
                     messageID: parts[5], xml: DicomAuditMessageXML.serialize(event), event: event)
    }
    private static func token(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

#if canImport(Network)
private final class AuditNetworkResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, any Error>) {
        let saved = lock.withLock { let saved = continuation; continuation = nil; return saved }
        saved?.resume(with: result)
    }
}

/// No connection is opened until record is explicitly invoked on a configured sink.
/// Completion means local TCP/TLS delivery, not an application-level acknowledgement by the collector.
public final class DicomAuditSyslogSink: DicomAuditSink, Sendable {
    private let host: String
    private let port: UInt16
    private let tls: DicomTLSConfiguration
    private let timeout: TimeInterval
    private let attempts: Int
    private let facility: Int
    private let sourceHost: String
    private let application: String
    public init(host: String, port: UInt16, tls: DicomTLSConfiguration = .disabled,
                timeout: TimeInterval = 5, maximumAttempts: Int = 3, facility: Int = 10,
                sourceHost: String = "-", application: String = "DICOM-Swift") throws {
        guard !host.isEmpty, port > 0, timeout.isFinite, timeout > 0, timeout <= 300,
              (1...5).contains(maximumAttempts), (0...23).contains(facility) else { throw DicomAuditError.invalidConfiguration }
        self.host = host; self.port = port; self.timeout = timeout; self.attempts = maximumAttempts
        var secured = tls
        if secured.mode == .enabled {
            secured.serverName = secured.serverName ?? host; secured.securityProfile = .bcp195RFC8996
        }
        self.tls = secured; self.facility = facility; self.sourceHost = sourceHost; self.application = application
    }
    public func record(_ event: DicomAuditEvent) async throws {
        let bytes = DicomAuditSyslogFraming.frame(try DicomAuditSyslogFraming.message(event,
            facility: facility, host: sourceHost, application: application))
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw DicomAuditError.timeout }
            do {
                let slice = min(timeout / Double(attempts), Double(remaining.components.seconds)
                    + Double(remaining.components.attoseconds) / 1e18)
                try await send(bytes, timeout: slice)
                return
            } catch is CancellationError { throw CancellationError() }
            catch {
                if attempt == attempts - 1 || ContinuousClock.now >= deadline { throw DicomAuditError.sinkUnavailable }
                let backoff = min(0.1 * pow(2, Double(attempt)), 1)
                let remaining = ContinuousClock.now.duration(to: deadline)
                try await Task.sleep(for: min(.seconds(backoff), remaining))
            }
        }
    }
    public func flush() async throws {} // Each record awaits its send completion.
    private func send(_ data: Data, timeout: TimeInterval) async throws {
        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .client)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: prepared.parameters)
        let queue = DispatchQueue(label: "DicomAuditSyslog.send")
        defer { connection.stateUpdateHandler = nil; connection.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result = AuditNetworkResult(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: data, completion: .contentProcessed { error in
                            if let error { result.finish(.failure(error)) } else { result.finish(.success(())) }
                        })
                    case .failed(let error): result.finish(.failure(error))
                    case .cancelled: result.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    result.finish(.failure(DicomAuditError.timeout)); connection.cancel()
                }
                connection.start(queue: queue)
                if Task.isCancelled { connection.cancel() }
            }
        } onCancel: { connection.cancel() }
        withExtendedLifetime(prepared.tlsContext) {}
    }
}

/// Diagnostic receiver, bound to numeric loopback only. Storage and connections are bounded.
public final class DicomAuditSyslogReceiver: @unchecked Sendable {
    private let port: UInt16
    private let tls: DicomTLSConfiguration
    private let queue = DispatchQueue(label: "DicomAuditSyslog.receive")
    private let lock = NSLock()
    private var listener: NWListener?
    private var tlsContext: DicomAppliedTLSContext?
    private var connections: [UUID: NWConnection] = [:]
    private var storage: [DicomAuditSyslogMessage] = []
    public var received: [DicomAuditSyslogMessage] { lock.withLock { storage } }
    public init(port: UInt16 = 0, tls: DicomTLSConfiguration = .disabled) {
        self.port = port; self.tls = tls
    }
    public func start() async throws -> UInt16 {
        var configuration = tls
        if configuration.mode == .enabled { configuration.securityProfile = .bcp195RFC8996 }
        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: configuration, role: .server)
        if configuration.mode == .enabled, prepared.tlsContext?.hasLocalIdentity != true {
            throw DicomAuditError.invalidConfiguration
        }
        prepared.parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: prepared.parameters, on: NWEndpoint.Port(rawValue: port)!)
        guard lock.withLock({
            if self.listener != nil { return false }
            self.listener = listener; self.tlsContext = prepared.tlsContext; return true
        }) else { throw DicomAuditError.invalidConfiguration }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let result = AuditNetworkResult<UInt16>(continuation)
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if let port = listener.port { result.finish(.success(port.rawValue)) }
                            else { result.finish(.failure(DicomAuditError.sinkUnavailable)) }
                        case .failed(let error): result.finish(.failure(error))
                        case .cancelled: result.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    queue.asyncAfter(deadline: .now() + 5) { result.finish(.failure(DicomAuditError.timeout)) }
                    listener.start(queue: queue)
                    if Task.isCancelled { listener.cancel() }
                }
            } onCancel: { listener.cancel() }
        } catch { stop(); throw error }
    }
    public func stop() {
        let active = lock.withLock {
            let active = (listener, Array(connections.values)); listener = nil; connections.removeAll()
            tlsContext = nil; return active
        }
        active.0?.cancel(); active.1.forEach { $0.cancel() }
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let accepted = lock.withLock {
            guard listener != nil, connections.count < 32 else { return false }
            connections[id] = connection; return true
        }
        guard accepted else { connection.cancel(); return }
        connection.start(queue: queue)
        receive(connection, id: id, buffer: Data())
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.close(connection, id: id) }
    }
    private func close(_ connection: NWConnection, id: UUID) {
        _ = lock.withLock { connections.removeValue(forKey: id) }; connection.cancel()
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                let frames = try DicomAuditSyslogFraming.extract(from: &buffer)
                let messages = try frames.map(DicomAuditSyslogFraming.parse)
                let accepted = self.lock.withLock {
                    guard self.storage.count + messages.count <= 10000 else { return false }
                    self.storage.append(contentsOf: messages); return true
                }
                guard accepted else { throw DicomAuditError.invalidFrame }
                if done || error != nil { self.close(connection, id: id) }
                else { self.receive(connection, id: id, buffer: buffer) }
            } catch { self.close(connection, id: id) }
        }
    }
    deinit { listener?.cancel(); connections.values.forEach { $0.cancel() } }
}
#endif
