import Foundation
#if canImport(Network)
import Network

/// One connection belongs to one authentication attempt. Actor isolation owns framing and message IDs.
actor DicomLDAPConnection {
    private let connection: NWConnection
    private let tlsContext: DicomAppliedTLSContext?
    private let queue = DispatchQueue(label: "DicomLDAPConnection")
    private let deadline: DispatchTime
    private let configuration: DicomLDAPConfiguration
    private var buffer = Data()
    private var receivedBytes = 0
    private var messageID = 0

    init(configuration: DicomLDAPConfiguration) throws {
        self.configuration = configuration
        deadline = .now() + configuration.timeout
        let tls = DicomTLSConfiguration(mode: configuration.transport == .ldaps ? .enabled : .disabled,
            serverName: configuration.host, material: .init(trustStorePath: configuration.trustStorePath),
            securityProfile: .bcp195RFC8996)
        let prepared: DicomPreparedNetworkParameters
        do { prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .client) }
        catch { throw DicomLDAPError.tlsFailure }
        tlsContext = prepared.tlsContext
        connection = NWConnection(host: .init(configuration.host), port: .init(rawValue: configuration.port)!,
                                  using: prepared.parameters)
    }

    func open() async throws {
        let connection = connection; let queue = queue
        try await perform { (completion: DicomLDAPNetworkCompletion<Void>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(.success(()))
                case .failed(let error): completion.finish(.failure(Self.failure(error)))
                case .waiting(let error): completion.finish(.failure(Self.failure(error)))
                case .cancelled: completion.finish(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
    }

    func close() { connection.cancel() }

    func bind(dn: String, password: Data) async throws {
        messageID += 1
        try await send(DicomLDAPWire.bind(messageID, dn: dn, password: password))
        guard try await receive() == .bind else { throw DicomLDAPError.malformedResponse }
    }

    func search(base: String, filter: DicomLDAPEqualityFilter, attributes: [String], limit: Int) async throws
        -> [DicomLDAPWire.Entry] {
        messageID += 1
        try await send(DicomLDAPWire.search(messageID, base: base, filter: filter, attributes: attributes,
            limit: limit, seconds: max(1, Int(ceil(configuration.timeout)))))
        var entries: [DicomLDAPWire.Entry] = []
        while true {
            switch try await receive() {
            case .entry(let entry):
                guard entries.count < limit else { throw DicomLDAPError.responseLimit }
                entries.append(entry)
            case .done: return entries // No partial result is returned without successful SearchResultDone.
            case .bind: throw DicomLDAPError.malformedResponse
            }
        }
    }

    private func send(_ data: Data) async throws {
        let connection = connection
        try await perform { (completion: DicomLDAPNetworkCompletion<Void>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { completion.finish(.failure(Self.failure(error))) }
                else { completion.finish(.success(())) }
            })
        }
    }

    private func receive() async throws -> DicomLDAPWire.Response {
        while true {
            try Task.checkCancellation()
            if let count = try DicomLDAPWire.frameLength(buffer, maximum: configuration.maximumResponseBytes),
               buffer.count >= count {
                let frame = Data(buffer.prefix(count)); buffer.removeFirst(count)
                return try DicomLDAPWire.parse(frame, expectedID: messageID, maximum: configuration.maximumResponseBytes)
            }
            let remaining = configuration.maximumResponseBytes - receivedBytes
            guard remaining > 0 else { throw DicomLDAPError.responseLimit }
            let connection = connection
            let bytes: Data = try await perform { completion in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(65_536, remaining)) { data, _, _, error in
                    if let error { completion.finish(.failure(Self.failure(error))) }
                    else if let data, !data.isEmpty { completion.finish(.success(data)) }
                    else { completion.finish(.failure(DicomLDAPError.truncatedResponse)) }
                }
            }
            receivedBytes += bytes.count; buffer.append(bytes)
        }
    }

    private func perform<T: Sendable>(_ start: @escaping @Sendable (DicomLDAPNetworkCompletion<T>) -> Void) async throws -> T {
        let connection = connection
        try Task.checkCancellation()
        guard DispatchTime.now() < deadline else { throw DicomLDAPError.timeout }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let completion = DicomLDAPNetworkCompletion(continuation)
                let timer = DispatchWorkItem { completion.finish(.failure(DicomLDAPError.timeout)); connection.cancel() }
                completion.setTimer(timer)
                queue.asyncAfter(deadline: deadline, execute: timer)
                start(completion)
                if Task.isCancelled { completion.finish(.failure(CancellationError())); connection.cancel() }
            }
        } onCancel: { connection.cancel() }
    }

    private nonisolated static func failure(_ error: NWError) -> DicomLDAPError {
        if case .tls = error { return .tlsFailure }
        return .unavailable
    }
}

/// Network and deadline callbacks race; only the lock winner resumes the continuation.
private final class DicomLDAPNetworkCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var timer: DispatchWorkItem?
    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }
    func setTimer(_ timer: DispatchWorkItem) { lock.withLock { self.timer = timer } }
    func finish(_ result: Result<T, any Error>) {
        let saved = lock.withLock {
            let saved = continuation; continuation = nil
            timer?.cancel(); timer = nil
            return saved
        }
        saved?.resume(with: result)
    }
}
#endif
