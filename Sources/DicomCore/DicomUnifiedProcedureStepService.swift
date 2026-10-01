import Foundation

/// Transport-neutral workflow. The store owns serialization; no suspension occurs in a transaction.
public final class DicomUnifiedProcedureStepService: @unchecked Sendable {
    public let store: any DicomUnifiedProcedureStepStoring
    public let policy: DicomUnifiedProcedureStepPolicy
    private let sinkLock = NSLock()
    private var eventSink: (any DicomUnifiedProcedureStepEventSink)?
    private let eventReceiver: (@Sendable (String, UInt16, DicomDataSet) async throws -> Void)?
    private let observer: (any DicomUnifiedProcedureStepEventObserving)?
    public init(store: any DicomUnifiedProcedureStepStoring, policy: DicomUnifiedProcedureStepPolicy = .init(),
                eventSink: (any DicomUnifiedProcedureStepEventSink)? = nil,
                observer: (any DicomUnifiedProcedureStepEventObserving)? = nil,
                eventReceiver: (@Sendable (String, UInt16, DicomDataSet) async throws -> Void)? = nil) {
        self.eventReceiver = eventReceiver
        self.store = store; self.policy = policy; self.eventSink = eventSink; self.observer = observer
    }
    func receiveEvent(sopInstanceUID: String, typeID: UInt16, dataSet: DicomDataSet) async throws {
        guard (1...5).contains(typeID), let eventReceiver else { throw DicomUnifiedProcedureStepDeliveryError(status: 0x0211) }
        try await eventReceiver(sopInstanceUID, typeID, dataSet)
    }
    func installEventSinkIfAbsent(_ sink: any DicomUnifiedProcedureStepEventSink) {
        sinkLock.withLock { if eventSink == nil { eventSink = sink } }
    }
    private var sink: (any DicomUnifiedProcedureStepEventSink)? { sinkLock.withLock { eventSink } }
    private typealias Delivery = (DicomUnifiedProcedureStepEvent, String)

