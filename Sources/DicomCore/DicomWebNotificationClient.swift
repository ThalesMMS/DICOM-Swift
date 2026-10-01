import Foundation

public protocol DicomWebNotificationReceiving: Sendable {
    func receive() async throws -> String
    func ping() async throws
    func cancel()
}

public struct DicomWebNotificationClientConfiguration: Sendable {
    public var maximumReconnects = 5
    public var initialBackoff: TimeInterval = 0.5
    public var maximumBackoff: TimeInterval = 30
    public var pingInterval: TimeInterval = 20
    public var pingTimeout: TimeInterval = 10
    public init() {}
}

/// A reconnect always emits a gap. The consumer must retrieve state and re-subscribe as needed.
public struct DicomWebNotificationClient: Sendable {
    public enum Signal: Sendable {
        case connected
        case gap
        case event(DicomUnifiedProcedureStepEvent)
    }
    public typealias Factory = @Sendable (URLRequest) async throws -> any DicomWebNotificationReceiving
    public let configuration: DicomWebNotificationClientConfiguration
    private let factory: Factory
    public init(configuration: DicomWebNotificationClientConfiguration = .init(),
                factory: @escaping Factory = { request in URLSessionNotificationConnection(request: request) }) {
        self.configuration = configuration
        self.factory = factory
    }
    public func connect(to url: URL, headers: [String: String] = [:]) -> AsyncThrowingStream<Signal, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
                      let host = url.host, !host.isEmpty,
                      configuration.maximumReconnects >= 0, configuration.initialBackoff >= 0,
                      configuration.maximumBackoff >= configuration.initialBackoff,
                      configuration.pingInterval > 0, configuration.pingTimeout > 0 else {
                    continuation.finish(throwing: DicomWebError(kind: .badRequest)); return
                }
                var request = URLRequest(url: url)
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                request.setValue("application/dicom+json", forHTTPHeaderField: "Content-Type")
                request.setValue("dicom", forHTTPHeaderField: "Sec-WebSocket-Protocol")
                var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                origin.scheme = url.scheme == "wss" ? "https" : "http"
                origin.path = ""; origin.query = nil
                request.setValue(origin.url!.absoluteString, forHTTPHeaderField: "Origin")
                var attempts = 0
                while !Task.isCancelled {
                    do {
                        if attempts > 0 { continuation.yield(.gap) }
                        let connection = try await factory(request)
                        defer { connection.cancel() }
                        try await withTaskCancellationHandler {
                            try await Self.ping(connection, timeout: configuration.pingTimeout)
                            continuation.yield(.connected)
                            try await withThrowingTaskGroup(of: Void.self) { group in
                                group.addTask {
                                    while !Task.isCancelled {
                                        let text = try await connection.receive()
                                        continuation.yield(.event(try Self.decode(text)))
                                    }
                                }
                                group.addTask {
                                    while !Task.isCancelled {
                                        try await Task.sleep(for: .seconds(configuration.pingInterval))
                                        try await Self.ping(connection, timeout: configuration.pingTimeout)
                                    }
                                }
                                do { _ = try await group.next() }
                                catch { connection.cancel(); group.cancelAll(); throw error }
                                connection.cancel(); group.cancelAll()
                            }
                        } onCancel: { connection.cancel() }
                    } catch {
                        if Task.isCancelled { break }
                        guard attempts < configuration.maximumReconnects else { continuation.finish(throwing: error); return }
                    }
                    attempts += 1
                    do {
                        try await Task.sleep(for: .seconds(min(configuration.maximumBackoff,
                            configuration.initialBackoff * pow(2, Double(min(attempts - 1, 30))))))
                    } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private static func ping(_ connection: any DicomWebNotificationReceiving, timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await connection.ping() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                connection.cancel()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
    public static func decode(_ text: String) throws -> DicomUnifiedProcedureStepEvent {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw DicomWebError(kind: .badRequest) }
        let data = try DicomJSONCodec.decode(object: object).dataSet
        guard data.string(for: 0x00000002) == "1.2.840.10008.5.1.4.34.6.4",
              let uid = data.string(for: 0x00001000), !uid.isEmpty,
              case .unsignedIntegers(let ids) = data[0x00001002]?.value,
              ids.count == 1 else { throw DicomWebError(kind: .badRequest) }
        let payload: DicomUnifiedProcedureStepEvent.Payload
        switch ids[0] {
        case 1:
            guard let state = DicomUnifiedProcedureStepState(rawValue: data.string(for: 0x00741000) ?? "") else { throw DicomWebError(kind: .badRequest) }
            payload = .state(state, inputReadiness: data.string(for: 0x00404041) ?? "", cancellation: data)
        case 2: payload = .cancel(requestingAE: data.string(for: 0x00741236) ?? "", information: data)
        case 3: payload = .progress(data.sequenceItems(for: 0x00741002).first?.dataSet ?? .init())
        case 4:
            guard let status = DicomUnifiedProcedureStepSCPStatus(rawValue: data.string(for: 0x00741242) ?? ""),
                  let subscriptions = DicomUnifiedProcedureStepListStatus(rawValue: data.string(for: 0x00741244) ?? ""),
                  let instances = DicomUnifiedProcedureStepListStatus(rawValue: data.string(for: 0x00741246) ?? "") else { throw DicomWebError(kind: .badRequest) }
            payload = .scpStatus(status, subscriptions: subscriptions, instances: instances)
        case 5: payload = .assigned(.init(elements: data.elements.filter { $0.group != 0 }))
        default: throw DicomWebError(kind: .badRequest)
        }
        return .init(sopInstanceUID: uid, payload: payload)
    }
}

public final class URLSessionNotificationConnection: DicomWebNotificationReceiving, Sendable {
    private let task: URLSessionWebSocketTask
    public init(request: URLRequest) {
        task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 1024 * 1024
        task.resume()
    }
    public func receive() async throws -> String {
        guard case .string(let text) = try await task.receive() else { throw DicomWebError(kind: .badRequest) }
        return text
    }
    public func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    public func cancel() { task.cancel(with: .goingAway, reason: nil) }
}
