import Foundation
import XCTest
@testable import DicomCore

private actor AuditRevocation: DicomAuthorizationRevoking {
    var revoked = false
    var version: Int64 = 1
    func isRevoked(principalID: String) -> Bool { revoked }
    func currentPolicyVersion() -> Int64 { version }
    func revoke() { revoked = true }
    func bump() { version += 1 }
}
final class DicomAuthorizationLeaseTests: XCTestCase, @unchecked Sendable {
    func lease(at now: Date) async throws -> DicomAuthorizationLease {
        let p = DicomPrincipal(id: "user", kind: .localUser, source: .local, sessionID: "session",
            authenticatedAt: now, expiresAt: now.addingTimeInterval(10), policyVersion: 1)
        let lease = await DicomProtectionAuthorizer(policyVersion: 1) { _ in [:] }.lease(principal: p,
            operation: .readBytes, resource: .init(kind: .instance, id: "instance"), context: .init(protocol: .local, at: now))
        return try XCTUnwrap(lease)
    }
    func test_leaseValid_thenRevokedMidway_denied() async throws {
        let now = Date(); let lease = try await lease(at: now)
        let revocation = AuditRevocation(); let validator = DicomLeaseValidator(revocation: revocation)
        let initial = await validator.validate(lease, now: now)
        XCTAssertEqual(initial.outcome, .allow)
        await revocation.revoke()
        let revoked = await validator.validate(lease, now: now.addingTimeInterval(1))
        XCTAssertEqual(revoked.reason, .principalRevoked)
        XCTAssertEqual(lease.operation, .readBytes); XCTAssertEqual(lease.resource.id, "instance")
    }
    func test_policyVersionBump_invalidatesLease() async throws {
        let now = Date(); let lease = try await lease(at: now); let revocation = AuditRevocation()
        await revocation.bump()
        let result = await DicomLeaseValidator(revocation: revocation).validate(lease, now: now)
        XCTAssertEqual(result.reason, .policyVersionChanged)
    }
    func test_expiryAtBoundary_denied() async throws {
        let now = Date(); let lease = try await lease(at: now)
        XCTAssertEqual(lease.expiresAt, now.addingTimeInterval(10))
        let result = await DicomLeaseValidator(revocation: AuditRevocation()).validate(lease, now: lease.expiresAt)
        XCTAssertEqual(result.reason, .principalExpired)
    }
}
