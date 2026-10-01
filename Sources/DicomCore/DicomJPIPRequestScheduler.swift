import Foundation

/// A new window cancels the previous task; work starts only when `next` is pulled.
public actor DicomJPIPRequestScheduler {
    private let transport: DicomJPIPHTTPTransport
    private var sequence: DicomJPIPPayloadSequence?
    private var inFlight: Task<DicomJPIPLayerPayload?, Error>?
    private var retiring: Task<DicomJPIPLayerPayload?, Error>?
    private var generation: UInt64 = 0

    public init(transport: DicomJPIPHTTPTransport) { self.transport = transport }

    public func supersede(with request: DicomJPIPRequest) {
        generation &+= 1
        inFlight?.cancel()
        retiring = inFlight ?? retiring
        inFlight = nil
        sequence = transport.payloads(for: request)
    }

    public func next() async throws -> DicomJPIPLayerPayload? {
        guard let sequence else { return nil }
        if let inFlight { return try await inFlight.value }
        let current = generation
        let previous = retiring
        retiring = nil
        let task = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await sequence.next()
        }
        inFlight = task
        do {
            let payload = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard current == generation else { throw CancellationError() }
            inFlight = nil
            return payload
        } catch {
            if current == generation { inFlight = nil }
            throw error
        }
    }

    public func cancel() {
        generation &+= 1
        inFlight?.cancel()
        inFlight = nil
        sequence = nil
    }
}