    private func mutate(_ uid: String,
                        _ body: (inout DicomUnifiedProcedureStepRecord?) throws -> DicomUnifiedProcedureStepTransition)
        async throws -> DicomUnifiedProcedureStepTransition {
        let committed = try store.transaction(sopInstanceUID: uid) { record in
            let result = try body(&record)
            let subscribers = store.subscriptions(sopInstanceUID: uid).filter { $0.value != .notSubscribed }.keys.sorted()
            return (result, result.events.flatMap { event in subscribers.map { (event, $0) } })
        }
        await emit(committed.1)
        return committed.0
    }
    private func emit(_ deliveries: [Delivery]) async {
        for (event, ae) in deliveries {
            do {
                guard let sink else { throw DicomUnifiedProcedureStepDeliveryError(status: 0xC315) }
                try await sink.deliver(event, to: ae)
                await observer?.attempted(event: event, receivingAE: ae, outcome: .succeeded, status: 0, errorDescription: nil)
            } catch {
                await observer?.attempted(event: event, receivingAE: ae, outcome: .failed,
                    status: (error as? DicomUnifiedProcedureStepDeliveryError)?.status,
                    errorDescription: String(describing: error))
            }
        }
    }
    public func create(sopInstanceUID uid: String, attributes: DicomDataSet) async throws -> DicomUnifiedProcedureStepTransition {
        try await mutate(uid) { record in
            guard record == nil else { return .init(status: 0x0111) }
            guard attributes.string(for: 0x00741000) == "SCHEDULED" else { return .init(status: 0xC309) }
            guard !upsValued(attributes[0x00081195]) else { return .init(status: 0x0106) }
            guard upsAttributeViolations(attributes, creating: true).isEmpty else { return .init(status: 0x0120) }
            var created = DicomUnifiedProcedureStepRecord(sopInstanceUID: uid, attributes: attributes)
            if !upsValued(created.attributes[0x00741202]) {
                created.attributes.set(upsString(0x00741202, policy.defaultWorklistLabel, .LO))
            }
            for (ae, global) in store.globalSubscriptions() where global.state != .notSubscribed {
                if let keys = global.matchingKeys, try !DicomQueryMatcher().matches(created.attributes, identifier: keys) { continue }
                store.setSubscription(sopInstanceUID: uid, ae: ae, state: global.state)
            }
            record = created
            return .init(record: created, events: [.stateReport(created)] + [DicomUnifiedProcedureStepEvent.assigned(created)].compactMap { $0 }, status: 0)
        }
    }
    public func get(sopInstanceUID uid: String, attributes: [Int]? = nil) throws -> (status: UInt16, dataSet: DicomDataSet?) {
        try store.transaction(sopInstanceUID: uid) { record in
            guard let record else { return (0xC307, nil) }
            let forbidden: Set<Int> = [0x00081195, 0x00080016, 0x00080018]
            let selection = attributes.map(Set.init)
            let elements = record.attributes.elements.filter {
                !forbidden.contains($0.tag) && (selection == nil || selection!.isEmpty || selection!.contains($0.tag))
            }
            return (0, .init(elements: elements))
        }
    }
    public func set(sopInstanceUID uid: String, attributes: DicomDataSet) async throws -> DicomUnifiedProcedureStepTransition {
        try await mutate(uid) { record in
            guard var updated = record else { return .init(status: 0xC307) }
            guard !updated.state.isFinal else { return .init(record: updated, status: 0xC300) }
            if updated.state == .inProgress {
                guard attributes.string(for: 0x00081195) == updated.transactionUID else { return .init(record: updated, status: 0xC301) }
            } else if attributes[0x00081195] != nil { return .init(record: updated, status: 0xC301) }
            if attributes[0x00741000] != nil { return .init(record: updated, status: 0xC303) }
            guard upsAttributeViolations(attributes, creating: false).isEmpty else { return .init(record: updated, status: 0x0106) }
            let old = updated.attributes
            for element in attributes.elements where element.tag != 0x00081195 && element.tag != 0x00404010 {
                updated.attributes.set(element)
            }
            updated.modified = Date()
            updated.attributes.set(upsString(0x00404010, upsTime(updated.modified), .DT))
            var events: [DicomUnifiedProcedureStepEvent] = []
            if old[0x00404041] != updated.attributes[0x00404041] { events.append(.stateReport(updated)) }
            let oldProgress = old.sequenceItems(for: 0x00741002).first?.dataSet ?? .init()
            if let progress = updated.attributes.sequenceItems(for: 0x00741002).first?.dataSet,
               [0x00741004, 0x00741006, 0x00741007, 0x00741008].contains(where: { oldProgress[$0] != progress[$0] }) {
                events.append(.init(sopInstanceUID: uid, payload: .progress(progress)))
            }
            if old[0x00404025] != updated.attributes[0x00404025] || old[0x00404034] != updated.attributes[0x00404034],
               let assigned = DicomUnifiedProcedureStepEvent.assigned(updated) { events.append(assigned) }
            record = updated
            return .init(record: updated, events: events, status: 0)
        }
    }
    public func changeState(sopInstanceUID uid: String, to state: DicomUnifiedProcedureStepState,
                            transactionUID: String?) async throws -> DicomUnifiedProcedureStepTransition {
        try await mutate(uid) { record in
            guard let existing = record else { return .init(status: 0xC307) }
            let transition = existing.changingState(to: state, transactionUID: transactionUID)
            if transition.status == 0 { record = transition.record }
            return transition
        }
    }
    public func requestCancel(sopInstanceUID uid: String, requestingAE: String,
                              information: DicomDataSet = .init()) async throws -> DicomUnifiedProcedureStepTransition {
        try await mutate(uid) { record in
            guard var existing = record else { return .init(status: 0xC307) }
            if existing.state == .completed { return .init(record: existing, status: 0xC311) }
            if existing.state == .canceled { return .init(record: existing, status: 0xB304) }
            let subscribed = store.subscriptions(sopInstanceUID: uid).values.contains { $0 != .notSubscribed }
            if existing.state == .inProgress {
                switch policy.cancelDecision(existing, subscribed && sink != nil) {
                case .refused: return .init(record: existing, status: 0xC313)
                case .noSubscriber: return .init(record: existing, status: 0xC312)
                case .accept: break
                }
                if !policy.isPerformer {
                    return .init(record: existing, events: [.init(sopInstanceUID: uid,
                        payload: .cancel(requestingAE: requestingAE, information: information))], status: 0)
                }
            }
            var events: [DicomUnifiedProcedureStepEvent] = []
            if existing.state == .scheduled {
                let claimed = existing.changingState(to: .inProgress, transactionUID: "2.25." + UUID().uuidString
                    .replacingOccurrences(of: "-", with: "").prefix(12).utf8.map { String($0) }.joined())
                existing = claimed.record!
                events += claimed.events
            }
            var progress = existing.attributes.sequenceItems(for: 0x00741002).first?.dataSet ?? .init()
            for element in information.elements where [0x00741238, 0x0074100E, 0x0074100A, 0x0074100C].contains(element.tag) { progress.set(element) }
            if !upsValued(progress[0x0074100E]) {
                progress.set(upsSequence(0x0074100E, [.init(elements: [upsString(0x00080100, "110514", .SH),
                    upsString(0x00080102, "DCM", .SH), upsString(0x00080104, "Canceled by user", .LO)])]))
            }
            existing.attributes.set(upsSequence(0x00741002, [progress]))
            let canceled = existing.changingState(to: .canceled, transactionUID: existing.transactionUID)
            guard canceled.status == 0 else { return canceled }
            record = canceled.record
            return .init(record: record, events: events + canceled.events, status: 0)
        }
    }
    public func subscribe(sopInstanceUID uid: String, receivingAE: String, deletionLock: Bool,
                          matchingKeys: DicomDataSet? = nil) async throws -> DicomUnifiedProcedureStepTransition {
        try await subscription(uid, receivingAE: receivingAE, action: 3, deletionLock: deletionLock, matchingKeys: matchingKeys)
    }
    public func unsubscribe(sopInstanceUID uid: String, receivingAE: String) async throws -> DicomUnifiedProcedureStepTransition {
        try await subscription(uid, receivingAE: receivingAE, action: 4)
    }
    public func suspend(receivingAE: String) async throws -> DicomUnifiedProcedureStepTransition {
        try await subscription(Self.globalUID, receivingAE: receivingAE, action: 5)
    }
    static let globalUID = "1.2.840.10008.5.1.4.34.5"
    static let filteredUID = "1.2.840.10008.5.1.4.34.5.1"
    private func subscription(_ uid: String, receivingAE ae: String, action: Int, deletionLock: Bool = false,
                              matchingKeys: DicomDataSet? = nil) async throws -> DicomUnifiedProcedureStepTransition {
        guard let sink else { return .init(status: 0xC315) }
        guard try await sink.canDeliver(to: ae) else { return .init(status: 0xC308) }
        let global = uid == Self.globalUID || uid == Self.filteredUID
        let granted = deletionLock && policy.grantDeletionLock(ae)
        let state: DicomUnifiedProcedureStepSubscriptionState = granted ? .withLock : .withoutLock
        let committed = try store.transaction(sopInstanceUID: uid) { record -> (UInt16, [Delivery]) in
            guard global || record != nil else { return (0xC307, []) }
            var events: [Delivery] = []
            if global {
                store.setGlobalSubscription(ae: ae, subscription: .init(state: action == 3 ? state : .notSubscribed,
                    matchingKeys: uid == Self.filteredUID ? matchingKeys : nil))
                for existing in try store.all() {
                    if action == 4 { store.setSubscription(sopInstanceUID: existing.sopInstanceUID, ae: ae, state: .notSubscribed) }
                    if action != 3 { continue }
                    if uid == Self.filteredUID, let matchingKeys,
                       try !DicomQueryMatcher().matches(existing.attributes, identifier: matchingKeys) { continue }
                    if store.subscriptions(sopInstanceUID: existing.sopInstanceUID)[ae, default: .notSubscribed] == .notSubscribed {
                        store.setSubscription(sopInstanceUID: existing.sopInstanceUID, ae: ae, state: state)
                    }
                    // CC.2.4.3 explicitly requires a report for every existing matching instance with lock.
                    if granted { events.append((.stateReport(existing), ae)) }
                }
            } else {
                store.setSubscription(sopInstanceUID: uid, ae: ae, state: action == 3 ? state : .notSubscribed)
                if action == 3 { events.append((.stateReport(record!), ae)) }
            }
            return (action == 3 && deletionLock && !granted ? 0xB301 : 0, events)
        }
        await emit(committed.1)
        return .init(status: committed.0)
    }
    public func search(identifier: DicomDataSet) throws -> [(status: UInt16, dataSet: DicomDataSet)] {
        let table = DicomUnifiedProcedureStepAttribute.table.filter { $0.path.count == 1 }
        let matching = Set(table.filter { ["R", "O", "U"].contains($0.matching) }.map(\.tag))
        let keys = DicomDataSet(elements: identifier.elements.filter { matching.contains($0.tag) })
        guard !keys.isEmpty else { return [] }
        let returnable = Set(table.filter { !$0.returned.isEmpty && $0.returned != "-" }.map(\.tag))
        let unsupported = identifier.elements.contains { !returnable.contains($0.tag) && $0.tag != 0x00080201 }
        return try store.search(matching: keys).map { record in
            var elements = identifier.elements.filter { returnable.contains($0.tag) }.map { key in
                record.attributes[key.tag] ?? DicomDataElement(tag: key.tag, vr: key.vr, value: .empty)
            }
            if let charset = record.attributes[0x00080005], !elements.contains(where: { $0.tag == charset.tag }) { elements.append(charset) }
            return (unsupported ? 0xFF01 : 0xFF00, .init(elements: elements))
        }
    }
    public func scpStatusChanged(status: DicomUnifiedProcedureStepSCPStatus) async throws {
        let deliveries = try store.transaction(sopInstanceUID: Self.globalUID) { _ -> [Delivery] in
            var aes = Set(policy.fallbackAETitles)
            aes.formUnion(store.globalSubscriptions().filter { $0.value.state != .notSubscribed }.keys)
            for record in try store.all() {
                aes.formUnion(store.subscriptions(sopInstanceUID: record.sopInstanceUID).filter { $0.value != .notSubscribed }.keys)
            }
            let lists = store.listStatus
            let event = DicomUnifiedProcedureStepEvent(sopInstanceUID: Self.globalUID,
                payload: .scpStatus(status, subscriptions: lists.subscriptions, instances: lists.instances))
            return aes.sorted().map { (event, $0) }
        }
        await emit(deliveries)
    }
}
