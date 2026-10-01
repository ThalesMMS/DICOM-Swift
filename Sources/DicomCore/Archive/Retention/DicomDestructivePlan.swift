import Foundation

public struct DicomDestructivePlan: Codable, Equatable, Sendable {
    public struct Action: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case delete, migrate, evictCache }
        public let kind: Kind
        public let objectKey: String
        public let providerID: String
        public let locator: String
        public let byteCount: Int64
        public let reason: String
        public internal(set) var blockers: [DicomDeletionBlocker]
        public internal(set) var lastVerifiedCopy: Bool
        public let targetProviderID: String?
        public let targetLocator: String?
        public let sha256: String?
        public init(kind: Kind, objectKey: String, providerID: String, locator: String, byteCount: Int64,
                    reason: String, blockers: [DicomDeletionBlocker] = [], lastVerifiedCopy: Bool = true,
                    targetProviderID: String? = nil, targetLocator: String? = nil, sha256: String? = nil) {
            self.kind = kind; self.objectKey = objectKey; self.providerID = providerID; self.locator = locator
            self.byteCount = byteCount; self.reason = reason; self.blockers = blockers
            self.lastVerifiedCopy = lastVerifiedCopy; self.targetProviderID = targetProviderID
            self.targetLocator = targetLocator; self.sha256 = sha256
        }
    }
    public let planID: String
    public let createdAt: Date
    public let actions: [Action]
    public init(planID: String = UUID().uuidString, createdAt: Date = Date(), actions: [Action]) {
        self.planID = planID; self.createdAt = createdAt; self.actions = actions
    }
    public var executable: [Action] { actions.filter { $0.blockers.isEmpty && !$0.lastVerifiedCopy } }
    public var blocked: [Action] { actions.filter { !$0.blockers.isEmpty || $0.lastVerifiedCopy } }
}

public struct DicomDestructivePlanner: Sendable {
    public init() {}
    public func plan(candidates: [DicomDestructivePlan.Action], placements: [String: [DicomObjectPlacement]],
                     verifiedCopies: [String: Int], protections: [String: DicomObjectProtection],
                     graph: DicomProtectionGraph, now: Date) -> DicomDestructivePlan {
        var remaining = verifiedCopies
        var available = placements.mapValues { $0.filter { $0.state == .available }.count }
        var seen: Set<String> = []
        let actions = candidates.map { candidate in
            var action = candidate
            let key = action.objectKey
            action.blockers += graph.deletionBlockers(for: key, own: protections, now: now)
            let placement = placements[key]?.first { $0.providerID == action.providerID && $0.locator == action.locator }
            if placement == nil || placement?.byteCount != action.byteCount {
                action.blockers.append(.invalidPlan("Unknown or changed placement"))
            }
            let identity = action.providerID + "\0" + action.locator
            if !seen.insert(identity).inserted { action.blockers.append(.invalidPlan("Duplicate removal")) }
            action.lastVerifiedCopy = action.kind != .migrate &&
                ((remaining[key] ?? 0) <= 1 || (available[key] ?? 0) <= 1)
            if action.kind == .migrate {
                if action.targetProviderID == nil || action.targetLocator == nil || action.sha256 == nil ||
                    action.sha256 != placement?.sha256 ||
                    (action.targetProviderID == action.providerID && action.targetLocator == action.locator) {
                    action.blockers.append(.invalidPlan("Migration requires a distinct target and expected SHA-256"))
                }
            }
            // Reserve surviving copies across the whole plan, not just each action in isolation.
            if action.blockers.isEmpty && !action.lastVerifiedCopy && action.kind != .migrate {
                remaining[key, default: 0] -= 1
                available[key, default: 0] -= 1
            }
            return action
        }
        return .init(createdAt: now, actions: actions)
    }
}

