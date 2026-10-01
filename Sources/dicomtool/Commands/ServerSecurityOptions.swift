import ArgumentParser
import Foundation
import DicomCore

struct ServerSecurityOptions: ParsableArguments {
    @Option var auditSyslog: String?
    @Flag var auditTls = false
    @Option var auditTlsCa: String?
    @Option var auditTlsCertificate: String?
    @Option var auditTlsKey: String?
    @Flag var auditFailClosed = false
    @Option var principalScopes: [String] = []

    func recorder() throws -> DicomAuditRecorder {
        guard !auditTls || auditSyslog != nil,
              auditTls || (auditTlsCa == nil && auditTlsCertificate == nil && auditTlsKey == nil),
              (auditTlsCertificate == nil) == (auditTlsKey == nil),
              !auditFailClosed || auditSyslog != nil else { throw ValidationError("Invalid audit configuration") }
        let sinks: [any DicomAuditSink]
        if let auditSyslog {
            guard let parts = URLComponents(string: "tcp://" + auditSyslog), let host = parts.host,
                  let port = parts.port, (1...65535).contains(port), parts.user == nil, parts.password == nil,
                  parts.path.isEmpty, parts.query == nil, parts.fragment == nil else { throw ValidationError("Expected audit host:port") }
            sinks = [try DicomAuditSyslogSink(host: host, port: UInt16(port),
                tls: .init(mode: auditTls ? .enabled : .disabled, serverName: host,
                    material: .init(certificatePath: auditTlsCertificate, privateKeyPath: auditTlsKey,
                                    trustStorePath: auditTlsCa)))]
        } else { sinks = [] }
        return DicomAuditRecorder(sinks: sinks, policy: auditFailClosed ? .failClosed : .bestEffort)
    }

    static func isLoopback(_ address: String) -> Bool {
        (try? DicomExposurePolicy.defaults(for: .localOnly).validate(bindAddress: address,
            tlsEnabled: false, authenticationConfigured: true)) != nil
    }

    static func exposure(host: String, tls: Bool, authentication: Bool, lab: Bool) throws -> DicomExposurePolicy {
        let local = isLoopback(host)
        let policy = DicomExposurePolicy(mode: lab ? .intranetLab : local ? .localOnly : .external,
            requireTLS: !local && !lab, requireAuthentication: !local,
            allowUnauthorizedIntranetLab: lab)
        _ = try policy.validate(bindAddress: host, tlsEnabled: tls, authenticationConfigured: authentication)
        return policy
    }

    func principal() -> DicomPrincipal {
        .init(id: "dicomtool-local", kind: .localUser, source: .local, scopes: Set(principalScopes),
            sessionID: UUID().uuidString, authenticatedAt: Date(), policyVersion: 0)
    }
}

struct CommandWebPrincipals: DicomWebPrincipalResolving {
    let authentication: (any DicomWebPrincipalResolving)?
    let local: DicomPrincipal?
    let scopes: Set<String>
    func principal(for request: DicomWebHTTPRequest) async -> DicomPrincipal? {
        guard let authentication else { return local }
        guard let verified = await authentication.principal(for: request) else { return nil }
        return .init(id: verified.id, kind: verified.kind, source: verified.source, scopes: scopes,
            sessionID: verified.sessionID, authenticatedAt: verified.authenticatedAt,
            expiresAt: verified.expiresAt, policyVersion: verified.policyVersion)
    }
}
