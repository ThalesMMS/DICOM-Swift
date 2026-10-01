import XCTest
@testable import DicomCore

final class DicomDestructiveExecutorRecheckTests: XCTestCase, @unchecked Sendable {
    func test_ancestorProtectionAddedAfterPlanning_blocksAction() async throws {
        let action = DicomDestructivePlan.Action(kind: .delete, objectKey: "instance", providerID: "source",
            locator: "synthetic", byteCount: 1, reason: "synthetic", lastVerifiedCopy: false)
        let report = try await DicomDestructiveExecutor().execute(plan: .init(actions: [action]),
            authorization: .init(token: "synthetic", reason: "test"), providers: [:],
            placements: placements(for: action), verifiedCopies: [action.objectKey: 2],
            protections: [:], graph: .init(parents: ["instance": "series", "series": "study"]), dryRun: false,
            protectionReloader: { key in key == "study" ? .init(legalHold: true) : nil })
        XCTAssertTrue(report.executed.isEmpty)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(report.blockedAfterPlanning, [action])
    }

    func test_deniedSecondCheck_allowsLaterAuthorizedRetry() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let source = DicomLocalDiskProvider(id: "source", root: fixture.source)
        let action = DicomDestructivePlan.Action(kind: .delete, objectKey: item.objectKey, providerID: "source",
            locator: item.sourceLocator, byteCount: item.byteCount, reason: "synthetic", lastVerifiedCopy: false)
        let executor = DicomDestructiveExecutor()
        let checks = DestructiveProtectionChecks()
        let blocked = try await executor.execute(plan: .init(actions: [action]),
            authorization: .init(token: "synthetic", reason: "test"), providers: ["source": source],
            placements: placements(for: action), verifiedCopies: [action.objectKey: 2],
            protections: [:], graph: .init(parents: [:]), dryRun: false,
            protectionReloader: { _ in await checks.next() })
        XCTAssertEqual(blocked.blockedAfterPlanning, [action])
        let before = try await source.head(item.sourceLocator)
        XCTAssertNotNil(before)
        let retried = try await executor.execute(plan: .init(actions: [action]),
            authorization: .init(token: "synthetic", reason: "test"), providers: ["source": source],
            placements: placements(for: action), verifiedCopies: [action.objectKey: 2],
            protections: [:], graph: .init(parents: [:]), dryRun: false)
        XCTAssertEqual(retried.executed, [action])
        XCTAssertTrue(retried.failed.isEmpty)
        let after = try await source.head(item.sourceLocator)
        XCTAssertNil(after)
    }
    func test_protectionAddedAfterPlanning_blocksAction() async throws {
        let action = DicomDestructivePlan.Action(kind: .delete, objectKey: "synthetic", providerID: "source",
            locator: "synthetic", byteCount: 1, reason: "synthetic", lastVerifiedCopy: false)
        let report = try await DicomDestructiveExecutor().execute(plan: .init(actions: [action]),
            authorization: .init(token: "synthetic", reason: "test"), providers: [:],
            placements: placements(for: action), verifiedCopies: [action.objectKey: 2],
            protections: [:], graph: .init(parents: [:]), dryRun: false,
            protectionReloader: { _ in .init(legalHold: true) })
        XCTAssertTrue(report.executed.isEmpty)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(report.blockedAfterPlanning, [action])
        XCTAssertEqual(report.skipped, [action])
    }
    func test_deleteDecisionRevoked_skipsAction() async throws {
        let policy = AuthorizationTestPolicy()
        await policy.deny("synthetic")
        let action = DicomDestructivePlan.Action(kind: .evictCache, objectKey: "synthetic", providerID: "source",
            locator: "synthetic", byteCount: 1, reason: "synthetic", lastVerifiedCopy: false)
        let report = try await DicomDestructiveExecutor().execute(plan: .init(actions: [action]),
            authorization: .init(token: "synthetic", reason: "test"), providers: [:],
            placements: placements(for: action), verifiedCopies: [action.objectKey: 2],
            protections: [:], graph: .init(parents: [:]), dryRun: false,
            authorizer: policy, principal: authorizationPrincipal())
        XCTAssertEqual(report.blockedAfterPlanning, [action])
        XCTAssertTrue(report.failed.isEmpty)
    }

    // Keep planning permissive so the tests reach the later protection and authorization rechecks.
    private func placements(for action: DicomDestructivePlan.Action) -> [String: [DicomObjectPlacement]] {
        [action.objectKey: [action.providerID, "backup"].map {
            .init(objectKey: action.objectKey, tier: .online, providerID: $0, locator: action.locator,
                byteCount: action.byteCount, sha256: action.sha256 ?? "synthetic")
        }]
    }
}

private actor DestructiveProtectionChecks {
    private var count = 0
    func next() -> DicomObjectProtection? {
        count += 1
        return count == 2 ? .init(legalHold: true) : nil
    }
}