public actor DicomDestructiveExecutor {
    public struct ExecutionReport: Sendable {
        public let plan: DicomDestructivePlan
        public let dryRun: Bool
        public let executed: [DicomDestructivePlan.Action]
        public let skipped: [DicomDestructivePlan.Action]
        public var blockedAfterPlanning: [DicomDestructivePlan.Action] = []
        public let failed: [(objectKey: String, reason: String)]
    }
    private var executedPlacements: Set<String> = []
    public init() {}
    public func execute(plan: DicomDestructivePlan, authorization: DicomDeleteAuthorization,
                        providers: [String: any DicomStorageProvider],
                        placements: [String: [DicomObjectPlacement]], verifiedCopies: [String: Int],
                        protections: [String: DicomObjectProtection], graph: DicomProtectionGraph,
                        now: Date = Date(), dryRun: Bool = true,
                        protectionReloader: (@Sendable (String) async -> DicomObjectProtection?)? = nil,
                        authorizer: (any DicomAuthorizing)? = nil, principal: DicomPrincipal? = nil,
                        audit: DicomAuditRecorder? = nil) async throws -> ExecutionReport {
        // A serialized plan is a request. Derive safety decisions again from the host's current state.
        let candidates = plan.actions.map {
            DicomDestructivePlan.Action(kind: $0.kind, objectKey: $0.objectKey, providerID: $0.providerID,
                locator: $0.locator, byteCount: $0.byteCount, reason: $0.reason,
                targetProviderID: $0.targetProviderID, targetLocator: $0.targetLocator, sha256: $0.sha256)
        }
        let refreshed = DicomDestructivePlanner().plan(candidates: candidates, placements: placements,
            verifiedCopies: verifiedCopies, protections: protections, graph: graph, now: now)
        let plan = DicomDestructivePlan(planID: plan.planID, createdAt: plan.createdAt, actions: refreshed.actions)
        if dryRun { return .init(plan: plan, dryRun: true, executed: [], skipped: plan.actions, failed: []) }
        guard !authorization.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DicomStorageProviderError.deleteNotAuthorized
        }
        var executed: [DicomDestructivePlan.Action] = []
        var failed: [(objectKey: String, reason: String)] = []
        var blockedAfterPlanning: [DicomDestructivePlan.Action] = []
        func permitted(_ action: DicomDestructivePlan.Action) async throws -> Bool {
            if let protectionReloader {
                var current: [String: DicomObjectProtection] = [:]
                for key in graph.chain(action.objectKey) { current[key] = await protectionReloader(key) }
                if !graph.deletionBlockers(for: action.objectKey, own: current, now: Date()).isEmpty { return false }
            }
            return try await DicomEnforcement(principal: principal, authorizer: authorizer, audit: audit,
                context: .init(protocol: .local)).check(action.kind == .evictCache ? .evict : .delete,
                    .init(kind: .instance, id: action.objectKey), filtering: true)
        }
        for action in plan.executable {
            guard try await permitted(action) else { blockedAfterPlanning.append(action); continue }
            do {
                let identity = action.providerID + "\0" + action.locator
                guard executedPlacements.insert(identity).inserted else {
                    throw DicomStorageProviderError.io("Placement already executed")
                }
                var deleted = false
                defer {
                    if !deleted { executedPlacements.remove(identity) }
                }
                guard let source = providers[action.providerID], source.id == action.providerID else {
                    throw DicomStorageProviderError.unreachable(action.providerID)
                }
                guard let info = try await source.head(action.locator), info.byteCount == action.byteCount,
                      action.sha256 == nil || info.sha256 == action.sha256 else {
                    throw DicomStorageProviderError.integrity("Source placement changed")
                }
                if action.kind == .migrate {
                    guard let targetID = action.targetProviderID, let target = providers[targetID], target.id == targetID,
                          let locator = action.targetLocator, let hash = action.sha256,
                          targetID != action.providerID || locator != action.locator else {
                        throw DicomStorageProviderError.io("Invalid migration target")
                    }
                    let fs = DicomLocalIngestFileSystem()
                    let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try fs.createDirectory(work)
                    defer { try? fs.remove(work) }
                    let input = work.appendingPathComponent("source")
                    let reread = work.appendingPathComponent("reread")
                    _ = try await source.get(action.locator, to: input, expectedSHA256: hash, isCancelled: { false })
                    _ = try await target.put(input, locator: locator, expectedSHA256: hash, isCancelled: { false })
                    _ = try await target.get(locator, to: reread, expectedSHA256: hash, isCancelled: { false })
                    let verified = try StoragePath.info(reread, locator: locator, fileSystem: fs)
                    guard verified.sha256 == hash, verified.byteCount == action.byteCount else {
                        throw DicomStorageProviderError.integrity("Migration target verification failed")
                    }
                }
                try Task.checkCancellation()
                guard try await permitted(action) else {
                    executedPlacements.remove(identity)
                    blockedAfterPlanning.append(action)
                    continue
                }
                try await source.delete(action.locator, authorization: authorization)
                deleted = true
                executed.append(action)
            } catch { failed.append((action.objectKey, String(describing: error))) }
        }
        return .init(plan: plan, dryRun: false, executed: executed, skipped: plan.blocked + blockedAfterPlanning,
                     blockedAfterPlanning: blockedAfterPlanning, failed: failed)
    }
}
