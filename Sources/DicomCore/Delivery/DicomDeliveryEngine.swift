import Foundation

public actor DicomDeliveryEngine {
    private let authorizer: (any DicomAuthorizing)?
    private let principalProvider: (@Sendable (DicomDeliveryItem) async -> DicomPrincipal?)?
    private let audit: DicomAuditRecorder?
    private let outbox: any DicomDeliveryOutboxStoring
    private let destinations: [String: any DicomDeliveryDestination]
    private let retryPolicy: DicomDeliveryRetryPolicy
    private let limits: DicomDeliveryLimits
    private let backpressure: any DicomDeliveryBackpressure
    private let owner: String
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let globalBandwidth: DicomBandwidthLimiter?
    private let destinationBandwidth: [String: DicomBandwidthLimiter]
    private var active: [String: DicomDeliveryCancellation] = [:]
    private var tasks: [String: Task<DicomDeliveryAttemptResult, Never>] = [:]
    private var cycling = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(outbox: any DicomDeliveryOutboxStoring,
                destinations: [String: any DicomDeliveryDestination], retryPolicy: DicomDeliveryRetryPolicy = .init(),
                limits: DicomDeliveryLimits = .init(),
                backpressure: any DicomDeliveryBackpressure = DicomDeliveryNoBackpressure(), owner: String,
                clock: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                }, authorizer: (any DicomAuthorizing)? = nil,
                principalProvider: (@Sendable (DicomDeliveryItem) async -> DicomPrincipal?)? = nil,
                audit: DicomAuditRecorder? = nil) {
        self.authorizer = authorizer; self.principalProvider = principalProvider; self.audit = audit
        self.outbox = outbox
        self.destinations = destinations
        self.retryPolicy = retryPolicy
        self.limits = limits
        self.backpressure = backpressure
        self.owner = owner
        self.clock = clock
        self.sleep = sleep
        globalBandwidth = limits.globalBytesPerSecond.map {
            DicomBandwidthLimiter(bytesPerSecond: $0, clock: clock, sleep: sleep)
        }
        destinationBandwidth = limits.perDestinationBytesPerSecond.mapValues {
            DicomBandwidthLimiter(bytesPerSecond: $0, clock: clock, sleep: sleep)
        }
    }

    public func enqueue(_ items: [DicomDeliveryItem]) async throws {
        guard items.allSatisfy({ destinations[$0.destinationID] != nil }) else {
            throw DicomDeliveryOutboxError.invalidItem
        }
        try await outbox.enqueue(items)
    }

    public func runOnce(now: Date) async -> DicomDeliveryCycleReport {
        var report = DicomDeliveryCycleReport()
        guard !cycling else { return report }
        cycling = true
        defer {
            cycling = false
            for waiter in drainWaiters { waiter.resume() }
            drainWaiters.removeAll()
        }
        do {
            try await outbox.releaseExpiredLeases(now: now)
            if case .pause(let seconds) = await backpressure.admission() {
                report.paused = true
                report.retryAfter = seconds
                return report
            }
            let leaseOwner = owner + ":" + UUID().uuidString
            let slots = destinations.mapValues { limits.perDestinationMaxConcurrent[$0.id, default: 1] }
            let items = try await outbox.lease(max: limits.globalMaxConcurrent, owner: leaseOwner, now: now,
                leaseSeconds: limits.leaseSeconds, statShare: limits.statShare, destinationSlots: slots)
            for item in items { active[item.deliveryID] = DicomDeliveryCancellation() }
            await withTaskGroup(of: (DicomDeliveryItem, DicomDeliveryAttemptResult).self) { group in
                for item in items {
                    let cancellation = active[item.deliveryID]!
                    let destination = destinations[item.destinationID]!
                    let global = globalBandwidth
                    let bandwidth = destinationBandwidth[item.destinationID]
                    let store = outbox
                    let authorizer = self.authorizer
                    let principalProvider = self.principalProvider
                    let audit = self.audit
                    let task = Task<DicomDeliveryAttemptResult, Never> {
                        do {
                            if try await store.isDelivered(destinationID: item.destinationID,
                                                           idempotencyKey: item.idempotencyKey) {
                                return .delivered(.init(status: "alreadyDelivered"))
                            }
                            if cancellation.isCancelled { return .failed(.cancelled, "Cancelled", retryAfter: nil) }
                            try await global?.acquire(bytes: item.byteCount)
                            try await bandwidth?.acquire(bytes: item.byteCount)
                            if cancellation.isCancelled || Task.isCancelled {
                                return .failed(.cancelled, "Cancelled", retryAfter: nil)
                            }
                            if let authorizer {
                                guard let resource = item.resource,
                                      let principal = await principalProvider?(item) else {
                                    return .failed(.cancelled, "authorizationRevoked", retryAfter: nil)
                                }
                                let access = DicomEnforcement(principal: principal, authorizer: authorizer,
                                    audit: audit, context: .init(protocol: .local))
                                guard try await access.check(.route, resource, filtering: true) else {
                                    return .failed(.cancelled, "authorizationRevoked", retryAfter: nil)
                                }
                            }
                            return await destination.deliver(item, isCancelled: { cancellation.isCancelled })
                        } catch is CancellationError {
                            return .failed(.cancelled, "Cancelled", retryAfter: nil)
                        } catch { return .failed(.transient, String(describing: error), retryAfter: nil) }
                    }
                    tasks[item.deliveryID] = task
                    group.addTask {
                        await withTaskCancellationHandler {
                            (item, await task.value)
                        } onCancel: { task.cancel() }
                    }
                }
                for await (item, result) in group {
                    report.attempted += 1
                    do {
                        let settlement: DicomDeliverySettlement
                        if active[item.deliveryID]?.isCancelled == true {
                            settlement = .cancel
                        } else {
                            settlement = try self.settlement(result, item: item, now: clock())
                        }
                        try await outbox.settle(deliveryID: item.deliveryID, leaseOwner: leaseOwner,
                                                settlement: settlement)
                        if case .complete = settlement { report.delivered += 1 }
                    } catch { report.errors.append(String(describing: error)) }
                    active[item.deliveryID] = nil
                    tasks[item.deliveryID] = nil
                }
            }
        } catch { report.errors.append(String(describing: error)) }
        return report
    }

    private func settlement(_ result: DicomDeliveryAttemptResult, item: DicomDeliveryItem,
                            now: Date) throws -> DicomDeliverySettlement {
        switch result {
        case .delivered(let receipt): return .complete(receipt, retry: nil)
        case .partial(let receipt):
            guard case .objects(let files) = item.payload else { return .complete(receipt, retry: nil) }
            let refused = Set(receipt.perObject.filter { !$0.accepted && $0.errorClass == .transient }.map(\.sopInstanceUID))
            guard !refused.isEmpty else { return .complete(receipt, retry: nil) }
            let retryAt = retryPolicy.nextAttempt(after: item.attempts, class: .transient, now: now)
            let subset = try files.filter { refused.contains(try DicomStoreRequest(part10FileAt: $0).sopInstanceUID) }
            guard !subset.isEmpty else { throw DicomDeliveryOutboxError.invalidItem }
            var retry = DicomDeliveryItem(eventID: item.eventID, destinationID: item.destinationID,
                destinationKind: item.destinationKind, idempotencyKey: item.idempotencyKey + "#retry\(item.attempts)",
                priority: item.priority, payload: .objects(subset), byteCount: try subset.reduce(0) {
                    $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                }, now: now, resource: item.resource)
            retry.attempts = item.attempts
            retry.state = retryAt == nil ? .deadLetter : .retryWait
            retry.nextAttemptAt = retryAt ?? now
            retry.lastErrorClass = .transient
            retry.lastError = retryAt == nil ? "Per-object retry budget exhausted" : "Transient per-object refusal"
            return .complete(receipt, retry: retry)
        case .failed(let errorClass, let message, let retryAfter):
            if errorClass == .cancelled, message == "authorizationRevoked" {
                return .cancelWithReason("authorizationRevoked")
            }
            return .fail(errorClass, message, retryAt: retryPolicy.nextAttempt(after: item.attempts,
                class: errorClass, retryAfter: retryAfter, now: now))
        case .uncertain(let message):
            return .fail(.uncertain, message, retryAt: retryPolicy.nextAttempt(after: item.attempts,
                class: .uncertain, now: now))
        }
    }

    public func cancel(deliveryID: String) async throws {
        active[deliveryID]?.cancel()
        tasks[deliveryID]?.cancel()
        try await outbox.cancel(deliveryID: deliveryID)
    }
    /// Existing uncertain deadlines are durable and must not be shortened on restart.
    public func resume(now: Date) async throws { try await outbox.releaseExpiredLeases(now: now) }
    /// Waits for admitted attempts; queued retries are left durable for a subsequent run.
    public func drain() async {
        if cycling { await withCheckedContinuation { drainWaiters.append($0) } }
    }
    public func run(until stop: @Sendable () -> Bool) async {
        while !stop() && !Task.isCancelled {
            let report = await runOnce(now: clock())
            do {
                let due = try await outbox.fetch(states: [.pending, .retryWait, .uncertain])
                    .filter { destinations[$0.destinationID] != nil }
                    .map(\.nextAttemptAt).min()
                let delay = report.retryAfter ?? due.map { max(0.01, $0.timeIntervalSince(clock())) } ?? 1
                try await sleep(min(1, max(0.01, delay)))
            } catch { return }
        }
    }
}
