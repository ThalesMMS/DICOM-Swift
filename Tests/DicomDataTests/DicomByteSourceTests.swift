import DicomData
import Foundation
import Synchronization
import XCTest

@MainActor
final class DicomByteSourceTests: XCTestCase {
    func test_memorySlice_tracksLogicalRangesAndExplicitCopiesUntilClose() async throws {
        var original = Data([0xEE, 0xEE, 1, 2, 3, 4])
        let source = DicomByteSource(data: original.dropFirst(2))
        original.resetBytes(in: original.startIndex..<original.endIndex)
        let lease = try await source.read(1..<4)
        XCTAssertEqual(try lease.withUnsafeBytes { Array($0) }, [2, 3, 4])
        let copy = try lease.copyData()
        let metrics = await source.metrics
        XCTAssertEqual(metrics.ranges, [1..<4])
        XCTAssertEqual(metrics.storageCopiedBytes, 0)
        XCTAssertEqual(metrics.compatibilityCopiedBytes, 3)
        await source.close()
        XCTAssertThrowsError(try lease.copyData()) { XCTAssertEqual($0 as? DicomByteSource.Failure, .closed) }
        XCTAssertEqual(copy, Data([2, 3, 4]))
        await assertFailure(.closed) { _ = try await source.read(0..<1) }
    }

    func test_invalidRangesAndBudgets_failBeforeReading() async throws {
        let source = DicomByteSource(data: Data([1, 2, 3, 4]),
                                     limits: .init(maximumReadBytes: 2, maximumTotalReadBytes: 3))
        await assertFailure(.invalidRange) { _ = try await source.read(-1..<2) }
        await assertFailure(.invalidRange) { _ = try await source.read(0..<Int.max) }
        await assertFailure(.readLimit) { _ = try await source.read(0..<3) }
        _ = try await source.read(0..<2)
        await assertFailure(.totalReadLimit) { _ = try await source.read(2..<4) }
        let metrics = await source.metrics
        XCTAssertEqual(metrics.readCount, 1)
        XCTAssertEqual(metrics.requestedBytes, 2)
    }

