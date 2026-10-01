import Foundation

public struct MLLPDeframer: Sendable {
    private enum State: Sendable { case idle, inBlock, trailer, discarding, discardTrailer }
    public let limits: MLLPLimits
    private var state: State = .idle
    private var payload = Data()
    private var blockOffset = 0
    private var sequence = 0
    private var junk = 0
    private var diagnosticJunk = 0
    private var diagnosticDropped = 0
    private var discardReason: MLLPLossReason = .incompleteBlock
    private var failure: MLLPFramingError?
    /// Bounded by the number of reasons, not the number of malformed blocks.
    public private(set) var losses: [MLLPLoss] = []
    public private(set) var junkBytes = 0
    public private(set) var droppedBytes = 0
    /// Number of input bytes processed; unchanged by an empty feed.
    public private(set) var lastActivityOffset = 0
    public var bufferedBytes: Int { payload.count }
    var isDiscardingForBufferLimit: Bool {
        (state == .discarding || state == .discardTrailer) && discardReason == .bufferLimit
    }

    public init(limits: MLLPLimits = .init()) { self.limits = limits }

    /// Time is supplied by the connection layer; framing owns no clock or networking.
    public func isIdle(since: TimeInterval, now: TimeInterval) -> Bool {
        now >= since && now - since >= limits.idleTimeout
    }

    /// Returned payloads plus partial payload are bounded by maxBufferedBytes during this call.
    /// A strict failure is terminal; earlier frames in the failed call are not returned.
    public mutating func feed(_ chunk: Data) throws -> [MLLPFrame] {
        var frames: [MLLPFrame] = []
        var retained = 0
        for byte in chunk {
            if let frame = try accept(byte, retainedBytes: retained) {
                frames.append(frame)
                retained += frame.payload.count
            }
        }
        return frames
    }

    mutating func accept(_ byte: UInt8, retainedBytes: Int) throws -> MLLPFrame? {
        if let failure { throw failure }
        guard limits.isValid else { throw fail(.invalidLimits, offset: lastActivityOffset) }
        let offset = lastActivityOffset
        lastActivityOffset += 1
        switch state {
        case .idle:
            if byte == MLLPBytes.startBlock { start(at: offset) }
            else {
                junk += 1
                junkBytes += 1
                diagnosticJunk += 1
                if junk > limits.maxJunkBytesBetweenBlocks { throw fail(.junkLimit, offset: offset) }
            }
        case .inBlock:
            if byte == MLLPBytes.startBlock {
                try abort(.unexpectedStartBlock, at: offset)
                endLoss(at: offset)
                start(at: offset)
            } else if byte == MLLPBytes.endBlock { state = .trailer }
            else if payload.count >= limits.maxMessageBytes {
                try abort(.messageLimit, at: offset)
            } else if retainedBytes >= limits.maxBufferedBytes - payload.count {
                try abort(.bufferLimit, at: offset)
            } else { payload.append(byte) }
        case .trailer:
            if byte == MLLPBytes.carriageReturn {
                sequence += 1
                var diagnostics: [MLLPDiagnostic] = []
                if diagnosticJunk > 0 { diagnostics.append(.junkSkipped(count: diagnosticJunk)) }
                if diagnosticDropped > 0 { diagnostics.append(.resynchronized(dropped: diagnosticDropped)) }
                let frame = MLLPFrame(payload: payload, sequence: sequence, byteOffset: blockOffset,
                                      diagnostics: diagnostics)
                payload = Data()
                diagnosticJunk = 0
                diagnosticDropped = 0
                state = .idle
                return frame
            }
            try abort(.invalidTrailer, at: offset)
            if byte == MLLPBytes.startBlock {
                endLoss(at: offset)
                start(at: offset)
            } else if byte == MLLPBytes.endBlock { state = .discardTrailer }
        case .discarding, .discardTrailer:
            if byte == MLLPBytes.startBlock {
                endLoss(at: offset)
                start(at: offset)
            } else if state == .discardTrailer && byte == MLLPBytes.carriageReturn {
                endLoss(at: offset + 1)
                state = .idle
            } else { state = byte == MLLPBytes.endBlock ? .discardTrailer : .discarding }
        }
        return nil
    }

    public mutating func finish() throws -> MLLPFinishReport {
        if let failure { throw failure }
        guard limits.isValid else { throw fail(.invalidLimits, offset: lastActivityOffset) }
        if state != .idle {
            if state == .inBlock || state == .trailer {
                try abort(.incompleteBlock, at: lastActivityOffset)
            }
            endLoss(at: lastActivityOffset)
            state = .idle
        }
        return MLLPFinishReport(losses: losses, junkSkipped: junkBytes)
    }

    private mutating func start(at offset: Int) {
        blockOffset = offset
        junk = 0
        state = .inBlock
    }

    private mutating func fail(_ reason: MLLPLossReason, offset: Int) -> MLLPFramingError {
        let error = MLLPFramingError(reason: reason, byteOffset: offset,
                                    droppedBytes: state == .idle ? 0 : lastActivityOffset - blockOffset)
        payload = Data()
        failure = error
        return error
    }

    private mutating func abort(_ reason: MLLPLossReason, at offset: Int) throws {
        if limits.recovery == .strict { throw fail(reason, offset: offset) }
        payload = Data()
        discardReason = reason
        state = .discarding
    }

    private mutating func endLoss(at offset: Int) {
        // Counts all wire bytes of the discarded block, including SB and any discarded trailer.
        let count = offset - blockOffset
        droppedBytes += count
        diagnosticDropped += count
        if let index = losses.firstIndex(where: { $0.reason == discardReason }) {
            let old = losses[index]
            losses[index] = MLLPLoss(droppedBytes: old.droppedBytes + count, reason: old.reason,
                                     byteOffset: old.byteOffset)
        } else {
            losses.append(MLLPLoss(droppedBytes: count, reason: discardReason, byteOffset: blockOffset))
        }
    }
}
