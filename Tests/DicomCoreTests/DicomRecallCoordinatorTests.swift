import Foundation
import XCTest
@testable import DicomCore

actor GatedObjectStore: DicomObjectStore {
    let base: any DicomObjectStore
    var blocked: Set<String>
    var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var keys: [String] = []
    private(set) var active = 0
    private(set) var peak = 0
    init(root: URL, blocked: Set<String> = []) {
        base = DicomDirectoryObjectStore(root: root)
        self.blocked = blocked
    }
    func release(_ key: String) { blocked.remove(key); gates.removeValue(forKey: key)?.resume() }
    func getObject(key: String, to destination: URL) async throws -> DicomStorageObjectInfo {
        keys.append(key)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if blocked.contains(key) { await withCheckedContinuation { gates[key] = $0 } }
        try Task.checkCancellation()
        return try await base.getObject(key: key, to: destination)
    }
    func putObject(key: String, from source: URL, sha256: String) async throws -> DicomStorageObjectInfo {
        try await base.putObject(key: key, from: source, sha256: sha256)
    }
    func headObject(key: String) async throws -> DicomStorageObjectInfo? { try await base.headObject(key: key) }
    func listObjects(prefix: String) async throws -> [DicomStorageObjectInfo] { try await base.listObjects(prefix: prefix) }
    func deleteObject(key: String) async throws { try await base.deleteObject(key: key) }
}

