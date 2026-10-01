import Foundation
import XCTest
@testable import DicomCore

final class DicomDestructivePlanTests: XCTestCase {
    private func plan(_ fixture: BackupFixture, copies: Int = 2, migrate: Bool = false,
                      protection: DicomObjectProtection = .init()) -> DicomDestructivePlan {
        let object = fixture.inventory.objects[0]
        let placements = (0..<copies).map { index in
            DicomObjectPlacement(objectKey: object.objectKey, tier: .online,
                providerID: index == 0 ? "source" : "other\(index)", locator: object.objectKey,
                byteCount: object.byteCount, sha256: object.sha256)
        }
        return DicomDestructivePlanner().plan(candidates: [.init(kind: migrate ? .migrate : .delete,
            objectKey: object.objectKey, providerID: "source", locator: object.objectKey, byteCount: object.byteCount,
            reason: "Test authorized removal", targetProviderID: migrate ? "destination" : nil,
            targetLocator: migrate ? object.objectKey : nil, sha256: object.sha256)],
            placements: [object.objectKey: placements], verifiedCopies: [object.objectKey: copies],
            protections: [object.objectKey: protection], graph: .init(parents: [:]), now: Date())
    }

    private func placements(_ fixture: BackupFixture, copies: Int = 2) -> [String: [DicomObjectPlacement]] {
        let object = fixture.inventory.objects[0]
        return [object.objectKey: (0..<copies).map { index in
            DicomObjectPlacement(objectKey: object.objectKey, tier: .online,
                providerID: index == 0 ? "source" : "other\(index)", locator: object.objectKey,
                byteCount: object.byteCount, sha256: object.sha256)
        }]
    }

