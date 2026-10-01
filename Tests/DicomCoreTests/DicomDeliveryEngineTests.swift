import Foundation
import XCTest
@testable import DicomCore

final class DeliveryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

actor DeliveryFake: DicomDeliveryDestination {
    nonisolated let id: String
    nonisolated let kind = DicomDeliveryDestinationKind.webhook
    var results: [DicomDeliveryAttemptResult]
    var keys: [String] = []
    var effects: Set<String> = []
    init(id: String = "peer", results: [DicomDeliveryAttemptResult] = []) { self.id = id; self.results = results }
    func deliver(_ item: DicomDeliveryItem, isCancelled: @Sendable () -> Bool) async -> DicomDeliveryAttemptResult {
        keys.append(item.idempotencyKey)
        effects.insert(item.idempotencyKey)
        return results.isEmpty ? .delivered(.init()) : results.removeFirst()
    }
}

final class DicomDeliveryEngineTests: XCTestCase {
    func test_unknownDestination_isRejectedWithoutChangingSharedOutbox() async throws {
        let store = DicomInMemoryDeliveryOutbox()
        let other = deliveryItem("other", destination: "other")
        try await store.enqueue([other])
        let sleeps = DeliverySleepRecorder()
        let engine = DicomDeliveryEngine(outbox: store, destinations: ["peer": DeliveryFake()], owner: "test",
            sleep: { delay in await sleeps.record(delay); throw CancellationError() })
        do {
            try await engine.enqueue([deliveryItem("unknown", destination: "missing")])
            XCTFail("Accepted an unconfigured destination")
        } catch DicomDeliveryOutboxError.invalidItem {}
        let pending = try await store.fetch(states: [.pending])
        XCTAssertEqual(pending.map(\.deliveryID), [other.deliveryID])
        await engine.run(until: { false })
        let delays = await sleeps.delays
        XCTAssertEqual(delays, [1])
    }

