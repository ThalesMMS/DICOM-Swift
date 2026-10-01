import Foundation

/// A request-scoped value; never shared mutable authentication state between requests.
struct DicomEnforcement: Sendable {
    let principal: DicomPrincipal?
    let authorizer: (any DicomAuthorizing)?
    let audit: DicomAuditRecorder?
    let context: DicomAccessContext

    func check(_ operation: DicomAccessOperation, _ resource: DicomResourceRef,
               filtering: Bool = false) async throws -> Bool {
        var current = context
        current.at = Date()
        if let authorizer {
            var decision = await authorizer.decide(principal: principal, operation: operation,
                                                   resource: resource, context: current)
            if decision.outcome == .allow {
                let reason: DicomAuthorizationDecision.Reason?
                if let principal, principal.kind != .anonymous, principal.source != .none,
                   principal.authenticatedAt > current.at || (principal.expiresAt ?? .distantFuture) <= current.at {
                    reason = .principalExpired
                } else { reason = nil }
                if let reason {
                    decision = .init(outcome: .deny, reason: reason, policyVersion: decision.policyVersion,
                                     evaluatedAt: current.at)
                }
            }
            try await audit?.record(DicomAuditMessages.authorizationDecision(decision, principal: principal,
                operation: operation, context: current, resources: [resource]))
            if decision.reason == .policyUnavailable { throw DicomWebServerFailure(503, "Authorization unavailable.") }
            if decision.outcome != .allow {
                if filtering { return false }
                throw DicomWebServerFailure(decision.reason == .noPrincipal ? 401 : 403, "Access denied.")
            }
            if decision.obligations.contains(.auditRequired), audit == nil {
                throw DicomWebServerFailure(503, "Audit unavailable.")
            }
        }
        let event = operation == .query
            ? DicomAuditMessages.queryPerformed(principal: principal, context: current, resources: [resource])
            : DicomAuditMessages.dicomInstancesAccessed(principal: principal, context: current, resources: [resource])
        try await audit?.record(event)
        return true
    }

    /// Renew at each output boundary (N = 1). A failed renewal closes the stream with an error;
    /// no further multipart payload or closing boundary is emitted after revocation.
    func recheck(_ operation: DicomAccessOperation, _ resource: DicomResourceRef) async throws {
        _ = try await check(operation, resource)
        if let authorizer {
            var current = context
            current.at = Date()
            guard let lease = await authorizer.lease(principal: principal, operation: operation,
                resource: resource, context: current), lease.resource == resource,
                lease.operation == operation, lease.principal == principal,
                lease.decision.outcome == .allow, lease.expiresAt > current.at,
                lease.policyVersion == (await authorizer.policyVersion) else {
                throw DicomWebServerFailure(403, "Authorization lease revoked.")
            }
        }
    }

    func transferred(_ resource: DicomResourceRef) async throws {
        var current = context
        current.at = Date()
        try await audit?.record(DicomAuditMessages.instancesTransferred(principal: principal,
            context: current, resources: [resource]))
    }
}

enum DicomRequestAuthorization {
    @TaskLocal static var current: DicomEnforcement?
}

extension DicomResourceRef {
    static func instance(study: String, series: String, instance: String) -> Self {
        .init(kind: .instance, id: instance,
              parent: .init(kind: .series, id: series, parent: .init(kind: .study, id: study)))
    }
    static func dataSet(_ set: DicomDataSet) -> Self? {
        guard let study = set.string(for: .studyInstanceUID), !study.isEmpty else { return nil }
        let root = Self(kind: .study, id: study)
        guard let series = set.string(for: .seriesInstanceUID), !series.isEmpty else { return root }
        let parent = Self(kind: .series, id: series, parent: root)
        guard let instance = set.string(for: .sopInstanceUID), !instance.isEmpty else { return parent }
        return .init(kind: .instance, id: instance, parent: parent)
    }
}
