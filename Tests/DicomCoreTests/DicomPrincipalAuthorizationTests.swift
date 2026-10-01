import Foundation
import XCTest
@testable import DicomCore

final class DicomPrincipalAuthorizationTests: XCTestCase, @unchecked Sendable {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func principal(scopes: Set<String> = [], roles: Set<String> = [], expires: Date? = nil) -> DicomPrincipal {
        .init(id: "opaque-user", kind: .localUser, source: .local, scopes: scopes, roles: roles,
              sessionID: "session", authenticatedAt: now.addingTimeInterval(-1), expiresAt: expires, policyVersion: 1)
    }
    func test_enforcement_honoursAnonymousAndNilAuthorizerAllow() async throws {
        for principal in [nil, DicomPrincipal.anonymous] {
            let authorizer = AnonymousAllowAuthorizer()
            let access = DicomEnforcement(principal: principal, authorizer: authorizer,
                                         audit: nil, context: .init(protocol: .dimse))
            let resource = DicomResourceRef(kind: .study, id: "2.25.2359")
            let allowed = try await access.check(.query, resource)
            XCTAssertTrue(allowed)
            let received = await authorizer.principals
            XCTAssertEqual(received, [principal])
        }
    }

    func test_denyAllAndUnavailable_failClosed() async {
        let resource = DicomResourceRef(kind: .study, id: "1.2")
        let context = DicomAccessContext(protocol: .dimse, at: now)
        let deny = await DicomDenyAllAuthorizer().decide(principal: principal(), operation: .query, resource: resource, context: context)
        XCTAssertEqual(deny.outcome, .deny)
        let wrapper = DicomFailClosedAuthorizer(wrapping: DicomProtectionAuthorizer(policyVersion: 1) { _ in [:] }, isAvailable: { false })
        let decision = await wrapper.decide(principal: principal(), operation: .query, resource: resource, context: context)
        let lease = await wrapper.lease(principal: principal(), operation: .readBytes, resource: resource, context: context)
        XCTAssertEqual(decision.reason, .policyUnavailable); XCTAssertNil(lease)
    }
    func test_privacyMatrix_operationsAndScopes() async {
        let flags: [DicomObjectProtection.PrivacyFlag] = [.restricted, .researchOnly, .vip]
        for flag in flags {
            let scope = flag == .restricted ? "phi:restricted" : flag == .vip ? "phi:vip" : "research"
            let authorizer = DicomProtectionAuthorizer(policyVersion: 1) { _ in ["1.2": .init(privacyFlags: [flag])] }
            for operation in DicomAccessOperation.allCases {
                for granted in [false, true] {
                    let scopes: Set<String> = granted ? [scope, "export"] : ["export"]
                    let decision = await authorizer.decide(principal: principal(scopes: scopes, roles: ["admin"]),
                        operation: operation, resource: .init(kind: .study, id: "1.2"), context: .init(protocol: .local, at: now))
                    let expected = granted && (flag != .researchOnly || [.query, .readMetadata, .derive].contains(operation))
                    XCTAssertEqual(decision.outcome, expected ? .allow : .deny, "\(flag) \(operation) \(granted)")
                }
            }
        }
    }
    func test_derivativeAndRepresentation_cannotBypassSource() async {
        let patient = DicomResourceRef(kind: .patient, id: "patient")
        let study = DicomResourceRef(kind: .study, id: "study", parent: patient)
        let instance = DicomResourceRef(kind: .instance, id: "instance", parent: .init(kind: .series, id: "series", parent: study))
        for kind in [DicomResourceRef.Kind.representation, .derivative] {
            let resource = DicomResourceRef(kind: kind, id: "alternate", parent: instance)
            XCTAssertEqual(resource.sourceObject, instance); XCTAssertEqual(resource.ancestry.count, 4)
            let authorizer = DicomProtectionAuthorizer(policyVersion: 1) { ref in
                ref.id == "instance" ? ["patient": .init(privacyFlags: [.restricted])] : [:]
            }
            for operation in [DicomAccessOperation.readBytes, .cacheRead, .export] {
                let decision = await authorizer.decide(principal: principal(scopes: ["export"]), operation: operation,
                    resource: resource, context: .init(protocol: .dicomweb, at: now))
                XCTAssertEqual(decision.reason, .resourceRestricted)
            }
            let missing = await authorizer.decide(principal: principal(), operation: .readBytes,
                resource: .init(kind: kind, id: "alternate"), context: .init(protocol: .local, at: now))
            XCTAssertEqual(missing.outcome, .deny)
        }
    }
    func test_deletion_inheritsAllBlockers() async {
        let cases: [(DicomObjectProtection, DicomAuthorizationDecision.Reason)] = [
            (.init(protected: true), .protectedFromDeletion), (.init(legalHold: true), .legalHold),
            (.init(retainUntil: now.addingTimeInterval(60)), .retention)]
        for (protection, reason) in cases {
            let authorizer = DicomProtectionAuthorizer(policyVersion: 1) { _ in ["study": protection] }
            for operation in [DicomAccessOperation.delete, .evict] {
                let decision = await authorizer.decide(principal: principal(), operation: operation,
                    resource: .init(kind: .instance, id: "instance", parent: .init(kind: .study, id: "study")),
                    context: .init(protocol: .local, at: now))
                XCTAssertEqual(decision.reason, reason)
            }
        }
    }
    func test_anonymousExpiredAndPolicyMismatch_denied() async {
        let authorizer = DicomProtectionAuthorizer(policyVersion: 1) { _ in [:] }
        for operation in DicomAccessOperation.allCases {
            for identity in [nil, DicomPrincipal.anonymous] {
                let decision = await authorizer.decide(principal: identity, operation: operation,
                    resource: .init(kind: .archive, id: "all"), context: .init(callingAETitle: "TRUSTED", peerAddress: "127.0.0.1", protocol: .dimse, at: now))
                XCTAssertEqual(decision.reason, .noPrincipal)
            }
        }
        let expired = await authorizer.decide(principal: principal(expires: now), operation: .query,
            resource: .init(kind: .archive, id: "all"), context: .init(protocol: .local, at: now))
        XCTAssertEqual(expired.reason, .principalExpired)
        let changed = await DicomProtectionAuthorizer(policyVersion: 2) { _ in [:] }.decide(principal: principal(), operation: .query,
            resource: .init(kind: .study, id: "s"), context: .init(protocol: .local, at: now))
        XCTAssertEqual(changed.reason, .policyVersionChanged)
    }
    func test_adminAndExport_requireExplicitGrants() async {
        let authorizer = DicomProtectionAuthorizer(policyVersion: 1) { _ in [:] }
        for operation in [DicomAccessOperation.export, .route, .configure, .modifyProtection, .auditExport] {
            let deny = await authorizer.decide(principal: principal(), operation: operation, resource: .init(kind: .configuration, id: "c"), context: .init(protocol: .local, at: now))
            let allow = await authorizer.decide(principal: principal(scopes: ["export"], roles: ["admin"]), operation: operation, resource: .init(kind: .configuration, id: "c"), context: .init(protocol: .local, at: now))
            XCTAssertEqual(deny.reason, .scopeMissing); XCTAssertEqual(allow.outcome, .allow)
        }
    }
    func test_principalCodable_boundsEvidenceAndRejectsSecretKeys() throws {
        let p = DicomPrincipal(id: "opaque", kind: .serviceAccount, source: .oidc, sessionID: "s", authenticatedAt: now,
            policyVersion: 1, evidence: ["issuer": String(repeating: "a", count: 1000), "kid": "k", "password": "secret"])
        XCTAssertEqual(p.evidence["issuer"]?.count, 200); XCTAssertNil(p.evidence["password"])
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(DicomPrincipal.self, from: data), p)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
    }
}

private actor AnonymousAllowAuthorizer: DicomAuthorizing {
    let policyVersion: Int64 = 17
    var principals: [DicomPrincipal?] = []
    func decide(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
                context: DicomAccessContext) -> DicomAuthorizationDecision {
        principals.append(principal)
        return .init(outcome: .allow, reason: .allowed, policyVersion: policyVersion,
                     evaluatedAt: context.at)
    }
}
