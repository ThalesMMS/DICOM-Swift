//
//  DicomTranscodeExecutionPlan.swift
//
//  The executable plan of one transcode: what the engine will do to the dataset and to each frame, at what
//  cost, and with which identity and provenance consequences, decided before any frame is decoded.
//

import Foundation

/// A qualified route with its steps, per-frame source format, predicted cost and streaming ability.
public struct DicomTranscodeExecutionPlan: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Same transfer syntax: bytes carried unchanged.
        case passThrough
        /// Native ⇄ native (or deflate): dataset rewritten, pixel bytes unchanged.
        case rewriteDataset
        /// Encapsulated codestreams carried into a transfer syntax that accepts them unchanged.
        case rewrap
        /// Encapsulated → native: frames decoded, stored bytes written.
        case decode
        /// Native → encapsulated: frames encoded.
        case encode
        /// Encapsulated → encapsulated through decode and encode.
        case transcode
        /// JPEG → JPEG XL byte-exact recompression.
        case recompress
    }

    public enum OffsetTables: String, Equatable, Sendable {
        case basic, extended
        /// An empty Basic Offset Table: the fragments are component collections, not frames (JPEG 2000 Part 2).
        case emptyBasic = "empty-basic"
    }

    public enum Step: Equatable, Sendable {
        case carryDataset
        case copyEncapsulatedRegion(frames: Int)
        /// JPEG 2000/HTJ2K frames carried in a JP2/JPX/JPH file-format wrapper are reduced to their raw codestream
        /// (PS3.5 A.4.4) without re-encoding and re-encapsulated.
        case unwrapContainers(frames: Int)
        case decodeFrames(frames: Int, codec: String)
        case encodeFrames(frames: Int, codec: String)
        case writeNativePixels(frames: Int)
        case encapsulate(offsetTables: OffsetTables)
        case deflateDataset
        case assignNewSOPInstanceUID
        case recordLossHistory(method: String)
    }

    /// Format of the frames as they are stored in the source.
    public struct FrameFormat: Equatable, Sendable {
        public let transferSyntaxUID: String
        public let rows: Int
        public let columns: Int
        public let bitsAllocated: Int
        public let bitsStored: Int
        public let samplesPerPixel: Int
        public let photometricInterpretation: String
        public let isEncapsulated: Bool
    }

    /// Predicted cost; the executor reports what was observed.
    public struct Cost: Equatable, Sendable {
        public let inputBytes: Int
        public let frameCount: Int
        /// Bytes of one decoded frame (stored samples).
        public let decodedFrameBytes: Int
        /// Bytes of each source frame as stored (native frame size or encapsulated frame length).
        public let sourceFrameByteCounts: [Int]
        /// Largest amount of pixel memory the streaming executor holds at once.
        public let workingSetBytes: Int
    }

    public let source: DicomTransferSyntax
    public let destination: DicomTransferSyntax
    public let intent: DicomEncodingIntent
    /// Resolved explicit configuration; nil preserves the existing encoder defaults.
    public let jpeg2000Options: DicomJPEG2000EncodingOptions?
    public let kind: Kind
    public let steps: [Step]
    public let frameFormat: FrameFormat?
    public let cost: Cost
    /// A lossy operation derives a new SOP Instance.
    public let assignsNewSOPInstanceUID: Bool
    /// Whether the executor can write frame by frame to a file; otherwise the artifact is built in memory.
    public let isStreamable: Bool
    public let diagnostics: [String]
}

/// Progress of one execution, per frame.
public struct DicomTranscodeProgress: Equatable, Sendable {
    public let framesCompleted: Int
    public let frameCount: Int
    public let bytesWritten: Int
}

/// Encoded frames kept after an execution so another container can be assembled without re-encoding.
public struct DicomEncodedFrameSet: Equatable, Sendable {
    public let transferSyntax: DicomTransferSyntax
    public let descriptor: DicomCompressedFrameDescriptor
    public let codestreams: [Data]
    public let decodedByteCount: Int

    public var encodedByteCount: Int { codestreams.reduce(0) { $0 + $1.count } }
}

/// Outcome of one execution.
public struct DicomTranscodeExecutionResult: Sendable {
    public struct FrameOutcome: Equatable, Sendable {
        public let index: Int
        public let inputBytes: Int
        public let outputBytes: Int
    }

    public struct ObservedCost: Equatable, Sendable {
        public let outputBytes: Int
        public let peakWorkingSetBytes: Int
        public let elapsed: TimeInterval
    }

    /// The artifact when no destination URL was given.
    public let data: Data?
    /// The published file when a destination URL was given.
    public let outputURL: URL?
    public let sopInstanceUID: String
    public let frames: [FrameOutcome]
    public let observed: ObservedCost
    public let encodedFrames: DicomEncodedFrameSet?
}