@MainActor
func eventually(_ condition: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try await !condition() {
        guard ContinuousClock.now < deadline else { XCTFail("Gate timed out", file: file, line: line); throw DicomStorageProviderError.io("Test timeout") }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
final class DicomRecallCoordinatorTests: XCTestCase {
    func test_coalescedWaiterCancellationLeavesOtherResultIntact() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let store = GatedObjectStore(root: fixture.source, blocked: [item.objectKey])
        let coordinator = fixture.coordinator(store: store)
        let first = Task { try await coordinator.recall(items: [item], from: "source", to: "destination") }
        try await eventually { await store.keys.count == 1 }
        let second = Task { try await coordinator.recall(items: [item], from: "source", to: "destination") }
        try await eventually {
            let manifests = try fixture.journal.pending()
            return manifests.count == 2 && manifests.allSatisfy { $0.items[0].state == .inFlight }
        }
        let journals = try fixture.journal.pending()
        XCTAssertTrue(journals.allSatisfy { $0.items[0].state == .inFlight })
        first.cancel()
        await storageError(.cancelled) { _ = try await first.value }
        await store.release(item.objectKey)
        let result = try await second.value
        XCTAssertEqual(result.items[0].state, .verified)
        let keys = await store.keys
        XCTAssertEqual(keys, [item.objectKey])
        let placement = try await coordinator.placement(after: result.items[0])
        XCTAssertEqual(placement.tier, .online)
        XCTAssertEqual(placement.state, .available)
        XCTAssertEqual(placement.providerID, "destination")
        XCTAssertEqual(try fixture.fileSystem.checksum(fixture.source.appendingPathComponent(item.sourceLocator)), item.sha256)
        await storageError(.integrity("Item has no verified placement in this coordinator")) {
            _ = try await coordinator.placement(after: item)
        }
    }

    func test_concurrencyByteQuotaAndInteractivePriority() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let a = try fixture.item("a")
        let b = try fixture.item("b")
        let c = try fixture.item("c")
        let store = GatedObjectStore(root: fixture.source, blocked: ["a", "b", "c"])
        let coordinator = fixture.coordinator(store: store,
            quotas: .init(maxConcurrentTransfers: 2, maxInFlightBytes: a.byteCount, maxQueuedItems: 10))
        let first = Task { try await coordinator.recall(items: [a], from: "source", to: "destination") }
        try await eventually { await store.keys == ["a"] }
        let prefetch = Task { try await coordinator.recall(items: [b], from: "source", to: "destination", priority: .prefetch) }
        try await eventually { try fixture.journal.pending().count == 2 }
        let interactive = Task { try await coordinator.recall(items: [c], from: "source", to: "destination") }
        try await eventually { try fixture.journal.pending().count == 3 }
        let before = await store.keys
        XCTAssertEqual(before, ["a"])
        await store.release("a")
        _ = try await first.value
        try await eventually { await store.keys.count == 2 }
        let order = await store.keys
        XCTAssertEqual(order, ["a", "c"])
        await store.release("c")
        _ = try await interactive.value
        try await eventually { await store.keys.count == 3 }
        await store.release("b")
        _ = try await prefetch.value
        let peak = await store.peak
        XCTAssertEqual(peak, 1)
    }

    func test_concurrencyLimitAllowsTwoButNotThree() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let items = try ["a", "b", "c"].map { try fixture.item($0) }
        let store = GatedObjectStore(root: fixture.source, blocked: ["a", "b", "c"])
        let coordinator = fixture.coordinator(store: store, quotas: .init(maxConcurrentTransfers: 2))
        let task = Task { try await coordinator.recall(items: items, from: "source", to: "destination") }
        try await eventually { await store.keys.count == 2 }
        let firstKeys = await store.keys
        XCTAssertEqual(Set(firstKeys), ["a", "b"])
        let manifests = try fixture.journal.pending()
        XCTAssertEqual(manifests[0].items.map(\.state), [.inFlight, .inFlight, .pending])
        await store.release("a")
        try await eventually { await store.keys.count == 3 }
        await store.release("b")
        await store.release("c")
        let result = try await task.value
        XCTAssertEqual(result.totals.verifiedItems, 3)
        let peak = await store.peak
        XCTAssertEqual(peak, 2)
    }

    func test_interruptionResumeSkipsVerifiedAndRemovesPartial() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let items = try ["a", "b"].map { try fixture.item($0) }
        let store = GatedObjectStore(root: fixture.source, blocked: ["b"])
        let first = fixture.coordinator(store: store, quotas: .init(maxConcurrentTransfers: 1))
        let task = Task { try await first.recall(items: items, from: "source", to: "destination") }
        try await eventually { await store.keys == ["a", "b"] }
        let saved = try XCTUnwrap(fixture.journal.pending().first)
        XCTAssertEqual(saved.items.map(\.state), [.verified, .inFlight])
        task.cancel()
        await storageError(.cancelled) { _ = try await task.value }
        await store.release("b")
        try await eventually { await store.active == 0 }
        let stage = fixture.journalURL.appendingPathComponent("staging/orphan")
        try fixture.fileSystem.createDirectory(stage)
        try fixture.fileSystem.write(Data("partial".utf8), to: stage.appendingPathComponent("object.partial"), append: false)
        let destinationPartial = fixture.destination.appendingPathComponent("b.partial")
        try fixture.fileSystem.write(Data("interrupted publication".utf8), to: destinationPartial, append: false)
        let second = fixture.coordinator(store: store)
        let results = try await second.resume()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].transferID, saved.transferID)
        XCTAssertEqual(results[0].items.map(\.state), [.verified, .verified])
        let keys = await store.keys
        XCTAssertEqual(keys.filter { $0 == "a" }.count, 1)
        XCTAssertEqual(keys.filter { $0 == "b" }.count, 2)
        XCTAssertFalse(try fixture.fileSystem.exists(stage))
        XCTAssertFalse(try fixture.fileSystem.exists(destinationPartial))
        let restoredPlacement = try await second.placement(after: results[0].items[0])
        XCTAssertEqual(restoredPlacement.state, .available)
        XCTAssertTrue(try fixture.journal.pending().isEmpty)
    }

    func test_corruptionFailsWithSourceUntouched() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let base = DicomDirectoryObjectStore(root: fixture.source)
        let before = try await base.listObjects(prefix: "")
        let coordinator = fixture.coordinator(store: CorruptingObjectStore(base: base))
        let result = try await coordinator.recall(items: [item], from: "source", to: "destination")
        guard case .failed = result.items[0].state else { return XCTFail("Corruption accepted") }
        let after = try await base.listObjects(prefix: "")
        XCTAssertEqual(before, after)
        XCTAssertTrue(try fixture.fileSystem.contentsOf(fixture.destination).isEmpty)
        XCTAssertEqual(try fixture.journal.load(transferID: result.transferID), result)
    }

    func test_quotaRefusalAndUnknownProviderDoNotStartIO() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let store = GatedObjectStore(root: fixture.source)
        for quotas in [DicomRecallCoordinator.Quotas(maxInFlightBytes: 1), .init(maxQueuedItems: 0)] {
            let coordinator = fixture.coordinator(store: store, quotas: quotas)
            do { _ = try await coordinator.recall(items: [item], from: "source", to: "destination"); XCTFail("Quota ignored") }
            catch { guard case .quotaExceeded = error as? DicomPlacementError else { return XCTFail("Wrong error") } }
        }
        let coordinator = fixture.coordinator(store: store)
        do { _ = try await coordinator.recall(items: [item], from: "unknown", to: "destination"); XCTFail("Provider ignored") }
        catch { XCTAssertEqual(error as? DicomPlacementError, .unknownProvider("unknown")) }
        let keys = await store.keys
        XCTAssertTrue(keys.isEmpty)
    }
}