    func test_fileAndMappedReads_handleUnalignedRangesAndInvalidateOnTruncation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data((0..<16384).map { UInt8(truncatingIfNeeded: $0) })
        for mode in [DicomByteSource.FileStorage.buffer, .mappedSnapshot] {
            try bytes.write(to: url)
            let source = try await DicomByteSource.openFile(url, storage: mode)
            let lease = try await source.read(7..<8201)
            XCTAssertEqual(try lease.copyData(), bytes.subdata(in: 7..<8201))
            let metrics = await source.metrics
            XCTAssertEqual(metrics.receivedBytes, 8194)
            XCTAssertEqual(metrics.storageCopiedBytes, 8194)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 1)
            try handle.close()
            // An already acquired owned view is safe despite external truncation.
            XCTAssertEqual(try lease.copyData(), bytes.subdata(in: 7..<8201))
            await assertFailure(.changed) { _ = try await source.read(0..<1) }
            XCTAssertThrowsError(try lease.copyData())
            await source.close()
            XCTAssertThrowsError(try lease.withUnsafeBytes { $0.count })
        }
    }

    func test_fileReplacement_isDetectedEvenWhenOriginalDescriptorRemainsReadable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)
        let source = try await DicomByteSource.openFile(url)
        try Data([1, 2, 3]).write(to: url, options: .atomic)
        await assertFailure(.changed) { _ = try await source.read(0..<3) }
        await source.close()
    }

    func test_remoteResponses_validateRangeRevisionLengthAndStatus() async throws {
        typealias Response = DicomByteRangeTransport.Response
        let cases: [(Response, DicomByteSource.Failure)] = [
            (.init(status: 206, contentRange: "bytes 2-3/5", entityTag: "\"a\"", body: Data([2, 3])), .invalidContentRange),
            (.init(status: 206, contentRange: "bytes 2-3/4", entityTag: "\"b\"", body: Data([2, 3])), .changed),
            (.init(status: 206, contentRange: "bytes 2-3/4", entityTag: "\"a\"", body: Data([2])), .shortRead(expected: 2, actual: 1)),
            (.init(status: 200, contentRange: nil, entityTag: "\"a\"", body: Data([0, 1, 2, 3])), .readLimit),
            (.init(status: 401, contentRange: nil, entityTag: nil, body: Data()), .httpStatus(401)),
            (.init(status: 412, contentRange: nil, entityTag: nil, body: Data()), .changed),
            (.init(status: 412, contentRange: nil, entityTag: nil, body: Data(repeating: 0, count: 16)), .changed),
            (.init(status: 416, contentRange: nil, entityTag: nil, body: Data(repeating: 0, count: 16)), .rangeUnsupported)
        ]
        for (response, expected) in cases {
            let transport = DicomByteRangeTransport { request in
                XCTAssertEqual(request.range, 2..<4)
                XCTAssertEqual(request.ifMatch, "\"a\"")
                XCTAssertEqual(request.maximumResponseBytes, 2)
                return response
            }
            let source = try DicomByteSource(remote: transport, count: 4, entityTag: "\"a\"")
            await assertFailure(expected) { _ = try await source.read(2..<4) }
        }
    }

    func test_completeRemoteFallback_consumesActualResponseBudget() async throws {
        let transport = DicomByteRangeTransport { _ in
            .init(status: 200, contentRange: nil, entityTag: "\"a\"", body: Data([0, 1, 2, 3]))
        }
        let source = try DicomByteSource(remote: transport, count: 4, entityTag: "\"a\"",
                                         maximumFullResponseBytes: 4,
                                         limits: .init(maximumReadBytes: 4, maximumTotalReadBytes: 4))
        let lease = try await source.read(2..<3)
        XCTAssertEqual(try lease.copyData(), Data([2]))
        await assertFailure(.totalReadLimit) { _ = try await source.read(0..<1) }
        let metrics = await source.metrics
        XCTAssertEqual(metrics.receivedBytes, 4)
    }

    func test_preCancelledRead_doesNotInvokeTransport() async throws {
        let calls = Mutex(0)
        let source = try DicomByteSource(remote: .init { _ in
            calls.withLock { $0 += 1 }
            return .init(status: 206, contentRange: "bytes 0-0/1", entityTag: "\"a\"", body: Data([1]))
        }, count: 1, entityTag: "\"a\"")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.read(0..<1)
        }
        do { _ = try await task.value; XCTFail("Cancelled read succeeded") }
        catch is CancellationError {}
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func test_closeDuringRemoteRead_invalidatesResultAndBoundsConcurrentWork() async throws {
        let gate = ResponseGate()
        let source = try DicomByteSource(remote: .init { _ in
            await gate.pause()
            return .init(status: 206, contentRange: "bytes 0-0/1", entityTag: "\"a\"", body: Data([1]))
        }, count: 1, entityTag: "\"a\"", limits: .init(maximumConcurrentReads: 1))
        let task = Task { try await source.read(0..<1) }
        await gate.waitUntilEntered()
        await assertFailure(.concurrentReadLimit) { _ = try await source.read(0..<1) }
        await source.close()
        await gate.release()
        await assertFailure(.closed) { _ = try await task.value }
    }

    func test_cancellationDuringRemoteRead_cannotPublishIgnoredCancellationResponse() async throws {
        let gate = ResponseGate()
        let source = try DicomByteSource(remote: .init { _ in
            await gate.pause()
            return .init(status: 206, contentRange: "bytes 0-0/1", entityTag: "\"a\"", body: Data([1]))
        }, count: 1, entityTag: "\"a\"")
        let task = Task { try await source.read(0..<1) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled read returned a lease") }
        catch is CancellationError {}
    }

    func test_contentRangeGrammar_acceptsCaseInsensitiveUnitsAndRejectsMalformedExtents() async throws {
        for field in ["bytes 2/3-4", "bytes 2--3/4", "bytes 2-3/*", "bytes 2-3/999999999999999999999999", "bytes +2-3/4"] {
            let source = try DicomByteSource(remote: .init { _ in
                .init(status: 206, contentRange: field, entityTag: "\"a\"", body: Data([2, 3]))
            }, count: 4, entityTag: "\"a\"")
            await assertFailure(.invalidContentRange) { _ = try await source.read(2..<4) }
        }
        let source = try DicomByteSource(remote: .init { _ in
            .init(status: 206, contentRange: "BYTES 02-03/04", entityTag: "\"a\"", body: Data([2, 3]))
        }, count: 4, entityTag: "\"a\"")
        let lease = try await source.read(2..<4)
        XCTAssertEqual(try lease.copyData(), Data([2, 3]))
    }

    private actor ResponseGate {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var responseWaiter: CheckedContinuation<Void, Never>?

        func pause() async {
            entered = true
            enteredWaiter?.resume()
            enteredWaiter = nil
            await withCheckedContinuation { responseWaiter = $0 }
        }

        func waitUntilEntered() async {
            if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
        }

        func release() { responseWaiter?.resume(); responseWaiter = nil }
    }

    private func assertFailure(_ expected: DicomByteSource.Failure,
                               _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? DicomByteSource.Failure, expected) }
    }
}