    func test_acknowledgedBeforeCrash_retriesSameKeyWithoutSecondRemoteEffect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let seed = try DicomJSONLDeliveryOutbox(directory: directory)
        try await seed.enqueue([deliveryItem("a")])
        let peer = DeliveryFake()
        let clock = DeliveryTestClock()
        // The first append leases; the second crashes after acknowledgement, before recording completion.
        let fault = DicomFaultInjectingFileSystem(operation: .write, nth: 2, fault: .crashBefore)
        let crashingStore = try DicomJSONLDeliveryOutbox(directory: directory, fileSystem: fault)
        var crashed: DicomDeliveryEngine? = DicomDeliveryEngine(outbox: crashingStore,
            destinations: ["peer": peer], limits: .init(leaseSeconds: 10), owner: "old", clock: clock.now)
        let interrupted = await crashed!.runOnce(now: clock.now())
        XCTAssertEqual(interrupted.errors.count, 1)
        crashed = nil
        clock.advance(11)
        let store = try DicomJSONLDeliveryOutbox(directory: directory)
        let restarted = DicomDeliveryEngine(outbox: store, destinations: ["peer": peer], owner: "new", clock: clock.now)
        try await restarted.resume(now: clock.now())
        let report = await restarted.runOnce(now: clock.now())
        XCTAssertEqual(report.delivered, 1)
        let keys = await peer.keys
        let effects = await peer.effects
        XCTAssertEqual(keys, ["a", "a"])
        XCTAssertEqual(effects.count, 1)
        let delivered = try await store.isDelivered(destinationID: "peer", idempotencyKey: "a")
        XCTAssertTrue(delivered)
    }

    func test_uncertainBackoffThenDelivered() async throws {
        let clock = DeliveryTestClock()
        let store = DicomInMemoryDeliveryOutbox()
        let peer = DeliveryFake(results: [.uncertain("body sent")])
        let engine = DicomDeliveryEngine(outbox: store, destinations: ["peer": peer],
            retryPolicy: .init(random: { 1 }), owner: "engine", clock: clock.now)
        try await engine.enqueue([deliveryItem("a")])
        _ = await engine.runOnce(now: clock.now())
        let uncertain = try await store.fetch(states: [.uncertain])
        XCTAssertEqual(uncertain.first?.nextAttemptAt, clock.now().addingTimeInterval(2))
        let early = await engine.runOnce(now: clock.now())
        XCTAssertEqual(early.attempted, 0)
        clock.advance(2)
        let result = await engine.runOnce(now: clock.now())
        XCTAssertEqual(result.delivered, 1)
        let keys = await peer.keys
        XCTAssertEqual(keys, ["a", "a"])
    }

    func test_permanentRequeueAndTransientBudget() async throws {
        let clock = DeliveryTestClock()
        let store = DicomInMemoryDeliveryOutbox()
        let peer = DeliveryFake(results: [.failed(.rejectedByDestination, "refused", retryAfter: nil)] +
            Array(repeating: .failed(.transient, "busy", retryAfter: nil), count: 3))
        let engine = DicomDeliveryEngine(outbox: store, destinations: ["peer": peer],
            retryPolicy: .init(maxAttempts: [.transient: 3], random: { 1 }), owner: "engine", clock: clock.now)
        try await engine.enqueue([deliveryItem("a")])
        _ = await engine.runOnce(now: clock.now())
        let rejected = try await store.fetch(states: [.deadLetter])
        XCTAssertEqual(rejected.count, 1)
        try await store.requeueDeadLetter(deliveryID: "a", now: clock.now())
        for delay in [2.0, 4.0] {
            _ = await engine.runOnce(now: clock.now())
            let waiting = try await store.fetch(states: [.retryWait])
            XCTAssertEqual(waiting.first?.nextAttemptAt, clock.now().addingTimeInterval(delay))
            clock.advance(delay)
        }
        _ = await engine.runOnce(now: clock.now())
        let dead = try await store.fetch(states: [.deadLetter])
        XCTAssertEqual(dead.first?.attempts, 3)
    }

    func test_cancelRetryWaitPreventsFurtherAttempt() async throws {
        let store = DicomInMemoryDeliveryOutbox()
        let clock = DeliveryTestClock()
        let peer = DeliveryFake(results: [.failed(.transient, "busy", retryAfter: nil)])
        let engine = DicomDeliveryEngine(outbox: store, destinations: ["peer": peer], owner: "engine", clock: clock.now)
        try await engine.enqueue([deliveryItem("a")])
        _ = await engine.runOnce(now: clock.now())
        try await engine.cancel(deliveryID: "a")
        clock.advance(1000)
        let next = await engine.runOnce(now: clock.now())
        XCTAssertEqual(next.attempted, 0)
        let cancelled = try await store.fetch(states: [.cancelled])
        XCTAssertEqual(cancelled.count, 1)
    }

    func test_backpressureDoesNotLease() async throws {
        struct Pressure: DicomDeliveryBackpressure {
            func admission() async -> DicomDeliveryAdmission { .pause(retryAfter: 10) }
        }
        let store = DicomInMemoryDeliveryOutbox()
        let engine = DicomDeliveryEngine(outbox: store, destinations: ["peer": DeliveryFake()],
                                         backpressure: Pressure(), owner: "engine")
        try await engine.enqueue([deliveryItem("a")])
        let report = await engine.runOnce(now: Date())
        XCTAssertTrue(report.paused)
        let pending = try await store.fetch(states: [.pending])
        XCTAssertEqual(pending.first?.attempts, 0)
    }

    func test_bandwidthLargeObjectConsumesMultipleRefills() async throws {
        let clock = DeliveryTestClock()
        let limiter = DicomBandwidthLimiter(bytesPerSecond: 100, clock: clock.now, sleep: { clock.advance($0) })
        try await limiter.acquire(bytes: 350)
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 1002.5))
    }

    func test_destinationQuotaKeepsOtherPeerVisible() async throws {
        let store = DicomInMemoryDeliveryOutbox()
        let first = DeliveryFake()
        let second = DeliveryFake(id: "other")
        let engine = DicomDeliveryEngine(outbox: store, destinations: ["peer": first, "other": second], owner: "engine")
        try await engine.enqueue([deliveryItem("a"), deliveryItem("b"), deliveryItem("c", destination: "other")])
        let report = await engine.runOnce(now: Date())
        XCTAssertEqual(report.attempted, 2)
        let firstKeys = await first.keys
        let secondKeys = await second.keys
        XCTAssertEqual(firstKeys.count, 1)
        XCTAssertEqual(secondKeys.count, 1)
    }
}

