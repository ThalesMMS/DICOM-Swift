/// PHI-free parser findings. Frame and segment indexes are zero-based sequence indexes.
public struct DicomSegmentationDiagnostic: Error, Equatable, Sendable {
    public enum Code: String, Sendable {
        case frameWithoutSegment
        case segmentWithoutFrames
        case fractionalValueAboveMaximum
        case labelmapValueWithoutSegment
        case referencedInstanceNotInReferencedSeries
        case segmentsOverlapDeclaredNoButOverlapping
        case frameGeometryMissing
        case unknownSegmentationType
        case unsupportedTransferSyntax
        case invalidBinaryRLE
        case lossySegmentationFrame
        case compressedFrameDecodeFailed
    }

    public let code: Code
    public let message: String
    public let transferSyntaxUID: String?
    public let frameIndex: Int?
    public let segmentIndex: Int?

    public init(code: Code, frameIndex: Int? = nil, segmentIndex: Int? = nil, transferSyntaxUID: String? = nil) {
        self.code = code
        self.transferSyntaxUID = transferSyntaxUID
        self.message = transferSyntaxUID.map { "\(code.rawValue): \($0)" } ?? code.rawValue
        self.frameIndex = frameIndex
        self.segmentIndex = segmentIndex
    }
}
