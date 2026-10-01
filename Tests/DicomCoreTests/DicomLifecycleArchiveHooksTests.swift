import XCTest
@testable import DicomCore

@MainActor
final class DicomLifecycleArchiveHooksTests: XCTestCase {
    func test_verifiedRecall_emitsAvailableWithTransferAndObjectReference() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let emitter = LifecycleTestEmitter()
        let coordinator = DicomRecallCoordinator(providers: [
            "source": DicomLocalDiskProvider(id: "source", root: fixture.source),
            "destination": DicomLocalDiskProvider(id: "destination", root: fixture.destination)
        ], journal: fixture.journal, lifecycle: emitter)
        let item = try fixture.item()
        let result = try await coordinator.recall(items: [item], from: "source", to: "destination")
        let events = await emitter.events
        XCTAssertEqual(result.items.first?.state, .verified)
        XCTAssertEqual(events.map(\.kind), [.available])
        XCTAssertEqual(events.first?.sourceKind, "recall")
        XCTAssertEqual(events.first?.sourceRef, result.transferID + ":" + item.objectKey)
    }

    func test_failedRecall_emitsNoAvailable() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let emitter = LifecycleTestEmitter()
        let item = try fixture.item()
        try Data("corrupt".utf8).write(to: fixture.source.appendingPathComponent(item.objectKey))
        let coordinator = DicomRecallCoordinator(providers: [
            "source": DicomLocalDiskProvider(id: "source", root: fixture.source),
            "destination": DicomLocalDiskProvider(id: "destination", root: fixture.destination)
        ], journal: fixture.journal, lifecycle: emitter)
        let result = try await coordinator.recall(items: [item], from: "source", to: "destination")
        let events = await emitter.events
        XCTAssertNotEqual(result.items.first?.state, .verified)
        XCTAssertTrue(events.isEmpty)
    }

    func test_backupCopied_emitsNothingAndVerifiedEmitsArchivedOnce() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let emitter = LifecycleTestEmitter()
        var evidence = DicomBackupEvidence(inventoryID: fixture.inventory.inventoryID, destinationProviderID: "destination")
        try evidence.recordCopied(report: await fixture.copy())
        let afterCopy = await emitter.events
        XCTAssertEqual(evidence.status, .copied)
        XCTAssertTrue(afterCopy.isEmpty)
        let report = try await fixture.verify()
        try await evidence.recordVerified(report: report, lifecycle: emitter)
        try await evidence.recordVerified(report: report, lifecycle: emitter)
        let events = await emitter.events
        XCTAssertEqual(evidence.status, .verified)
        XCTAssertEqual(events.map(\.kind), [.archived])
        XCTAssertEqual(events.first?.sourceRef, fixture.inventory.inventoryID)
        XCTAssertEqual(events.first?.sourceKind, "backup")
    }

    func test_failedBackupVerification_emitsNothing() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let emitter = LifecycleTestEmitter()
        var evidence = DicomBackupEvidence(inventoryID: fixture.inventory.inventoryID, destinationProviderID: "destination")
        try evidence.recordCopied(report: await fixture.copy())
        try fixture.fs.remove(fixture.destination.root.appendingPathComponent("object0.dcm"))
        let report = try await fixture.verify()
        do { try await evidence.recordVerified(report: report, lifecycle: emitter); XCTFail("Expected failed verification") }
        catch {}
        let events = await emitter.events
        XCTAssertTrue(events.isEmpty)
    }
}
