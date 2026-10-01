import Foundation
import XCTest
@testable import HL7MLLP

@MainActor
final class MLLPAccumulatorTests: XCTestCase {
    func test_pendingLimit_pauseUntilDeliveredFrameAcknowledged() async throws {
        var limits = MLLPLimits()
        limits.maxPendingFrames = 1
        let accumulator = MLLPAccumulator(limits: limits)
        let wire = try MLLPFramer.frame(Data([65]))
        let outcome = try await accumulator.feed(wire)
        XCTAssertEqual(outcome, .pauseReads)
        do { _ = try await accumulator.feed(wire); XCTFail("Expected capacity error") }
        catch { XCTAssertEqual((error as? MLLPFramingError)?.reason, .pendingFramesLimit) }
        let stillPaused = await accumulator.consumed()
        XCTAssertEqual(stillPaused, .pauseReads)
        let frame = await accumulator.next()
        XCTAssertEqual(frame?.payload, Data([65]))
        let pending = await accumulator.stats.pending
        XCTAssertEqual(pending, 1)
        let resumed = await accumulator.consumed()
        XCTAssertEqual(resumed, .resumeReads)
        let second = try await accumulator.feed(wire)
        XCTAssertEqual(second, .pauseReads)
        await accumulator.close()
    }

    func test_bufferLimit_countsOutstandingAndPartialBytes() async throws {
        var limits = MLLPLimits()
        limits.maxBufferedBytes = 3
        let accumulator = MLLPAccumulator(limits: limits)
        let outcome = try await accumulator.feed(Data([11, 65, 66, 28, 13, 11, 67]))
        XCTAssertEqual(outcome, .pauseReads)
        let stats = await accumulator.stats
        XCTAssertEqual(stats.bufferedBytes, 3)
        _ = await accumulator.next()
        let resumed = await accumulator.consumed()
        XCTAssertEqual(resumed, .resumeReads)
        let end = try await accumulator.feed(Data([28, 13]))
        XCTAssertEqual(end, .accepted(frames: 1))
        let frame = await accumulator.next()
        XCTAssertEqual(frame?.payload, Data([67]))
        await accumulator.close()
    }

    func test_singleChunkBeyondPendingLimit_rejectedAtomicallyAndRetryable() async throws {
        var limits = MLLPLimits()
        limits.maxPendingFrames = 1
        let accumulator = MLLPAccumulator(limits: limits)
        let wire = try MLLPFramer.frame(Data())
        do { _ = try await accumulator.feed(wire + wire); XCTFail("Expected capacity error") }
        catch { XCTAssertEqual((error as? MLLPFramingError)?.reason, .pendingFramesLimit) }
        let stats = await accumulator.stats
        XCTAssertEqual(stats.frames, 0)
        XCTAssertEqual(stats.bytes, 0)
        XCTAssertEqual(stats.pending, 0)
        _ = try await accumulator.feed(wire)
        let frame = await accumulator.next()
        XCTAssertEqual(frame?.sequence, 1)
        XCTAssertEqual(frame?.byteOffset, 0)
        await accumulator.close()
    }

    func test_byteOverflow_neverSilentlyDropsUnderRecovery() async throws {
        var limits = MLLPLimits()
        limits.maxBufferedBytes = 2
        limits.recovery = .resynchronize
        let accumulator = MLLPAccumulator(limits: limits)
        let wire = try MLLPFramer.frame(Data([65, 66, 67]))
        do { _ = try await accumulator.feed(wire); XCTFail("Expected capacity error") }
        catch { XCTAssertEqual((error as? MLLPFramingError)?.reason, .bufferLimit) }
        let stats = await accumulator.stats
        XCTAssertEqual(stats.bufferedBytes, 0)
        XCTAssertEqual(stats.dropped, 0)
        XCTAssertEqual(stats.bytes, 0)
        await accumulator.close()
    }

    func test_next_suspendsThenReceivesFrame() async throws {
        let accumulator = MLLPAccumulator()
        let started = expectation(description: "Consumer started")
        let received = expectation(description: "Consumer received frame")
        let consumer = Task {
            started.fulfill()
            let frame = await accumulator.next()
            received.fulfill()
            return frame
        }
        await fulfillment(of: [started], timeout: 1)
        _ = try await accumulator.feed(Data([11, 65]))
        let stats = await accumulator.stats
        XCTAssertEqual(stats.frames, 0)
        _ = try await accumulator.feed(Data([28, 13]))
        await fulfillment(of: [received], timeout: 1)
        let frame = await consumer.value
        XCTAssertEqual(frame?.payload, Data([65]))
        await accumulator.close()
    }

    func test_close_releasesAllWaitersAndDrainsQueuedFrames() async throws {
        let accumulator = MLLPAccumulator()
        let tasks = (0..<3).map { _ in Task { await accumulator.next() } }
        for _ in 0..<10 { await Task.yield() }
        await accumulator.close()
        for task in tasks { let value = await task.value; XCTAssertNil(value) }
        await accumulator.close()
        do { _ = try await accumulator.feed(Data()); XCTFail("Expected closed error") }
        catch { XCTAssertEqual((error as? MLLPFramingError)?.reason, .closed) }
        let queued = MLLPAccumulator()
        _ = try await queued.feed(Data([11, 65, 28, 13]))
        await queued.close()
        let frame = await queued.next()
        let end = await queued.next()
        XCTAssertEqual(frame?.payload, Data([65]))
        XCTAssertNil(end)
    }

    func test_cancelledWaiter_doesNotStealNextFrame() async throws {
        let accumulator = MLLPAccumulator()
        for _ in 0..<20 {
            let task = Task { await accumulator.next() }
            await Task.yield()
            task.cancel()
            let value = await task.value
            XCTAssertNil(value)
        }
        _ = try await accumulator.feed(Data([11, 90, 28, 13]))
        let frame = await accumulator.next()
        XCTAssertEqual(frame?.payload, Data([90]))
        await accumulator.close()
    }

    func test_stats_countWireBytesJunkLossAndPending() async throws {
        var limits = MLLPLimits()
        limits.recovery = .resynchronize
        let accumulator = MLLPAccumulator(limits: limits)
        _ = try await accumulator.feed(Data([99, 11, 65, 11, 90, 28, 13]))
        let stats = await accumulator.stats
        XCTAssertEqual(stats, MLLPAccumulatorStats(frames: 1, bytes: 7, dropped: 2,
            pending: 1, junk: 1, bufferedBytes: 1))
        _ = await accumulator.next()
        _ = await accumulator.consumed()
        let drained = await accumulator.stats
        XCTAssertEqual(drained.pending, 0)
        XCTAssertEqual(drained.bufferedBytes, 0)
        await accumulator.close()
    }

    func test_close_exposesStrictEOFErrorAndRecoveryReport() async throws {
        let strict = MLLPAccumulator()
        _ = try await strict.feed(Data([11, 65, 28]))
        await strict.close()
        let error = await strict.finishError
        XCTAssertEqual(error?.reason, .incompleteBlock)
        var limits = MLLPLimits()
        limits.recovery = .resynchronize
        let recovering = MLLPAccumulator(limits: limits)
        _ = try await recovering.feed(Data([11, 65, 28]))
        await recovering.close()
        let report = await recovering.finishReport
        XCTAssertEqual(report?.losses.first?.droppedBytes, 3)
    }
}
