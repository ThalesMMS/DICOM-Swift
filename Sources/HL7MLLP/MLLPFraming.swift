import Foundation

public enum MLLPBytes {
    public static let startBlock: UInt8 = 0x0B
    public static let endBlock: UInt8 = 0x1C
    public static let carriageReturn: UInt8 = 0x0D
}

public struct MLLPFramer: Sendable {
    /// Refuses reserved SB/EB bytes, including an embedded EB CR trailer.
    /// `allowUnsafe` wraps bytes verbatim; such output need not round-trip through the strict deframer.
    public static func frame(_ payload: Data, allowUnsafe: Bool = false) throws -> Data {
        if !allowUnsafe, let offset = payload.enumerated().first(where: {
            $0.element == MLLPBytes.startBlock || $0.element == MLLPBytes.endBlock
        })?.offset {
            throw MLLPFramingError(reason: .unsafePayload, byteOffset: offset, droppedBytes: 0)
        }
        var result = Data([MLLPBytes.startBlock])
        result.append(payload)
        result.append(contentsOf: [MLLPBytes.endBlock, MLLPBytes.carriageReturn])
        return result
    }
}

public struct MLLPLimits: Sendable, Equatable {
    public enum Recovery: Sendable { case strict, resynchronize }
    public var maxMessageBytes = 16 * 1024 * 1024
    public var maxBufferedBytes = 32 * 1024 * 1024
    public var maxPendingFrames = 64
    public var maxJunkBytesBetweenBlocks = 4 * 1024
    public var maxInFlight = 16
    public var connectionLifetime: TimeInterval = 3600
    public var idleTimeout: TimeInterval = 60
    public var recovery: Recovery = .strict
    public init() {}

    var isValid: Bool {
        maxInFlight > 0 && maxInFlight <= Int.max / 4 && connectionLifetime.isFinite && connectionLifetime > 0
            && maxMessageBytes >= 0 && maxMessageBytes <= Int.max - 3 && maxBufferedBytes > 0 && maxPendingFrames > 0
            && maxJunkBytesBetweenBlocks >= 0 && idleTimeout.isFinite && idleTimeout >= 0
    }
}

public enum MLLPLossReason: Sendable, Equatable {
    case unsafePayload, unexpectedStartBlock, invalidTrailer, messageLimit, bufferLimit
    case junkLimit, incompleteBlock, invalidLimits, pendingFramesLimit, closed
}

public struct MLLPFramingError: Error, Sendable, Equatable {
    public let reason: MLLPLossReason
    /// Zero-based stream offset (payload offset for a framer error).
    public let byteOffset: Int
    public let droppedBytes: Int
}

public struct MLLPLoss: Sendable, Equatable {
    public let droppedBytes: Int
    public let reason: MLLPLossReason
    public let byteOffset: Int
}

public enum MLLPDiagnostic: Sendable, Equatable {
    case junkSkipped(count: Int)
    case resynchronized(dropped: Int)
}

public struct MLLPFrame: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let payload: Data
    /// One-based sequence of successfully completed frames.
    public let sequence: Int
    /// Zero-based offset of SB in the stream.
    public let byteOffset: Int
    public let diagnostics: [MLLPDiagnostic]
    public var description: String {
        "MLLPFrame(sequence: \(sequence), byteOffset: \(byteOffset), bytes: \(payload.count), diagnostics: \(diagnostics))"
    }
    public var debugDescription: String { description }
}

public struct MLLPFinishReport: Sendable, Equatable {
    /// Cumulative losses coalesced by reason (offset is the first loss for that reason).
    public let losses: [MLLPLoss]
    public let junkSkipped: Int
}
