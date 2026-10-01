import Foundation

public enum DicomLifecycleRecordOutcome: Equatable, Sendable { case recorded, alreadyRecorded }

/// A durable implementation MUST commit the event and ALL obligations in one transaction,
/// idempotently by eventID. On failure neither may commit. Recovery must recover both together.
/// Separate event/outbox database writes do not satisfy this contract.
public protocol DicomLifecycleEventSink: Sendable {
    func record(_ event: DicomLifecycleEvent, obligations: [DicomDeliveryItem]) async throws -> DicomLifecycleRecordOutcome
}

/// Nonthrowing boundary for coordinators. Hosts own durable retry/replay of failed publications.
/// Awaiting this hook preserves ordering, but its outcome never changes the ingest/transfer result.
public protocol DicomLifecycleEventEmitting: Sendable {
    func emit(_ event: DicomLifecycleEvent) async
}

/// Test-only, non-durable sink. An injected outbox must implement atomic enqueue.
/// This actor is NOT a cross-store crash transaction, even when the injected outbox is durable.
public actor DicomInMemoryLifecycleEventSink: DicomLifecycleEventSink {
    private let outbox: any DicomDeliveryOutboxStoring
    private let gate = DicomIngestGate()
    private var recorded: [String: DicomLifecycleEvent] = [:]
    public init(outbox: any DicomDeliveryOutboxStoring = DicomInMemoryDeliveryOutbox()) {
        self.outbox = outbox
    }
    public func events() -> [DicomLifecycleEvent] { recorded.values.sorted { $0.eventID < $1.eventID } }
    public func record(_ event: DicomLifecycleEvent, obligations: [DicomDeliveryItem]) async throws -> DicomLifecycleRecordOutcome {
        // Actor methods reenter while enqueue suspends; serialize duplicate checks across that await.
        await gate.acquire()
        do {
            if recorded[event.eventID] != nil {
                await gate.release()
                return .alreadyRecorded
            }
            try await outbox.enqueue(obligations)
            recorded[event.eventID] = event
            await gate.release()
            return .recorded
        } catch {
            await gate.release()
            throw error
        }
    }
}
