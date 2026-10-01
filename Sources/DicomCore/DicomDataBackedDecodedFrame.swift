/// One decoded frame whose canonical pixels remain Data-backed.
public struct DicomDataBackedDecodedFrame: Equatable, Sendable {
    /// Zero-based source frame index.
    public let index: Int
    /// Canonical decoded bytes and their explicit interpretation.
    public let pixels: DicomDecodedFrameDataBuffer
    /// Renderer-facing metadata for the decoded output.
    public let metadata: DicomDecodedFrameMetadata
    /// Host allocation accounting, shared by value copies of these same pixels.
    public let memoryOwner: (any DicomFrameMemoryOwner)?

    init(index: Int, pixels: DicomDecodedFrameDataBuffer, metadata: DicomDecodedFrameMetadata,
         memoryOwner: (any DicomFrameMemoryOwner)? = nil) {
        self.index = index
        self.pixels = pixels
        self.metadata = metadata
        self.memoryOwner = memoryOwner
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.index == rhs.index && lhs.pixels == rhs.pixels && lhs.metadata == rhs.metadata
    }

    /// Copies this frame into the source-compatible array-backed representation.
    public func copyingToArrayBackedFrame() throws -> DicomDecodedFrame {
        let owner = try memoryOwner?.reserveCopy(byteCount: pixels.data.count)
        let output = DicomDecodedFrame(index: index, pixels: pixels.copyingToArrayBackedPixels(),
                                       metadata: metadata, memoryOwner: owner)
        try owner?.didMaterialize(byteCount: pixels.data.count)
        return output
    }
}