extension DicomRecallCoordinatorTests {
    func test_cancelledFlightRetainsKeyUntilIOFinishes() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        let store = GatedObjectStore(root: fixture.source, blocked: [item.objectKey])
        let coordinator = fixture.coordinator(store: store)
        let task = Task { try await coordinator.recall(items: [item], from: "source", to: "destination") }
        try await eventually { await store.keys.count == 1 }
        task.cancel()
        await storageError(.cancelled) { _ = try await task.value }
        var conflicting = item
        conflicting.sourceLocator = "missing"
        await storageError(.integrity("Conflicting in-flight object key")) {
            _ = try await coordinator.recall(items: [conflicting], from: "source", to: "destination")
        }
        await store.release(item.objectKey)
        try await eventually { await store.active == 0 }
    }

    func test_resumeStartsIndependentManifestsConcurrently() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let items = try ["a", "b"].map { try fixture.item($0) }
        for item in items {
            try fixture.journal.save(.init(sourceProviderID: "source", destinationProviderID: "destination", items: [item]))
        }
        let store = GatedObjectStore(root: fixture.source, blocked: ["a", "b"])
        let coordinator = fixture.coordinator(store: store)
        let task = Task { try await coordinator.resume() }
        do { try await eventually { await store.keys.count == 2 } }
        catch {
            await store.release("a"); await store.release("b")
            _ = await task.result
            throw error
        }
        await store.release("a"); await store.release("b")
        let results = try await task.value
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.items[0].state == .verified })
    }

    func test_resumeInvalidManifestDoesNotAbandonLaterManifest() async throws {
        let fixture = try PlacementFixture()
        defer { fixture.clean() }
        let item = try fixture.item()
        try fixture.journal.save(.init(createdAt: .distantPast, sourceProviderID: "missing",
            destinationProviderID: "destination", items: [item]))
        try fixture.journal.save(.init(sourceProviderID: "source", destinationProviderID: "destination", items: [item]))
        let coordinator = fixture.coordinator(store: DicomDirectoryObjectStore(root: fixture.source))
        do { _ = try await coordinator.resume(); XCTFail("Expected invalid provider") }
        catch { XCTAssertEqual(error as? DicomPlacementError, .unknownProvider("missing")) }
        XCTAssertTrue(try fixture.fileSystem.exists(fixture.destination.appendingPathComponent(item.objectKey)))
    }
}
