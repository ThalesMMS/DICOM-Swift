import Foundation
import XCTest
@testable import DicomCore

@MainActor
final class DicomSourceFrameSessionTests: XCTestCase {
    func test_sharedDecodedFrame_isDecodedOnceAndPreservesOtherConsumerOnCancellation() async throws {
        let (session, gate) = try await gatedSession(inFlightBytes: 65536)
        let first = Task { try await session.dataBackedFrame(at: 2) }
        await gate.waitUntilEntered()
        let second = Task { try await session.dataBackedFrame(at: 2) }
        try await waitForConsumers(2, session: session)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled consumer succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
        let decoded = try await second.value
        XCTAssertEqual(decoded.index, 2)
        XCTAssertEqual(decoded.metadata.frameCount, 3)
        XCTAssertEqual(Array(decoded.pixels.data), (30..<45).map { UInt8(($0 * 37 + 11) % 256) })
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        let metrics = await session.metrics
        XCTAssertEqual(metrics.sharedRequests, 1)
        XCTAssertEqual(metrics.materializedBytes, 15)
        XCTAssertEqual(metrics.inFlightReservedBytes, 0)
        XCTAssertGreaterThan(metrics.source.compatibilityCopiedBytes, 15)
        await session.close()
    }

    func test_decodedBudget_rejectsBeforePixelRead() async throws {
        let (session, gate) = try await gatedSession()
        do { _ = try await session.dataBackedFrame(at: 0); XCTFail("Decode budget ignored") }
        catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .frameLimit) }
        let calls = await gate.calls
        XCTAssertEqual(calls, 0)
        await session.close()
    }

    func test_sharedFrame_oneConsumerCancellationDoesNotCancelAnother() async throws {
        let (session, gate) = try await gatedSession()
        let first = Task { try await session.frameData(at: 1) }
        await gate.waitUntilEntered()
        let second = Task { try await session.frameData(at: 1) }
        try await waitForConsumers(2, session: session)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled consumer succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let pending = await session.metrics
        XCTAssertEqual(pending.waitingConsumers, 1)
        XCTAssertEqual(pending.inFlightFrames, 1)
        XCTAssertEqual(pending.sharedRequests, 1)
        await gate.release()
        let data = try await second.value
        XCTAssertEqual(Array(data), (15..<30).map { UInt8(($0 * 37 + 11) % 256) })
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        let finished = await session.metrics
        XCTAssertEqual(finished.materializedBytes, 15)
        XCTAssertEqual(finished.inFlightReservedBytes, 0)
        XCTAssertEqual(finished.retainedCompletedBytes, 0)
        await session.close()
    }

    func test_cancelledLastConsumer_keepsReservationUntilTransportReturns() async throws {
        let (session, gate) = try await gatedSession()
        let first = Task { try await session.frameData(at: 0) }
        await gate.waitUntilEntered()
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled consumer succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let pending = await session.metrics
        XCTAssertEqual(pending.inFlightReservedBytes, 30)
        XCTAssertEqual(pending.waitingConsumers, 0)
        do { _ = try await session.frameData(at: 2); XCTFail("Outstanding allocation overbooked") }
        catch { XCTAssertEqual(error as? DicomByteSource.Failure, .concurrentReadLimit) }
        await gate.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await session.metrics.inFlightFrames != 0, ContinuousClock.now < deadline { await Task.yield() }
        let released = await session.metrics
        XCTAssertEqual(released.inFlightReservedBytes, 0)
        XCTAssertEqual(released.materializedBytes, 0)
        await session.close()
    }

    func test_closeResumesAllWaitersWithoutWaitingForIgnoringTransport() async throws {
        let (session, gate) = try await gatedSession()
        let first = Task { try await session.frameData(at: 0) }
        await gate.waitUntilEntered()
        let second = Task { try await session.frameData(at: 0) }
        try await waitForConsumers(2, session: session)
        await session.close()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Closed session published data") }
            catch { XCTAssertEqual(error as? DicomByteSource.Failure, .closed) }
        }
        await gate.release()
    }

    func test_pullSequence_readsOneFramePerNextAndRetainsNoCompletedFrames() async throws {
        let source = DicomByteSource(data: try fixture())
        let session = try await DicomSourceFrameSession.open(source: source)
        let before = await session.metrics
        var iterator = try session.frames().makeAsyncIterator()
        let created = await session.metrics
        XCTAssertEqual(created.source.receivedBytes, before.source.receivedBytes)
        for index in 0..<3 {
            let frame = try await iterator.next()
            XCTAssertEqual(frame?.index, index)
            XCTAssertEqual(frame?.data.count, 15)
            let metrics = await session.metrics
            XCTAssertEqual(metrics.source.receivedBytes - before.source.receivedBytes, 15 * (index + 1))
            XCTAssertEqual(metrics.inFlightReservedBytes, 0)
            XCTAssertEqual(metrics.retainedCompletedBytes, 0)
        }
        let end = try await iterator.next()
        XCTAssertNil(end)
        await session.close()
    }

    func test_pullSequence_readFailureTerminatesIterator() async throws {
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: fixture()))
        var iterator = try session.frames().makeAsyncIterator()
        await session.close()
        do { _ = try await iterator.next(); XCTFail("Closed session published a frame") }
        catch { XCTAssertEqual(error as? DicomByteSource.Failure, .closed) }
        for _ in 0..<2 {
            let end = try await iterator.next()
            XCTAssertNil(end)
        }
    }

    func test_pullSequence_cancelledReadTerminatesIterator() async throws {
        let (session, gate) = try await gatedSession()
        let consumer = Task {
            var iterator = try session.frames().makeAsyncIterator()
            do { _ = try await iterator.next(); XCTFail("Cancelled iterator published a frame") }
            catch { XCTAssertTrue(error is CancellationError) }
            let end = try await iterator.next()
            XCTAssertNil(end)
        }
        await gate.waitUntilEntered()
        consumer.cancel()
        let result = await consumer.result
        await gate.release()
        await session.close()
        try result.get()
    }

    private func waitForConsumers(_ count: Int, session: DicomSourceFrameSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await session.metrics.waitingConsumers != count, ContinuousClock.now < deadline { await Task.yield() }
        let actual = await session.metrics.waitingConsumers
        XCTAssertEqual(actual, count)
        if actual != count { throw DicomByteSource.Failure.concurrentReadLimit }
    }

    private func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndependentDifferential/gray8.dcm"))
    }

    private func gatedSession(inFlightBytes: Int = 30) async throws -> (DicomSourceFrameSession, Gate) {
        let bytes = try fixture()
        let probe = DicomByteSource(data: bytes)
        let metadata = try await DicomSourceMetadata.readPart10(from: probe)
        let pixels = try XCTUnwrap(metadata.pixelDataRange)
        let gate = Gate()
        let transport = DicomByteRangeTransport { request in
            if request.range.overlaps(pixels) { await gate.enter() }
            return .init(status: 206, contentRange: "bytes \(request.range.lowerBound)-\(request.range.upperBound - 1)/\(bytes.count)",
                         entityTag: "\"fixture\"", body: bytes.subdata(in: request.range))
        }
        let source = try DicomByteSource(remote: transport, count: bytes.count, entityTag: "\"fixture\"")
        let session = try await DicomSourceFrameSession.open(source: source,
            limits: .init(maximumFrameBytes: 15, maximumInFlightBytes: inFlightBytes))
        return (session, gate)
    }

    private actor Gate {
        private var entered: CheckedContinuation<Void, Never>?
        private var response: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var calls = 0

        func enter() async {
            calls += 1
            entered?.resume()
            entered = nil
            if !released { await withCheckedContinuation { response = $0 } }
        }

        func waitUntilEntered() async {
            if calls == 0 { await withCheckedContinuation { entered = $0 } }
        }

        func release() {
            released = true
            response?.resume()
            response = nil
        }
    }
}
