import Foundation

public struct DicomAuthorizationDecision: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case allow, deny }
    public enum Reason: String, Codable, Sendable {
        case allowed, noPrincipal, principalExpired, principalRevoked, scopeMissing, resourceRestricted
        case resourceResearchOnly, resourceVIP, protectedFromDeletion, legalHold, retention, policyUnavailable
        case policyVersionChanged, transportInsecure, exposureNotPermitted, phiNotAuthorized
    }
    public enum Obligation: String, Codable, Sendable { case auditRequired, minimizePHI }
    public let outcome: Outcome
    public let reason: Reason
    public let policyVersion: Int64
    public let obligations: Set<Obligation>
    public let recheckInterval: TimeInterval?
    public let evaluatedAt: Date
    public init(outcome: Outcome, reason: Reason, policyVersion: Int64,
                obligations: Set<Obligation> = [], recheckInterval: TimeInterval? = nil, evaluatedAt: Date) {
        self.outcome = outcome; self.reason = reason; self.policyVersion = policyVersion
        self.obligations = obligations; self.recheckInterval = recheckInterval; self.evaluatedAt = evaluatedAt
    }
}

public protocol DicomAuthorizing: Sendable {
    func decide(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
                context: DicomAccessContext) async -> DicomAuthorizationDecision
    func lease(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
               context: DicomAccessContext) async -> DicomAuthorizationLease?
    var policyVersion: Int64 { get async }
}

public extension DicomAuthorizing {
    func lease(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
               context: DicomAccessContext) async -> DicomAuthorizationLease? {
        let decision = await decide(principal: principal, operation: operation, resource: resource, context: context)
        // The authorizer decides about anonymous callers; a lease only materialises an `allow`.
        guard decision.outcome == .allow else { return nil }
        let principal = principal ?? .anonymous
        let interval = decision.recheckInterval ?? 30
        guard interval.isFinite, interval > 0 else { return nil }
        let expiry = min(context.at.addingTimeInterval(interval), principal.expiresAt ?? .distantFuture)
        guard expiry > context.at else { return nil }
        return .init(principal: principal, operation: operation, resource: resource,
                     decision: decision, expiresAt: expiry)
    }
}

/// Immutable scope binding: this lease cannot be reused for another principal, operation, or resource.
public struct DicomAuthorizationLease: Sendable {
    public let id: UUID
    public let principal: DicomPrincipal
    public let operation: DicomAccessOperation
    public let resource: DicomResourceRef
    public let decision: DicomAuthorizationDecision
    public let expiresAt: Date
    public let policyVersion: Int64
    public init(id: UUID = UUID(), principal: DicomPrincipal, operation: DicomAccessOperation,
                resource: DicomResourceRef, decision: DicomAuthorizationDecision, expiresAt: Date) {
        self.id = id; self.principal = principal; self.operation = operation; self.resource = resource
        self.decision = decision; self.expiresAt = expiresAt; self.policyVersion = decision.policyVersion
    }
}

public protocol DicomAuthorizationRevoking: Sendable {
    func isRevoked(principalID: String) async -> Bool
    func currentPolicyVersion() async -> Int64
}

public actor DicomLeaseValidator {
    private let revocation: any DicomAuthorizationRevoking
    public init(revocation: any DicomAuthorizationRevoking) { self.revocation = revocation }
    public func validate(_ lease: DicomAuthorizationLease, now: Date = Date()) async -> DicomAuthorizationDecision {
        let version = await revocation.currentPolicyVersion()
        let reason: DicomAuthorizationDecision.Reason
        if await revocation.isRevoked(principalID: lease.principal.id) { reason = .principalRevoked }
        else if version != lease.policyVersion || version != lease.principal.policyVersion {
            reason = .policyVersionChanged
        } else if now >= lease.expiresAt || now >= (lease.principal.expiresAt ?? .distantFuture)
                    || now < lease.principal.authenticatedAt { reason = .principalExpired }
        else if lease.principal.kind == .anonymous || lease.principal.source == .none { reason = .noPrincipal }
        else { reason = lease.decision.reason }
        return .init(outcome: reason == .allowed && lease.decision.outcome == .allow ? .allow : .deny,
            reason: reason, policyVersion: version, obligations: lease.decision.obligations,
            recheckInterval: lease.decision.recheckInterval, evaluatedAt: now)
    }
}

public struct DicomDenyAllAuthorizer: DicomAuthorizing {
    public let policyVersion: Int64
    public init(policyVersion: Int64 = 0) { self.policyVersion = policyVersion }
    public func decide(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
                       context: DicomAccessContext) async -> DicomAuthorizationDecision {
        .init(outcome: .deny, reason: principal == nil ? .noPrincipal : .resourceRestricted,
              policyVersion: policyVersion, evaluatedAt: context.at)
    }
}

