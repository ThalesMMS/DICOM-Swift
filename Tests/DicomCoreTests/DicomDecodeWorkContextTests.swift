import Foundation
import XCTest
@testable import DicomCore

final class DicomDecodeWorkContextTests: XCTestCase {
    func test_fallbackExecutor_boundsCancelledPhysicalWorkAndPendingRequests() async {
        let started = expectation(description: "physical worker started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let context = DicomDecodeWorkContext(memory: nil)
        let executor = DicomFallbackWorkExecutor(maximumRunning: 1, maximumQueued: 1)
        let first = Task {
            try await DicomDecodeWorkContext.$current.withValue(context) {
                try await DicomCancellableDetachedOperation.run(executor: executor) {
                    started.fulfill()
                    release.wait()
                    return 1
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled caller succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }

        let second = Task {
            try await DicomCancellableDetachedOperation.run(executor: executor) {
                XCTFail("Queued cancelled work must not start")
                return 2
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await executor.snapshot.queued == 0, ContinuousClock.now < deadline { await Task.yield() }
        let occupied = await executor.snapshot
        XCTAssertEqual(occupied.running, 1)
        XCTAssertEqual(occupied.queued, 1)
        do {
            _ = try await DicomCancellableDetachedOperation.run(executor: executor) { 3 }
            XCTFail("Full queue admitted another worker")
        } catch { XCTAssertTrue(error is DicomFallbackWorkExecutor.Failure) }
        second.cancel()
        do { _ = try await second.value; XCTFail("Cancelled queued caller succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cancelled = await executor.snapshot
        XCTAssertEqual(cancelled.running, 1)
        XCTAssertEqual(cancelled.queued, 0)
        release.signal()
        await context.waitForWorkers()
        let drained = await executor.snapshot
        XCTAssertEqual(drained.running, 0)
        XCTAssertEqual(drained.queued, 0)
    }

    func test_cancelledFallback_keepsPhysicalWorkerUntilSynchronousOperationExits() async {
        let started = expectation(description: "physical worker started")
        let cancelled = expectation(description: "consumer cancelled promptly")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let context = DicomDecodeWorkContext(memory: nil)
        let consumer = Task {
            try await DicomDecodeWorkContext.$current.withValue(context) {
                try await DicomCancellableDetachedOperation.run {
                    started.fulfill()
                    release.wait()
                    return 7
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        consumer.cancel()
        let observer = Task {
            do {
                _ = try await consumer.value
                XCTFail("Cancelled consumer returned pixels")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch { XCTFail("Unexpected error: \(error)") }
        }
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(context.activeWorkerCount, 1)
        release.signal()
        await context.waitForWorkers()
        XCTAssertEqual(context.activeWorkerCount, 0)
        await observer.value
    }

    func test_failedFallback_releasesPhysicalWorker() async {
        enum Failure: Error { case expected }
        let context = DicomDecodeWorkContext(memory: nil)
        do {
            let _: Int = try await DicomDecodeWorkContext.$current.withValue(context) {
                try await DicomCancellableDetachedOperation.run { throw Failure.expected }
            }
            XCTFail("Expected codec failure")
        } catch { XCTAssertTrue(error is Failure) }
        await context.waitForWorkers()
        XCTAssertEqual(context.activeWorkerCount, 0)
    }
}
