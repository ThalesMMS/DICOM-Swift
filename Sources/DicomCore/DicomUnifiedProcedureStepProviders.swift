import Foundation

public enum DicomUnifiedProcedureStepSubscriptionState: Sendable, CaseIterable {
    case notSubscribed, withLock, withoutLock
}
public struct DicomUnifiedProcedureStepGlobalSubscription: Sendable {
    public var state: DicomUnifiedProcedureStepSubscriptionState
    public var matchingKeys: DicomDataSet?
    public init(state: DicomUnifiedProcedureStepSubscriptionState, matchingKeys: DicomDataSet? = nil) {
        self.state = state; self.matchingKeys = matchingKeys
    }
}

/// Implementations serialize the closure with *all* record and subscription access, and roll back on throws.
/// Subscription calls made inside a transaction must participate in that same transaction.
public protocol DicomUnifiedProcedureStepStoring: Sendable {
    func transaction<T>(sopInstanceUID: String,
                        _ body: (inout DicomUnifiedProcedureStepRecord?) throws -> T) throws -> T
    func all() throws -> [DicomUnifiedProcedureStepRecord]
    func subscriptions(sopInstanceUID: String) -> [String: DicomUnifiedProcedureStepSubscriptionState]
    func setSubscription(sopInstanceUID: String, ae: String, state: DicomUnifiedProcedureStepSubscriptionState)
    func globalSubscriptions() -> [String: DicomUnifiedProcedureStepGlobalSubscription]
    func setGlobalSubscription(ae: String, subscription: DicomUnifiedProcedureStepGlobalSubscription)
    var listStatus: (subscriptions: DicomUnifiedProcedureStepListStatus, instances: DicomUnifiedProcedureStepListStatus) { get }
}

extension DicomUnifiedProcedureStepStoring {
    public func search(matching identifier: DicomDataSet) throws -> [DicomUnifiedProcedureStepRecord] {
        let matcher = DicomQueryMatcher(requiredKeys: Set(DicomUnifiedProcedureStepAttribute.table.filter {
            $0.matching == "R"
        }.map(\.tag)))
        return try all().filter { try matcher.matches($0.attributes, identifier: identifier) }
    }
    public func deletionLockHolders(sopInstanceUID: String) -> Set<String> {
        Set(subscriptions(sopInstanceUID: sopInstanceUID).filter { $0.value == .withLock }.keys)
    }
    public func purgeEligible(sopInstanceUID: String) throws -> Bool {
        try transaction(sopInstanceUID: sopInstanceUID) { record in
            record?.state.isFinal == true && deletionLockHolders(sopInstanceUID: sopInstanceUID).isEmpty
        }
    }
}

public final class DicomInMemoryUnifiedProcedureStepStore: DicomUnifiedProcedureStepStoring, @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var records: [String: DicomUnifiedProcedureStepRecord]
        public var subscriptions: [String: [String: DicomUnifiedProcedureStepSubscriptionState]]
        public var globalSubscriptions: [String: DicomUnifiedProcedureStepGlobalSubscription]
    }
    private let lock = NSRecursiveLock()
    private var saved = Snapshot(records: [:], subscriptions: [:], globalSubscriptions: [:])
    private var warm = false
    public init() {}
    public var listStatus: (subscriptions: DicomUnifiedProcedureStepListStatus, instances: DicomUnifiedProcedureStepListStatus) {
        lock.withLock { warm ? (.warmStart, .warmStart) : (.coldStart, .coldStart) }
    }
    public func snapshot() -> Snapshot { lock.withLock { saved } }
    public func restore(snapshot: Snapshot) { lock.withLock { saved = snapshot; warm = true } }
    public func transaction<T>(sopInstanceUID: String,
                              _ body: (inout DicomUnifiedProcedureStepRecord?) throws -> T) throws -> T {
        try lock.withLock {
            let backup = saved
            var record = saved.records[sopInstanceUID]
            do {
                let result = try body(&record)
                saved.records[sopInstanceUID] = record
                return result
            } catch { saved = backup; throw error }
        }
    }
    public func all() -> [DicomUnifiedProcedureStepRecord] {
        lock.withLock { saved.records.values.sorted { $0.sopInstanceUID < $1.sopInstanceUID } }
    }
    public func subscriptions(sopInstanceUID: String) -> [String: DicomUnifiedProcedureStepSubscriptionState] {
        lock.withLock { saved.subscriptions[sopInstanceUID] ?? [:] }
    }
    public func setSubscription(sopInstanceUID: String, ae: String, state: DicomUnifiedProcedureStepSubscriptionState) {
        lock.withLock { saved.subscriptions[sopInstanceUID, default: [:]][ae] = state }
    }
    public func globalSubscriptions() -> [String: DicomUnifiedProcedureStepGlobalSubscription] {
        lock.withLock { saved.globalSubscriptions }
    }
    public func setGlobalSubscription(ae: String, subscription: DicomUnifiedProcedureStepGlobalSubscription) {
        lock.withLock { saved.globalSubscriptions[ae] = subscription }
    }
}

public struct DicomUnifiedProcedureStepPolicy: Sendable {
    public enum CancelDecision: Sendable { case accept, noSubscriber, refused }
    public var defaultWorklistLabel = "DEFAULT"
    public var fallbackAETitles: [String] = []
    public var isPerformer = false
    public var grantDeletionLock: @Sendable (String) -> Bool = { _ in true }
    public var cancelDecision: @Sendable (DicomUnifiedProcedureStepRecord, Bool) -> CancelDecision = { _, _ in .accept }
    public init() {}
}

public protocol DicomUnifiedProcedureStepEventSink: Sendable {
    /// Returning normally means the receiving peer acknowledged status 0000. Any other outcome must throw.
    func deliver(_ event: DicomUnifiedProcedureStepEvent, to receivingAETitle: String) async throws
    func canDeliver(to receivingAETitle: String) async throws -> Bool
}
extension DicomUnifiedProcedureStepEventSink {
    public func canDeliver(to receivingAETitle: String) async throws -> Bool { true }
}
public enum DicomUnifiedProcedureStepDeliveryOutcome: Sendable { case succeeded, failed }
public protocol DicomUnifiedProcedureStepEventObserving: Sendable {
    func attempted(event: DicomUnifiedProcedureStepEvent, receivingAE: String,
                   outcome: DicomUnifiedProcedureStepDeliveryOutcome, status: UInt16?, errorDescription: String?) async
}
public struct DicomUnifiedProcedureStepDeliveryError: Error, Sendable {
    public let status: UInt16
    public init(status: UInt16) { self.status = status }
}
