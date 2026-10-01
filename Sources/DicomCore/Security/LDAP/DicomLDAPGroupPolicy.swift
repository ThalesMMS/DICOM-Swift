import Foundation

/// Explicit grants keyed by the exact group DN returned by this configured directory.
/// Membership is not itself an application role. Unmapped membership never issues a principal.
public struct DicomLDAPGroupPolicy: Codable, Equatable, Sendable {
    public struct Grant: Codable, Equatable, Sendable {
        public let scopes: Set<String>
        public let roles: Set<String>
        public init(scopes: Set<String> = [], roles: Set<String> = []) { self.scopes = scopes; self.roles = roles }
    }
    public let groups: [String: Grant]
    public let policyVersion: Int64
    public let sessionLifetime: TimeInterval
    public init(groups: [String: Grant], policyVersion: Int64, sessionLifetime: TimeInterval = 300) {
        self.groups = groups; self.policyVersion = policyVersion; self.sessionLifetime = sessionLifetime
    }
    public func principal(for identity: DicomLDAPIdentity, at now: Date) -> DicomPrincipal? {
        let grants = identity.groups.compactMap { groups[$0] }
        guard !grants.isEmpty, sessionLifetime.isFinite, sessionLifetime > 0, sessionLifetime <= 3600 else { return nil }
        return .init(id: identity.distinguishedName, kind: .localUser, source: .ldap,
            scopes: Set(grants.flatMap(\.scopes)), roles: Set(grants.flatMap(\.roles)),
            sessionID: UUID().uuidString, authenticatedAt: now,
            expiresAt: now.addingTimeInterval(sessionLifetime), policyVersion: policyVersion)
    }
}
