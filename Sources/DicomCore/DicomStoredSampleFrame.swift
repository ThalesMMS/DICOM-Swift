import Foundation

/// One frame in the stored-sample convention of `DicomDecodedFrame.storedSampleData()`: little-endian words, signed
/// samples two's complement and masked to Bits Stored, MONOCHROME1 samples as written (issue #3111).
public struct DicomStoredSampleFrame: Equatable, Sendable {
    /// Zero-based source frame index.
    public let index: Int
    /// The stored samples.
    public let data: Data
    /// Renderer-facing metadata, the same as the decoded frame's.
    public let metadata: DicomDecodedFrameMetadata
    /// Host allocation accounting, shared by value copies of these same samples.
    public let memoryOwner: (any DicomFrameMemoryOwner)?

    init(index: Int, data: Data, metadata: DicomDecodedFrameMetadata, memoryOwner: (any DicomFrameMemoryOwner)? = nil) {
        self.index = index
        self.data = data
        self.metadata = metadata
        self.memoryOwner = memoryOwner
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.data == rhs.data && lhs.metadata == rhs.metadata
    }
}