    func test_onlyVerifiedCopy_isBlocked() throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let result = plan(fixture, copies: 1)
        XCTAssertTrue(result.executable.isEmpty)
        XCTAssertTrue(result.blocked[0].lastVerifiedCopy)
    }

    func test_protection_blocksDeletion() throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        XCTAssertEqual(plan(fixture, protection: .init(protected: true)).blocked[0].blockers, [.protected])
    }

    @MainActor
    func test_defaultDryRun_andEmptyToken_leaveBytesIntact() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let executor = DicomDestructiveExecutor()
        let input = plan(fixture)
        let result = try await executor.execute(plan: input, authorization: .init(token: "", reason: ""),
            providers: ["source": fixture.source], placements: placements(fixture),
            verifiedCopies: [fixture.inventory.objects[0].objectKey: 2], protections: [:], graph: .init(parents: [:]))
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.plan, input)
        XCTAssertTrue(result.executed.isEmpty)
        XCTAssertTrue(try fixture.fs.exists(fixture.source.root.appendingPathComponent("object0.dcm")))
        do {
            _ = try await executor.execute(plan: input, authorization: .init(token: "", reason: ""),
                providers: ["source": fixture.source], placements: placements(fixture, copies: 1),
                verifiedCopies: [fixture.inventory.objects[0].objectKey: 1], protections: [:], graph: .init(parents: [:]),
                dryRun: false)
            XCTFail("Expected authorization failure")
        } catch { XCTAssertEqual(error as? DicomStorageProviderError, .deleteNotAuthorized) }
        XCTAssertTrue(try fixture.fs.exists(fixture.source.root.appendingPathComponent("object0.dcm")))
    }

    @MainActor
    func test_migrate_verifiesTargetBeforeDeletingSource() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let result = try await DicomDestructiveExecutor().execute(plan: plan(fixture, copies: 1, migrate: true),
            authorization: .init(token: "approved", reason: "test"),
            providers: ["source": fixture.source, "destination": fixture.destination],
            placements: placements(fixture, copies: 1), verifiedCopies: [fixture.inventory.objects[0].objectKey: 1],
            protections: [:], graph: .init(parents: [:]), dryRun: false)
        XCTAssertEqual(result.executed.count, 1)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(try fixture.fs.exists(fixture.source.root.appendingPathComponent("object0.dcm")))
        XCTAssertEqual(try fixture.fs.checksum(fixture.destination.root.appendingPathComponent("object0.dcm")),
                       fixture.inventory.objects[0].sha256)
    }

    @MainActor
    func test_corruptedMigrationTarget_keepsSource() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let result = try await DicomDestructiveExecutor().execute(plan: plan(fixture, copies: 1, migrate: true),
            authorization: .init(token: "approved", reason: "test"),
            providers: ["source": fixture.source, "destination": CorruptingBackupProvider(base: fixture.destination)],
            placements: placements(fixture, copies: 1), verifiedCopies: [fixture.inventory.objects[0].objectKey: 1],
            protections: [:], graph: .init(parents: [:]), dryRun: false)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(result.executed.isEmpty)
        XCTAssertTrue(try fixture.fs.exists(fixture.source.root.appendingPathComponent("object0.dcm")))
    }

    @MainActor
    func test_failedMigration_releasesPlacementForRetryButSuccessfulDeleteStaysGuarded() async throws {
        let failures: [(source: FailingDestructiveProvider.Operation?, target: FailingDestructiveProvider.Operation?)] = [
            (.head, nil), (.get, nil), (nil, .put), (nil, .get), (.delete, nil)
        ]
        for failure in failures {
            let fixture = try BackupFixture()
            defer { fixture.cleanup() }
            let executor = DicomDestructiveExecutor()
            let input = plan(fixture, copies: 1, migrate: true)
            let authorization = DicomDeleteAuthorization(token: "approved", reason: "test")
            let copies = [fixture.inventory.objects[0].objectKey: 1]
            let failed = try await executor.execute(plan: input, authorization: authorization,
                providers: [
                    "source": FailingDestructiveProvider(base: fixture.source, failure: failure.source),
                    "destination": FailingDestructiveProvider(base: fixture.destination, failure: failure.target)
                ], placements: placements(fixture, copies: 1), verifiedCopies: copies,
                protections: [:], graph: .init(parents: [:]), dryRun: false)
            XCTAssertEqual(failed.failed.count, 1)
            XCTAssertTrue(failed.executed.isEmpty)
            XCTAssertTrue(try fixture.fs.exists(fixture.source.root.appendingPathComponent("object0.dcm")))

            let providers: [String: any DicomStorageProvider] = ["source": fixture.source, "destination": fixture.destination]
            let retryPlan = plan(fixture)
            let retried = try await executor.execute(plan: retryPlan, authorization: authorization, providers: providers,
                placements: placements(fixture), verifiedCopies: [fixture.inventory.objects[0].objectKey: 2],
                protections: [:], graph: .init(parents: [:]), dryRun: false)
            XCTAssertEqual(retried.executed.count, 1)
            XCTAssertTrue(retried.failed.isEmpty)

            let repeated = try await executor.execute(plan: retryPlan, authorization: authorization, providers: providers,
                placements: placements(fixture), verifiedCopies: [fixture.inventory.objects[0].objectKey: 2],
                protections: [:], graph: .init(parents: [:]), dryRun: false)
            XCTAssertTrue(repeated.executed.isEmpty)
            XCTAssertTrue(repeated.failed.first?.reason.contains("Placement already executed") == true)
        }
    }

    @MainActor
    func test_authorizedBlockedAction_isSkipped() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let result = try await DicomDestructiveExecutor().execute(plan: plan(fixture, copies: 1),
            authorization: .init(token: "approved", reason: "test"), providers: ["source": fixture.source], placements: placements(fixture, copies: 1),
                verifiedCopies: [fixture.inventory.objects[0].objectKey: 1], protections: [:], graph: .init(parents: [:]),
                dryRun: false)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(try fixture.fs.exists(fixture.source.root.appendingPathComponent("object0.dcm")))
    }

    @MainActor
    func test_editedPlanCannotRemoveLastCopy() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        var edited = plan(fixture, copies: 1).actions[0]
        edited.blockers = []
        edited.lastVerifiedCopy = false
        let input = try JSONDecoder().decode(DicomDestructivePlan.self,
            from: JSONEncoder().encode(DicomDestructivePlan(actions: [edited])))
        let result = try await DicomDestructiveExecutor().execute(plan: input,
            authorization: .init(token: "approved", reason: "test"), providers: ["source": fixture.source],
            placements: placements(fixture, copies: 1), verifiedCopies: [edited.objectKey: 1],
            protections: [:], graph: .init(parents: [:]), dryRun: false)
        XCTAssertTrue(result.executed.isEmpty)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertTrue(result.skipped[0].lastVerifiedCopy)
        XCTAssertTrue(try fixture.fs.exists(fixture.source.root.appendingPathComponent(edited.locator)))
    }

    @MainActor
    func test_newLegalHoldBlocksPreviouslyExecutablePlan() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let input = plan(fixture)
        let key = fixture.inventory.objects[0].objectKey
        XCTAssertEqual(input.executable.count, 1)
        let result = try await DicomDestructiveExecutor().execute(plan: input,
            authorization: .init(token: "approved", reason: "test"), providers: ["source": fixture.source],
            placements: placements(fixture), verifiedCopies: [key: 2],
            protections: ["study": .init(legalHold: true)], graph: .init(parents: [key: "study"]), dryRun: false)
        XCTAssertTrue(result.executed.isEmpty)
        XCTAssertTrue(result.skipped[0].blockers.contains(.inheritedFrom("study", .legalHold)))
        XCTAssertTrue(try fixture.fs.exists(fixture.source.root.appendingPathComponent(key)))
    }

    func test_multipleRemovals_preserveOneCopyAcrossPlan() throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let object = fixture.inventory.objects[0]
        let placements = ["a", "b"].map { DicomObjectPlacement(objectKey: object.objectKey, tier: .online,
            providerID: $0, locator: object.objectKey, byteCount: object.byteCount, sha256: object.sha256) }
        let candidates = placements.map { DicomDestructivePlan.Action(kind: .delete, objectKey: object.objectKey,
            providerID: $0.providerID, locator: object.objectKey, byteCount: object.byteCount, reason: "test") }
        let result = DicomDestructivePlanner().plan(candidates: candidates, placements: [object.objectKey: placements],
            verifiedCopies: [object.objectKey: 2], protections: [:], graph: .init(parents: [:]), now: Date())
        XCTAssertEqual(result.executable.count, 1)
        XCTAssertEqual(result.blocked.count, 1)
    }
}

