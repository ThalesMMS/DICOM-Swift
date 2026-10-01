import XCTest
@testable import DicomCore

actor LifecycleTestEmitter: DicomLifecycleEventEmitting {
    private(set) var events: [DicomLifecycleEvent] = []
    private(set) var journalSnapshots: [[DicomIngestJournalEntry]] = []
    let journal: (any DicomIngestJournaling)?
    init(journal: (any DicomIngestJournaling)? = nil) { self.journal = journal }
    func emit(_ event: DicomLifecycleEvent) async {
        events.append(event)
        if let journal { journalSnapshots.append((try? await journal.entries()) ?? []) }
    }
}

private actor LifecycleFailingRegistrar: DicomIngestRegistrar {
    nonisolated let gate = DicomIngestGate()
    nonisolated let durability = DicomDurabilityLevel.publishedAndRegistered
    func classify(sopInstanceUID: String, contentSHA256: String) -> DicomIngestClassification { .new }
    func records() -> [DicomIngestRecord] { [] }
    func register(_ record: DicomIngestRecord) throws -> DicomIngestClassification {
        throw DicomIngestError.permissionDenied(path: "/private/synthetic-patient")
    }
}

@MainActor
final class DicomLifecycleIngestHooksTests: XCTestCase {
    func test_receivedAndAvailable_followStageDoneJournalRecords() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let emitter = LifecycleTestEmitter(journal: fixture.journal)
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal,
            registrar: fixture.registrar, lifecycle: emitter)
        let result = try await coordinator.ingest(part10Data: ingestBytes())
        let events = await emitter.events
        let snapshots = await emitter.journalSnapshots
        XCTAssertEqual(events.map(\.kind), [.received, .available])
        // Each event follows the durable `done` record of its stage. Publication completion and
        // registration intent commit together, so the received snapshot may already end at the
        // registration intent; what matters is that the stage-done record is already journaled.
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots[0].contains { $0.stage == .published && $0.phase == .done })
        XCTAssertFalse(snapshots[0].contains { $0.stage == .registered && $0.phase == .done })
        XCTAssertEqual(snapshots[1].last?.stage, .registered)
        XCTAssertEqual(snapshots[1].last?.phase, .done)
        XCTAssertEqual(events.map(\.sourceRef), Array(repeating: result.record.ingestID.uuidString, count: 2))
        XCTAssertEqual(events.first?.subject.studyInstanceUID, "2.25.2356002")
        XCTAssertEqual(events.first?.durability, .fileSynced)
        XCTAssertEqual(events.last?.durability, .publishedAndRegistered)
    }

    func test_recoveryBeforePublicationRetainsStudyAndSeriesRoutingMetadata() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let interrupted = DicomIngestCoordinator(root: fixture.root,
            fileSystem: DicomFaultInjectingFileSystem(operation: .rename, fault: .crashBefore),
            journal: fixture.journal, registrar: fixture.registrar)
        do { _ = try await interrupted.ingest(part10Data: ingestBytes()); XCTFail("Expected interruption") }
        catch is DicomIngestCrash {}
        let entries = try await fixture.journal.entries()
        var entry = try XCTUnwrap(entries.last)
        XCTAssertEqual(entry.stage, .published)
        XCTAssertFalse(try DicomLocalIngestFileSystem().exists(XCTUnwrap(entry.finalPath)))
        let emitter = LifecycleTestEmitter()
        let resumed = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal,
            registrar: fixture.registrar, lifecycle: emitter)
        _ = try await resumed.finish(&entry)
        let events = await emitter.events
        XCTAssertEqual(events.map(\.kind), [.received, .available])
        XCTAssertTrue(events.allSatisfy { $0.subject.studyInstanceUID == "2.25.2356002" &&
            $0.subject.seriesInstanceUID == "2.25.2356003" })
    }

    func test_failureAfterPublished_emitsClassifiedErrorWithoutPHI() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let emitter = LifecycleTestEmitter(journal: fixture.journal)
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal,
            registrar: LifecycleFailingRegistrar(), lifecycle: emitter)
        do { _ = try await coordinator.ingest(part10Data: ingestBytes()); XCTFail("Expected failure") }
        catch {}
        let events = await emitter.events
        XCTAssertEqual(events.map(\.kind), [.received, .error])
        XCTAssertEqual(events.last?.error?.class, "permissionDenied")
        XCTAssertFalse(events.last?.error?.message.contains("synthetic-patient") ?? true)
        XCTAssertEqual(events.first?.sourceRef, events.last?.sourceRef)
    }

    func test_socketReceiptAndReceivedJournalStage_emitNothing() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let emitter = LifecycleTestEmitter(journal: fixture.journal)
        let coordinator = DicomIngestCoordinator(root: fixture.root, journal: fixture.journal,
            registrar: fixture.registrar, lifecycle: emitter)
        var entry = DicomIngestJournalEntry(root: fixture.root)
        try await coordinator.mark(&entry, .received, .done)
        do { _ = try await coordinator.ingest(part10Data: Data()); XCTFail("Expected validation failure") }
        catch {}
        let events = await emitter.events
        XCTAssertTrue(events.isEmpty)
    }
}
