import Foundation

/// Optional LDAPv3 adapter. Construction never opens a connection or replaces a host's local principal.
public struct DicomLDAPAuthenticationService: Sendable {
    public typealias PrincipalMapping = @Sendable (DicomLDAPIdentity, Date) -> DicomPrincipal?
    private let configuration: DicomLDAPConfiguration
    private let mapIdentity: PrincipalMapping
    private let authorizer: any DicomAuthorizing
    private let audit: DicomAuditRecorder
    private let now: @Sendable () -> Date

    public init(configuration: DicomLDAPConfiguration, mapIdentity: @escaping PrincipalMapping,
                authorizer: any DicomAuthorizing, audit: DicomAuditRecorder,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        try configuration.validate()
        self.configuration = configuration; self.mapIdentity = mapIdentity
        self.authorizer = authorizer; self.audit = audit; self.now = now
    }

    /// Obtain secrets from the host's credential store or transient input, never a configuration document.
    /// Anonymous bind is permitted only for discovery when searchBindDN is explicitly absent.
    public func authenticate(username: String, password: Data, searchPassword: Data? = nil,
                             context: DicomAccessContext) async throws -> DicomPrincipal {
        let loginContext = DicomAccessContext(peerAddress: configuration.host, peerPort: configuration.port,
            transportSecured: configuration.transport == .ldaps, protocol: context.protocol,
            requestID: context.requestID, at: now())
        do {
            try Task.checkCancellation()
            guard !username.isEmpty, username.utf8.count <= 4096, !password.isEmpty, password.count <= 4096,
                  configuration.searchBindDN == nil ? searchPassword == nil
                    : (searchPassword.map { !$0.isEmpty && $0.count <= 4096 } ?? false) else {
                throw DicomLDAPError.invalidCredentials
            }
            let identity = try await verifiedIdentity(username: username, password: password, searchPassword: searchPassword)
            try Task.checkCancellation()
            let timestamp = now()
            guard let principal = mapIdentity(identity, timestamp) else { throw DicomLDAPError.unmappedIdentity }
            guard principal.source == .ldap, principal.kind != .anonymous, !principal.id.isEmpty,
                  !principal.sessionID.isEmpty, principal.authenticatedAt <= timestamp,
                  let expiry = principal.expiresAt, expiry > timestamp else { throw DicomLDAPError.expiredPrincipal }
            try await audit.record(DicomAuditMessages.userAuthentication(.login, principal: principal, context: loginContext))
            try Task.checkCancellation()
            guard expiry > now() else { throw DicomLDAPError.expiredPrincipal }
            return principal
        } catch {
            try await audit.record(DicomAuditMessages.userAuthentication(.failure, principal: nil, context: loginContext))
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// The existing injected authorizer retains responsibility for operation, resource, expiry and policy version.
    public func authenticateAndAuthorize(username: String, password: Data, searchPassword: Data? = nil,
                                         operation: DicomAccessOperation, resource: DicomResourceRef,
                                         context: DicomAccessContext) async throws -> DicomPrincipal {
        let principal = try await authenticate(username: username, password: password, searchPassword: searchPassword,
                                                context: context)
        let current = DicomAccessContext(callingAETitle: context.callingAETitle, calledAETitle: context.calledAETitle,
            peerAddress: context.peerAddress, peerPort: context.peerPort, transportSecured: context.transportSecured,
            protocol: context.protocol, requestID: context.requestID, at: now())
        let decision = await authorizer.decide(principal: principal, operation: operation, resource: resource, context: current)
        try await audit.record(DicomAuditMessages.authorizationDecision(decision, principal: principal,
            operation: operation, context: current, resources: [resource]))
        try Task.checkCancellation()
        guard let expiry = principal.expiresAt, expiry > now() else { throw DicomLDAPError.expiredPrincipal }
        guard decision.outcome == .allow else { throw DicomLDAPError.authorizationDenied }
        return principal
    }

    private func verifiedIdentity(username: String, password: Data, searchPassword: Data?) async throws -> DicomLDAPIdentity {
        #if canImport(Network)
        let connection = try DicomLDAPConnection(configuration: configuration)
        do {
            try await connection.open()
            try await connection.bind(dn: configuration.searchBindDN ?? "", password: searchPassword ?? Data())
            let users = try await connection.search(base: configuration.userBaseDN,
                filter: .init(attribute: configuration.userAttribute, value: username),
                attributes: [configuration.userAttribute], limit: 2)
            guard users.count == 1, let user = users.first,
                  let names = user.attributes[configuration.userAttribute.lowercased()], names.count == 1,
                  let name = names.first, !name.isEmpty else { throw DicomLDAPError.identityNotUnique }
            try await connection.bind(dn: user.dn, password: password)
            let groups = try await connection.search(base: configuration.groupBaseDN,
                filter: .init(attribute: configuration.groupMemberAttribute, value: user.dn),
                attributes: ["1.1"], limit: configuration.maximumGroups)
            await connection.close()
            return .init(distinguishedName: user.dn, username: name, groups: Set(groups.map(\.dn)))
        } catch {
            await connection.close()
            throw error
        }
        #else
        throw DicomLDAPError.unsupportedPlatform
        #endif
    }
}
