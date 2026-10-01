import Foundation

public enum MLLPFeedOutcome: Sendable, Equatable {
    case accepted(frames: Int)
    case pauseReads
    case resumeReads
}

public struct MLLPAccumulatorStats: Sendable, Equatable {
    public let frames: Int
    public let bytes: Int
    public let dropped: Int
    public let pending: Int
    public let junk: Int
    public let bufferedBytes: Int
}

public actor MLLPAccumulator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<MLLPFrame?, Never>
    }
    private var deframer: MLLPDeframer
    private var queue: [MLLPFrame] = []
    private var outstanding: [Int] = []
    private var waiters: [Waiter] = []
    private var retainedBytes = 0
    public private(set) var peakBufferedBytes = 0
    private var totalFrames = 0
    private var totalBytes = 0
    public private(set) var closed = false
    private var paused = false
    public private(set) var finishReport: MLLPFinishReport?
    public private(set) var finishError: MLLPFramingError?

    public init(limits: MLLPLimits = .init()) { deframer = MLLPDeframer(limits: limits) }

    public var stats: MLLPAccumulatorStats {
        MLLPAccumulatorStats(frames: totalFrames, bytes: totalBytes, dropped: deframer.droppedBytes,
            pending: queue.count + outstanding.count, junk: deframer.junkBytes,
            bufferedBytes: retainedBytes + deframer.bufferedBytes)
    }

    /// Atomic admission: success always consumes the entire chunk, including on `pauseReads`.
    /// Capacity errors consume nothing; retain the chunk and retry after consumption, or split it.
    /// Calling while paused throws (never ambiguously returns pauseReads for an unconsumed chunk).
    /// Limits include frames handed to consumers until acknowledged by `consumed()` in delivery order.
    public func feed(_ chunk: Data) throws -> MLLPFeedOutcome {
        if closed { throw admissionError(.closed) }
        if paused {
            throw admissionError(stats.pending >= deframer.limits.maxPendingFrames
                ? .pendingFramesLimit : .bufferLimit)
        }
        var candidate = deframer
        var frames: [MLLPFrame] = []
        var bytes = retainedBytes
        for byte in chunk {
            // Capacity must not be mistaken for corrupt framing in resynchronize mode.
            // The candidate may discard malformed blocks, but cannot discard data due to queue pressure.
            let lossBefore = candidate.losses.first(where: { $0.reason == .bufferLimit })?.droppedBytes ?? 0
            if let frame = try candidate.accept(byte, retainedBytes: bytes) {
                guard queue.count + outstanding.count + frames.count < candidate.limits.maxPendingFrames else {
                    throw admissionError(.pendingFramesLimit)
                }
                frames.append(frame)
                bytes += frame.payload.count
            }
            if candidate.isDiscardingForBufferLimit ||
                (candidate.losses.first(where: { $0.reason == .bufferLimit })?.droppedBytes ?? 0) > lossBefore {
                throw admissionError(.bufferLimit)
            }
        }
        deframer = candidate
        queue.append(contentsOf: frames)
        retainedBytes = bytes
        peakBufferedBytes = max(peakBufferedBytes, retainedBytes + deframer.bufferedBytes)
        totalFrames += frames.count
        totalBytes += chunk.count
        deliver()
        paused = atCapacity
        return paused ? .pauseReads : .accepted(frames: frames.count)
    }

    /// Cancellation returns nil and removes only this waiter, without consuming a queued frame.
    public func next() async -> MLLPFrame? {
        if Task.isCancelled { return nil }
        if !queue.isEmpty { return take() }
        if closed { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Acknowledge one delivered frame in delivery order; queued frames cannot be acknowledged.
    @discardableResult
    public func consumed() -> MLLPFeedOutcome {
        if !outstanding.isEmpty { retainedBytes -= outstanding.removeFirst() }
        if paused && !atCapacity {
            paused = false
            return .resumeReads
        }
        return paused ? .pauseReads : .accepted(frames: 0)
    }

    /// Releases waiters; completed queued frames remain drainable. Partial framing is finalized once.
    /// Strict EOF errors are exposed through finishError because close itself is nonthrowing.
    public func close(discardPending: Bool = false) {
        if discardPending {
            queue.removeAll(); outstanding.removeAll(); retainedBytes = 0
        }
        guard !closed else { return }
        closed = true
        do { finishReport = try deframer.finish() }
        catch let error as MLLPFramingError { finishError = error }
        catch { preconditionFailure("Unexpected framing error type") }
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
        waiters.removeAll()
    }

    private var atCapacity: Bool {
        stats.pending >= deframer.limits.maxPendingFrames || stats.bufferedBytes >= deframer.limits.maxBufferedBytes
    }

    private func admissionError(_ reason: MLLPLossReason) -> MLLPFramingError {
        MLLPFramingError(reason: reason, byteOffset: deframer.lastActivityOffset, droppedBytes: 0)
    }

    private func take() -> MLLPFrame {
        let frame = queue.removeFirst()
        outstanding.append(frame.payload.count)
        return frame
    }

    private func deliver() {
        while !waiters.isEmpty && !queue.isEmpty {
            waiters.removeFirst().continuation.resume(returning: take())
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: nil)
    }
}
