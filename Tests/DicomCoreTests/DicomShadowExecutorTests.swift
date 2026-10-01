import Foundation
import Synchronization
import XCTest
@testable import DicomCore

@MainActor
final class DicomShadowExecutorTests: XCTestCase {
    func test_shadowClosure_retainsTransferredPixelOwnerAndReleasesItWhenDrained() async {
        let executor = DicomShadowExecutor()
        let session = DicomShadowSession()
        let gate = Gate()
        let released = Mutex(false)
        let ownerReleased = expectation(description: "pixel owner released")
        await submitOwned(executor: executor, session: session, gate: gate) {
            released.withLock { $0 = true }
            ownerReleased.fulfill()
        }
        XCTAssertFalse(released.withLock { $0 })
        await gate.release()
        await executor.drain(session: session)
        await fulfillment(of: [ownerReleased], timeout: 2)
        XCTAssertTrue(released.withLock { $0 })
    }

    private func submitOwned(executor: DicomShadowExecutor, session: DicomShadowSession,
                             gate: Gate, onRelease: @escaping @Sendable () -> Void) async {
        let context = DicomDecodeWorkContext(memory: nil, shadowSession: session)
        context.retainOutput(Owner(onRelease: onRelease))
        _ = await executor.submit(session: session, bytes: 8, sampleEvery: 1) {
            defer { withExtendedLifetime(context) {} }
            await gate.wait()
        }
    }

    func test_closeDuringSynchronousFallback_keepsShadowSlotUntilPhysicalCompletion() async {
        let executor = DicomShadowExecutor()
        let session = DicomShadowSession()
        let started = expectation(description: "physical fallback started")
        let cancelled = expectation(description: "logical shadow decode cancelled")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        _ = await executor.submit(session: session, bytes: 8, sampleEvery: 1) {
            do {
                _ = try await DicomCancellableDetachedOperation.run {
                    started.fulfill()
                    release.wait()
                    return 1
                }
                XCTFail("Closed shadow returned pixels")
            } catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [started], timeout: 2)
        await executor.cancel(session: session)
        await fulfillment(of: [cancelled], timeout: 2)
        let retained = await executor.snapshot
        XCTAssertEqual(retained.running, 1)
        XCTAssertEqual(retained.retainedBytes, 8)
        release.signal()
        await executor.drain(session: session)
        let drained = await executor.snapshot
        XCTAssertEqual(drained.running, 0)
        XCTAssertEqual(drained.retainedBytes, 0)
    }

    func test_limitsAndClose_keepRunningBytesUntilWorkerExitsAndPreserveOtherSession() async {
        let clock = Mutex<UInt64>(0)
        let executor = DicomShadowExecutor(limits: .init(
            maximumRunning: 1, maximumQueued: 1, maximumRetainedBytes: 10
        ), now: { clock.withLock { $0 } })
        let first = DicomShadowSession()
        let second = DicomShadowSession()
        let started = expectation(description: "shadow worker started")
        let otherStarted = expectation(description: "other session runs after cancelled worker exits")
        let gate = Gate()
        let admitted = await executor.submit(session: first, bytes: 4, sampleEvery: 1) {
            started.fulfill()
            await gate.wait()
        }
        XCTAssertEqual(admitted, .admitted)
        await fulfillment(of: [started], timeout: 2)
        let queued = await executor.submit(session: second, bytes: 4, sampleEvery: 1) { otherStarted.fulfill() }
        XCTAssertEqual(queued, .admitted)
        let overflow = await executor.submit(session: second, bytes: 1, sampleEvery: 1) {
            XCTFail("Rejected shadow ran")
        }
        XCTAssertEqual(overflow, .queueFull)
        let bytes = await executor.submit(session: second, bytes: 3, sampleEvery: 1) {
            XCTFail("Shadow exceeded payload budget")
        }
        XCTAssertEqual(bytes, .byteLimit)
        await executor.cancel(session: first)
        let cancelled = await executor.snapshot
        XCTAssertEqual(cancelled.running, 1)
        XCTAssertEqual(cancelled.queued, 1)
        XCTAssertEqual(cancelled.retainedBytes, 8)
        let late = await executor.submit(session: first, bytes: 0, sampleEvery: 1) {
            XCTFail("Closed session accepted late work")
        }
        XCTAssertEqual(late, .closed)
        clock.withLock { $0 = 75 }
        await gate.release()
        await executor.drain(session: first)
        await executor.drain(session: second)
        await fulfillment(of: [otherStarted], timeout: 2)
        let drained = await executor.snapshot
        XCTAssertEqual(drained.running, 0)
        XCTAssertEqual(drained.queued, 0)
        XCTAssertEqual(drained.retainedBytes, 0)
        XCTAssertEqual(drained.completed, 2)
        XCTAssertEqual(drained.dropped, 3)
        XCTAssertEqual(drained.maximumQueueWaitNanoseconds, 75)
    }

    func test_samplingAndQueuedCancellation_doNotSpawnWork() async {
        let executor = DicomShadowExecutor()
        let running = DicomShadowSession()
        let pending = DicomShadowSession()
        let gate = Gate()
        let started = expectation(description: "running")
        _ = await executor.submit(session: running, bytes: 4, sampleEvery: 2) {
            started.fulfill()
            await gate.wait()
        }
        await fulfillment(of: [started], timeout: 2)
        let sampled = await executor.submit(session: pending, bytes: 4, sampleEvery: 2) {
            XCTFail("Sampled-out job ran")
        }
        XCTAssertEqual(sampled, .sampledOut)
        let queued = await executor.submit(session: pending, bytes: 4, sampleEvery: 2) {
            XCTFail("Cancelled queued job ran")
        }
        XCTAssertEqual(queued, .admitted)
        await executor.cancel(session: pending)
        await executor.drain(session: pending)
        let snapshot = await executor.snapshot
        XCTAssertEqual(snapshot.queued, 0)
        XCTAssertEqual(snapshot.retainedBytes, 4)
        await gate.release()
        await executor.drain(session: running)
    }

    private actor Gate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private final class Owner: DicomFrameMemoryOwner {
        let allocationIdentity = UUID()
        let onRelease: @Sendable () -> Void

        init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
        func reserveCopy(byteCount: Int) throws -> any DicomFrameMemoryOwner {
            XCTFail("Ownership test must not copy pixels")
            return self
        }
        func didMaterialize(byteCount: Int) throws {}
        deinit { onRelease() }
    }
}
