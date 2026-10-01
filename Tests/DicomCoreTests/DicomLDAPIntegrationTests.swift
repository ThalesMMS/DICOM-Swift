import Foundation
import XCTest
@testable import DicomCore

/// Runs against independent OpenLDAP started by Tools/Scripts/ldap_loopback_fixture.py in the parent repository.
final class DicomLDAPIntegrationTests: XCTestCase, @unchecked Sendable {
    private struct Fixture: Decodable {
        let ldapPort: UInt16
        let ldapsPort: UInt16
        let stalledPort: UInt16
        let truncatedPort: UInt16
        let oversizedPort: UInt16
        let unavailablePort: UInt16
        let caPath: String
        let wrongCAPath: String
        let passwordPath: String
        let searchPasswordPath: String
    }
    private func fixture() throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["ISIS_LDAP_FIXTURE"] else {
            throw XCTSkip("Run Tools/Scripts/ldap_loopback_fixture.py for independent LDAP integration")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    private func configuration(_ fixture: Fixture) -> DicomLDAPConfiguration {
        .init(host: "127.0.0.1", port: fixture.ldapPort, transport: .loopbackPlaintext,
            userBaseDN: "ou=people,dc=example,dc=test", groupBaseDN: "ou=groups,dc=example,dc=test")
    }
    private func password(_ fixture: Fixture) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: fixture.passwordPath)) }
    private var policy: DicomLDAPGroupPolicy {
        .init(groups: ["cn=readers,ou=groups,dc=example,dc=test": .init(scopes: ["export"], roles: ["reader"])],
            policyVersion: 3, sessionLifetime: 60)
    }
    private func service(_ config: DicomLDAPConfiguration, sink: DicomInMemoryAuditSink = .init(),
                         authorizer: (any DicomAuthorizing)? = nil,
                         mapping: DicomLDAPAuthenticationService.PrincipalMapping? = nil) throws -> DicomLDAPAuthenticationService {
        let policy = policy
        return try .init(configuration: config, mapIdentity: mapping ?? { policy.principal(for: $0, at: $1) },
            authorizer: authorizer ?? DicomProtectionAuthorizer(policyVersion: 3) { _ in [:] },
            audit: .init(sinks: [sink], policy: .failClosed))
    }
    private func assertError(_ expected: DicomLDAPError, _ operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected LDAP refusal", file: file, line: line) }
        catch { XCTAssertEqual(error as? DicomLDAPError, expected, file: file, line: line) }
    }

    func test_openLDAP_authenticationGroupMappingAuthorizationAndAudit() async throws {
        let fixture = try fixture(); let sink = DicomInMemoryAuditSink()
        let service = try service(configuration(fixture), sink: sink)
        let principal = try await service.authenticateAndAuthorize(username: "alice", password: password(fixture),
            operation: .export, resource: .init(kind: .archive, id: "synthetic"), context: .init(protocol: .cli))
        XCTAssertEqual(principal.id, "cn=Alice,ou=people,dc=example,dc=test")
        XCTAssertEqual(principal.scopes, ["export"]); XCTAssertEqual(principal.roles, ["reader"])
        let events = await sink.events
        XCTAssertEqual(events.count, 2)
        let encoded = try JSONEncoder().encode(events)
        XCTAssertFalse(encoded.range(of: try password(fixture)) != nil)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("110114"))
    }

    func test_openLDAP_literalFilterCharacters_doNotBroadenSearch() async throws {
        let fixture = try fixture(); let service = try service(configuration(fixture))
        let escaped = try await service.authenticate(username: "a*)(uid=*)\\é", password: password(fixture), context: .init(protocol: .cli))
        XCTAssertEqual(escaped.id, "cn=Escaped,ou=people,dc=example,dc=test")
        await assertError(.identityNotUnique) {
            _ = try await service.authenticate(username: "*)(uid=*)", password: self.password(fixture), context: .init(protocol: .cli))
        }
    }

    func test_openLDAP_missingDuplicateUnmappedAndInvalidCredentials_deny() async throws {
        let fixture = try fixture(); let sink = DicomInMemoryAuditSink()
        let service = try service(configuration(fixture), sink: sink)
        for (username, secret, error) in [
            ("missing", try password(fixture), DicomLDAPError.identityNotUnique),
            ("duplicate", try password(fixture), .identityNotUnique),
            ("bob", try password(fixture), .unmappedIdentity),
            ("alice", Data("wrong".utf8), .invalidCredentials),
            ("alice", Data(), .invalidCredentials)
        ] {
            await assertError(error) {
                _ = try await service.authenticate(username: username, password: secret, context: .init(protocol: .cli))
            }
        }
        let events = await sink.events
        XCTAssertEqual(events.count, 5)
        XCTAssertTrue(events.allSatisfy { $0.eventIdentification.eventOutcomeIndicator != .success })
    }

    func test_openLDAP_optionalSearchBind_usesSeparateTransientCredential() async throws {
        let fixture = try fixture(); var config = configuration(fixture)
        config.searchBindDN = "cn=manager,dc=example,dc=test"
        let service = try service(config)
        let searchPassword = try Data(contentsOf: URL(fileURLWithPath: fixture.searchPasswordPath))
        _ = try await service.authenticate(username: "alice", password: password(fixture), searchPassword: searchPassword,
            context: .init(protocol: .cli))
        for secret in [nil, Data(), Data("wrong".utf8)] {
            await assertError(.invalidCredentials) {
                _ = try await service.authenticate(username: "alice", password: self.password(fixture), searchPassword: secret,
                    context: .init(protocol: .cli))
            }
        }
    }

    func test_openLDAP_ldapsValidTrustSucceedsAndInvalidTrustNeverFallsBack() async throws {
        let fixture = try fixture(); var config = configuration(fixture)
        config.port = fixture.ldapsPort; config.transport = .ldaps; config.trustStorePath = fixture.caPath
        _ = try await service(config).authenticate(username: "alice", password: password(fixture), context: .init(protocol: .cli))
        config.trustStorePath = fixture.wrongCAPath
        let invalid = try service(config)
        await assertError(.tlsFailure) {
            _ = try await invalid.authenticate(username: "alice", password: self.password(fixture), context: .init(protocol: .cli))
        }
    }

    func test_openLDAP_groupSizeLimit_discardsPartialMembership() async throws {
        let fixture = try fixture(); var config = configuration(fixture); config.maximumGroups = 1
        let service = try service(config)
        await assertError(.serverResult(4)) {
            _ = try await service.authenticate(username: "alice", password: self.password(fixture), context: .init(protocol: .cli))
        }
    }

    func test_openLDAP_expiryPolicyUnavailableAndMissingScope_deny() async throws {
        let fixture = try fixture(); let config = configuration(fixture)
        let expired = try service(config, mapping: { identity, now in
            .init(id: identity.distinguishedName, kind: .localUser, source: .ldap, sessionID: "expired",
                authenticatedAt: now.addingTimeInterval(-1), expiresAt: now, policyVersion: 3)
        })
        await assertError(.expiredPrincipal) {
            _ = try await expired.authenticate(username: "alice", password: self.password(fixture), context: .init(protocol: .cli))
        }
        let unavailable = DicomFailClosedAuthorizer(wrapping: DicomProtectionAuthorizer(policyVersion: 3) { _ in [:] },
            isAvailable: { false })
        for service in [try service(config, authorizer: unavailable), try service(config)] {
            await assertError(.authorizationDenied) {
                _ = try await service.authenticateAndAuthorize(username: "alice", password: self.password(fixture),
                    operation: .configure, resource: .init(kind: .configuration, id: "synthetic"), context: .init(protocol: .cli))
            }
        }
    }

    func test_transport_unavailableTimeoutTruncatedAndOversizedResponses_deny() async throws {
        let fixture = try fixture()
        for (port, error) in [(fixture.unavailablePort, DicomLDAPError.unavailable), (fixture.stalledPort, .timeout),
                              (fixture.truncatedPort, .truncatedResponse), (fixture.oversizedPort, .responseLimit)] {
            var config = configuration(fixture); config.port = port; config.timeout = 0.5
            let service = try service(config)
            await assertError(error) {
                _ = try await service.authenticate(username: "alice", password: self.password(fixture), context: .init(protocol: .cli))
            }
        }
    }

    func test_transport_cancellationClosesPendingReceivePromptly() async throws {
        let fixture = try fixture(); var config = configuration(fixture); config.port = fixture.stalledPort
        let service = try service(config); let password = try password(fixture)
        let task = Task { try await service.authenticate(username: "alice", password: password, context: .init(protocol: .cli)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled authentication granted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }
}
