import Foundation
import XCTest
@testable import DicomCore

func deliveryItem(_ id: String = UUID().uuidString, destination: String = "peer",
                  priority: DicomDeliveryPriority = .routine, now: Date = Date(timeIntervalSince1970: 1000))
    -> DicomDeliveryItem {
    DicomDeliveryItem(deliveryID: id, eventID: id, destinationID: destination, destinationKind: .webhook,
        idempotencyKey: id, priority: priority, payload: .objects([]), now: now)
}

final class DicomDeliveryOutboxTests: XCTestCase {
    func test_leaseVisibilityExpiryAndFencing() async throws {
        let store = DicomInMemoryDeliveryOutbox()
        let now = Date(timeIntervalSince1970: 1000)
        try await store.enqueue([deliveryItem("a")])
        let first = try await store.lease(max: 2, owner: "old", now: now, leaseSeconds: 10, statShare: 70)
        XCTAssertEqual(first.count, 1)
        let hidden = try await store.lease(max: 2, owner: "new", now: now, leaseSeconds: 10, statShare: 70)
        XCTAssertTrue(hidden.isEmpty)
        try await store.releaseExpiredLeases(now: now.addingTimeInterval(10))
        let second = try await store.lease(max: 2, owner: "new", now: now.addingTimeInterval(10),
                                           leaseSeconds: 10, statShare: 70)
        XCTAssertEqual(second.first?.idempotencyKey, "a")
        XCTAssertEqual(second.first?.attempts, 2)
        try await store.settle(deliveryID: "a", leaseOwner: "old", settlement: .complete(.init(), retry: nil))
        let leased = try await store.fetch(states: [.leased])
        XCTAssertEqual(leased.count, 1)
    }

    func test_duplicateKeyAndBatchAtomicity() async throws {
        let store = DicomInMemoryDeliveryOutbox()
        try await store.enqueue([deliveryItem("a")])
        var duplicate = deliveryItem("b")
        duplicate.idempotencyKey = "a"
        do { try await store.enqueue([deliveryItem("c"), duplicate]); XCTFail("Duplicate accepted") }
        catch { XCTAssertEqual(error as? DicomDeliveryOutboxError, .duplicateIdempotencyKey) }
        let rows = try await store.fetch(states: [.pending])
        XCTAssertEqual(rows.count, 1)
        duplicate.destinationID = "other"
        try await store.enqueue([duplicate])
    }

    func test_statShareAndOldRoutineFirst() async throws {
        let store = DicomInMemoryDeliveryOutbox()
        let now = Date(timeIntervalSince1970: 1000)
        try await store.enqueue((0..<20).map { deliveryItem("s\($0)", priority: .stat) } +
            (0..<20).map { deliveryItem("r\($0)") })
        let rows = try await store.lease(max: 10, owner: "test", now: now.addingTimeInterval(1),
                                         leaseSeconds: 10, statShare: 70)
        XCTAssertEqual(rows.first?.priority, .stat)
        XCTAssertEqual(rows.filter { $0.priority == .stat }.count, 7)
        let aged = DicomInMemoryDeliveryOutbox()
        try await aged.enqueue((0..<20).map { deliveryItem("s\($0)", priority: .stat) } +
            [deliveryItem("old", now: now.addingTimeInterval(-1000))])
        let first = try await aged.lease(max: 1, owner: "test", now: now.addingTimeInterval(1),
                                         leaseSeconds: 10, statShare: 100)
        XCTAssertEqual(first.first?.deliveryID, "old")
    }

    func test_transitionsAndIdempotentCompletion() async throws {
        let store = DicomInMemoryDeliveryOutbox()
        let item = deliveryItem("a")
        try await store.enqueue([item])
        try await store.fail(deliveryID: "a", errorClass: .permanent, message: "refused", retryAt: nil)
        try await store.requeueDeadLetter(deliveryID: "a", now: item.createdAt)
        try await store.markUncertain(deliveryID: "a", message: "lost response")
        try await store.complete(deliveryID: "a", receipt: .init(status: "first"))
        try await store.complete(deliveryID: "a", receipt: .init(status: "second"))
        let rows = try await store.fetch(states: [.delivered])
        XCTAssertEqual(rows.first?.receipt?.status, "first")
        let delivered = try await store.isDelivered(destinationID: "peer", idempotencyKey: "a")
        XCTAssertTrue(delivered)
        try await store.enqueue([deliveryItem("b")])
        try await store.cancel(deliveryID: "b")
        try await store.complete(deliveryID: "b", receipt: .init())
        let cancelled = try await store.fetch(states: [.cancelled])
        XCTAssertEqual(cancelled.count, 1)
    }