private struct FailingDestructiveProvider: DicomStorageProvider {
    enum Operation { case head, get, put, delete }
    let base: DicomLocalDiskProvider
    let failure: Operation?
    var id: String { base.id }
    var tier: DicomStorageTier { base.tier }
    var capabilities: DicomStorageCapabilities { base.capabilities }
    func head(_ locator: String) async throws -> DicomStorageObjectInfo? {
        if failure == .head { throw DicomStorageProviderError.io("Injected head failure") }
        return try await base.head(locator)
    }
    func list(prefix: String) async throws -> [DicomStorageObjectInfo] { try await base.list(prefix: prefix) }
    func reachability() async -> DicomProviderReachability { await base.reachability() }
    func delete(_ locator: String, authorization: DicomDeleteAuthorization) async throws {
        if failure == .delete { throw DicomStorageProviderError.io("Injected delete failure") }
        try await base.delete(locator, authorization: authorization)
    }
    func put(_ source: URL, locator: String, expectedSHA256: String,
             isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo {
        if failure == .put { throw DicomStorageProviderError.io("Injected put failure") }
        return try await base.put(source, locator: locator, expectedSHA256: expectedSHA256, isCancelled: isCancelled)
    }
    func get(_ locator: String, to destination: URL, expectedSHA256: String,
             isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo {
        if failure == .get { throw DicomStorageProviderError.io("Injected get failure") }
        return try await base.get(locator, to: destination, expectedSHA256: expectedSHA256, isCancelled: isCancelled)
    }
}

private struct CorruptingBackupProvider: DicomStorageProvider {
    let base: DicomLocalDiskProvider
    var id: String { base.id }
    var tier: DicomStorageTier { base.tier }
    var capabilities: DicomStorageCapabilities { base.capabilities }
    func head(_ locator: String) async throws -> DicomStorageObjectInfo? { try await base.head(locator) }
    func list(prefix: String) async throws -> [DicomStorageObjectInfo] { try await base.list(prefix: prefix) }
    func reachability() async -> DicomProviderReachability { await base.reachability() }
    func delete(_ locator: String, authorization: DicomDeleteAuthorization) async throws {
        try await base.delete(locator, authorization: authorization)
    }
    func put(_ source: URL, locator: String, expectedSHA256: String,
             isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo {
        let result = try await base.put(source, locator: locator, expectedSHA256: expectedSHA256, isCancelled: isCancelled)
        try Data("corrupted after publication".utf8).write(to: base.root.appendingPathComponent(locator))
        return result
    }
    func get(_ locator: String, to destination: URL, expectedSHA256: String,
             isCancelled: @Sendable () -> Bool) async throws -> DicomStorageObjectInfo {
        try await base.get(locator, to: destination, expectedSHA256: expectedSHA256, isCancelled: isCancelled)
    }
}