private actor DeliverySleepRecorder {
    var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { delays.append(delay) }
}

actor DeliveryGate {
    var active = 0
    var maximum = 0
    var perDestination: [String: Int] = [:]
    var peakByDestination: [String: Int] = [:]
    var arrivals: [CheckedContinuation<Void, Never>] = []
    var waiters: [CheckedContinuation<Void, Never>] = []
    func enter(_ destination: String) async {
        active += 1
        maximum = max(maximum, active)
        perDestination[destination, default: 0] += 1
        peakByDestination[destination] = max(peakByDestination[destination, default: 0], perDestination[destination]!)
        if active >= 2 { for waiter in arrivals { waiter.resume() }; arrivals.removeAll() }
        await withCheckedContinuation { waiters.append($0) }
        active -= 1
        perDestination[destination, default: 0] -= 1
    }
    func waitForTwo() async {
        if active < 2 { await withCheckedContinuation { arrivals.append($0) } }
    }
    func release() { for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}
struct DeliveryGatedDestination: DicomDeliveryDestination {
    let id: String
    let kind = DicomDeliveryDestinationKind.webhook
    let gate: DeliveryGate
    func deliver(_ item: DicomDeliveryItem, isCancelled: @Sendable () -> Bool) async -> DicomDeliveryAttemptResult {
        await gate.enter(id)
        return isCancelled() ? .failed(.cancelled, "Cancelled", retryAfter: nil) : .delivered(.init())
    }
}

extension DicomDeliveryEngineTests {
    func test_concurrentGlobalAndDestinationLimitsAndLeasedCancellation() async throws {
        let gate = DeliveryGate()
        let store = DicomInMemoryDeliveryOutbox()
        let engine = DicomDeliveryEngine(outbox: store, destinations: [
            "peer": DeliveryGatedDestination(id: "peer", gate: gate),
            "other": DeliveryGatedDestination(id: "other", gate: gate)
        ], owner: "engine")
        try await engine.enqueue([deliveryItem("a"), deliveryItem("b"), deliveryItem("c", destination: "other")])
        let running = Task { await engine.runOnce(now: Date()) }
        await gate.waitForTwo()
        let overlap = await engine.runOnce(now: Date())
        XCTAssertEqual(overlap.attempted, 0)
        try await engine.cancel(deliveryID: "a")
        await gate.release()
        _ = await running.value
        await engine.drain()
        let maximum = await gate.maximum
        let peaks = await gate.peakByDestination
        XCTAssertEqual(maximum, 2)
        XCTAssertEqual(peaks, ["peer": 1, "other": 1])
        let cancelled = try await store.fetch(states: [.cancelled])
        XCTAssertEqual(cancelled.first?.deliveryID, "a")
    }

    func test_partialReceiptRetriesOnlyTransientSubset() async throws {
        let files = try ["1.2.3", "1.2.4", "1.2.5"].map(deliveryPart10)
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        let receipt = DicomDeliveryReceipt(status: "partial", perObject: [
            .init(sopInstanceUID: "1.2.3", accepted: true),
            .init(sopInstanceUID: "1.2.4", accepted: false, reason: "busy", errorClass: .transient),
            .init(sopInstanceUID: "1.2.5", accepted: false, reason: "unsupported", errorClass: .permanent)
        ])
        let clock = DeliveryTestClock()
        let peer = DeliveryFake(results: [.partial(receipt)])
        let store = DicomInMemoryDeliveryOutbox()
        let engine = DicomDeliveryEngine(outbox: store, destinations: ["peer": peer],
            retryPolicy: .init(random: { 1 }), owner: "engine", clock: clock.now)
        var item = deliveryItem("a")
        item.payload = .objects(files)
        try await engine.enqueue([item])
        let report = await engine.runOnce(now: clock.now())
        XCTAssertTrue(report.errors.isEmpty)
        let waiting = try await store.fetch(states: [.retryWait])
        XCTAssertEqual(waiting.first?.idempotencyKey, "a#retry1")
        XCTAssertEqual(waiting.first?.payload, .objects([files[1]]))
        let completed = try await store.fetch(states: [.delivered])
        XCTAssertEqual(completed.first?.receipt, receipt)
        clock.advance(2)
        let retried = await engine.runOnce(now: clock.now())
        XCTAssertEqual(retried.delivered, 1)
    }
}