    func test_jsonlRestartRestoresLeaseReceiptAndDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DicomJSONLDeliveryOutbox(directory: directory)
        let now = Date(timeIntervalSince1970: 1000)
        try await store.enqueue([deliveryItem("a"), deliveryItem("b")])
        try await store.fail(deliveryID: "a", errorClass: .transient, message: "busy",
                             retryAt: now.addingTimeInterval(500))
        _ = try await store.lease(max: 1, owner: "old", now: now, leaseSeconds: 10, statShare: 70)
        let reopened = try DicomJSONLDeliveryOutbox(directory: directory)
        let waiting = try await reopened.fetch(states: [.retryWait])
        XCTAssertEqual(waiting.first?.nextAttemptAt, now.addingTimeInterval(500))
        try await reopened.releaseExpiredLeases(now: now.addingTimeInterval(11))
        let leased = try await reopened.lease(max: 1, owner: "new", now: now.addingTimeInterval(11),
                                               leaseSeconds: 10, statShare: 70)
        XCTAssertEqual(leased.first?.deliveryID, "b")
        try await reopened.complete(deliveryID: "b", receipt: .init(status: "stored"))
        let finalStore = try DicomJSONLDeliveryOutbox(directory: directory)
        let done = try await finalStore.fetch(states: [.delivered])
        XCTAssertEqual(done.first?.receipt?.status, "stored")
    }
}

extension DicomDeliveryOutboxTests {
    func test_jsonlTornAppendRecoversPreviousStateAndCanAppendAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DicomJSONLDeliveryOutbox(directory: directory)
        try await first.enqueue([deliveryItem("a")])
        let fault = DicomFaultInjectingFileSystem(operation: .write, fault: .partialWrite(12))
        let failing = try DicomJSONLDeliveryOutbox(directory: directory, fileSystem: fault)
        do { try await failing.complete(deliveryID: "a", receipt: .init()); XCTFail("Expected interrupted append") }
        catch {}
        let recovered = try DicomJSONLDeliveryOutbox(directory: directory)
        let rows = try await recovered.fetch(states: [.pending])
        XCTAssertEqual(rows.count, 1)
        try await recovered.complete(deliveryID: "a", receipt: .init())
        let reopened = try DicomJSONLDeliveryOutbox(directory: directory)
        let delivered = try await reopened.isDelivered(destinationID: "peer", idempotencyKey: "a")
        XCTAssertTrue(delivered)
    }
}

extension DicomDeliveryOutboxTests {
    func test_jsonlIndependentHandlesEnforceUniqueKeyAndRefreshState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DicomJSONLDeliveryOutbox(directory: directory)
        let second = try DicomJSONLDeliveryOutbox(directory: directory)
        try await first.enqueue([deliveryItem("a")])
        var duplicate = deliveryItem("b")
        duplicate.idempotencyKey = "a"
        do { try await second.enqueue([duplicate]); XCTFail("Duplicate from another handle accepted") }
        catch { XCTAssertEqual(error as? DicomDeliveryOutboxError, .duplicateIdempotencyKey) }
        try await second.complete(deliveryID: "a", receipt: .init())
        let visible = try await first.isDelivered(destinationID: "peer", idempotencyKey: "a")
        XCTAssertTrue(visible)
    }
}

extension DicomDeliveryOutboxTests {
    func test_jsonlCompactionRetainsLatestStateAndDedupAcrossOwners() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try DicomJSONLDeliveryOutbox(directory: root)
        try await first.enqueue([deliveryItem("compact")])
        try await first.complete(deliveryID: "compact", receipt: .init(status: "accepted"))
        let journal = root.appendingPathComponent("delivery.jsonl")
        let original = try Data(contentsOf: journal)
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        for _ in 0..<(2 * 1024 * 1024 / original.count + 1) { try handle.write(contentsOf: original) }
        try handle.close()
        let second = try DicomJSONLDeliveryOutbox(directory: root)
        let counts = try await second.counts()
        XCTAssertEqual(counts[.delivered], 1)
        XCTAssertLessThan(try Data(contentsOf: journal).count, original.count * 2)
        let delivered = try await first.isDelivered(destinationID: "peer", idempotencyKey: "compact")
        XCTAssertTrue(delivered)
    }
}