public struct DicomFailClosedAuthorizer: DicomAuthorizing {
    private let wrapped: any DicomAuthorizing
    private let isAvailable: @Sendable () async -> Bool
    public init(wrapping: any DicomAuthorizing, isAvailable: @escaping @Sendable () async -> Bool) {
        wrapped = wrapping; self.isAvailable = isAvailable
    }
    public var policyVersion: Int64 { get async { await isAvailable() ? await wrapped.policyVersion : -1 } }
    public func decide(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
                       context: DicomAccessContext) async -> DicomAuthorizationDecision {
        guard await isAvailable() else { return unavailable(at: context.at) }
        let result = await wrapped.decide(principal: principal, operation: operation, resource: resource, context: context)
        return await isAvailable() ? result : unavailable(at: context.at)
    }
    public func lease(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
                      context: DicomAccessContext) async -> DicomAuthorizationLease? {
        guard await isAvailable() else { return nil }
        let result = await wrapped.lease(principal: principal, operation: operation, resource: resource, context: context)
        return await isAvailable() ? result : nil
    }
    private func unavailable(at: Date) -> DicomAuthorizationDecision {
        .init(outcome: .deny, reason: .policyUnavailable, policyVersion: -1, evaluatedAt: at)
    }
}

public struct DicomProtectionAuthorizer: DicomAuthorizing {
    public let policyVersion: Int64
    private let lookup: @Sendable (DicomResourceRef) async -> [String: DicomObjectProtection]
    public init(policyVersion: Int64, protectionLookup: @escaping @Sendable (DicomResourceRef) async -> [String: DicomObjectProtection]) {
        self.policyVersion = policyVersion; lookup = protectionLookup
    }
    public func decide(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
                       context: DicomAccessContext) async -> DicomAuthorizationDecision {
        func result(_ reason: DicomAuthorizationDecision.Reason) -> DicomAuthorizationDecision {
            .init(outcome: reason == .allowed ? .allow : .deny, reason: reason, policyVersion: policyVersion,
                  obligations: [.auditRequired, .minimizePHI], recheckInterval: 30, evaluatedAt: context.at)
        }
        guard let principal, principal.kind != .anonymous, principal.source != .none,
              !principal.id.isEmpty, !principal.sessionID.isEmpty else { return result(.noPrincipal) }
        guard principal.authenticatedAt <= context.at,
              (principal.expiresAt ?? .distantFuture) > context.at else { return result(.principalExpired) }
        guard principal.policyVersion == policyVersion else { return result(.policyVersionChanged) }
        if resource.kind == .representation || resource.kind == .derivative {
            guard resource.sourceObject != resource else { return result(.resourceRestricted) }
        }
        // Resolve source for every operation, including cache/export paths, and retain stricter child protections.
        var own = await lookup(resource.sourceObject)
        if resource.sourceObject != resource {
            let child = await lookup(resource)
            for (key, value) in child {
                if let existing = own[key] {
                    own[key] = DicomProtectionGraph(parents: ["child": "source"]).effective(for: "child",
                        own: ["source": existing, "child": value], now: context.at)
                } else { own[key] = value }
            }
        }
        let chain = [resource] + resource.ancestry
        // Duplicate IDs make an ancestry graph ambiguous; reject rather than silently drop an ancestor.
        guard Set(chain.map(\.id)).count == chain.count else { return result(.resourceRestricted) }
        var parents: [String: String] = [:]
        for pair in zip(chain, chain.dropFirst()) { parents[pair.0.id] = pair.1.id }
        let graph = DicomProtectionGraph(parents: parents)
        let protection = graph.effective(for: resource.id, own: own, now: context.at)
        if protection.privacyFlags.contains(.restricted), !principal.scopes.contains("phi:restricted") {
            return result(.resourceRestricted)
        }
        if protection.privacyFlags.contains(.researchOnly),
           !principal.scopes.contains("research") || ![.query, .readMetadata, .derive].contains(operation) {
            return result(.resourceResearchOnly)
        }
        if protection.privacyFlags.contains(.vip), !principal.scopes.contains("phi:vip") { return result(.resourceVIP) }
        if operation == .delete || operation == .evict {
            func reason(_ blocker: DicomDeletionBlocker) -> DicomAuthorizationDecision.Reason {
                switch blocker {
                case .protected: return .protectedFromDeletion
                case .legalHold: return .legalHold
                case .retention: return .retention
                case .inheritedFrom(_, let value): return reason(value)
                case .invalidPlan: return .resourceRestricted
                }
            }
            if let blocker = graph.deletionBlockers(for: resource.id, own: own, now: context.at).first {
                return result(reason(blocker))
            }
        }
        if [.export, .route].contains(operation), !principal.scopes.contains("export") { return result(.scopeMissing) }
        if [.configure, .modifyProtection, .auditExport].contains(operation), !principal.roles.contains("admin") {
            return result(.scopeMissing)
        }
        return result(.allowed)
    }
}
