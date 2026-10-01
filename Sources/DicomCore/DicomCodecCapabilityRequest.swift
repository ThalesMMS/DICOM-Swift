import Foundation

/// A specific frame operation, including the declared layout and optional codestream evidence.
public struct DicomCodecCapabilityRequest: Sendable {
    public let operation: DicomCodecOperation
    public let descriptor: DicomCompressedFrameDescriptor
    public let intent: DicomEncodingIntent
    /// Nil qualifies metadata only; decode still validates the actual codestream before returning pixels.
    public let frameData: Data?
    public let partialDecode: DicomCodecPartialDecodeRequest?
    public let preferredBackend: String?
    public let allowsFallback: Bool
    public let requiredExecutionClass: DicomCodecExecutionClass?
    public let requiredOutputOwnership: DicomCodecOutputOwnership?

    public init(
        operation: DicomCodecOperation,
        descriptor: DicomCompressedFrameDescriptor,
        intent: DicomEncodingIntent = .reversible,
        frameData: Data? = nil,
        partialDecode: DicomCodecPartialDecodeRequest? = nil,
        preferredBackend: String? = nil,
        allowsFallback: Bool = true,
        requiredExecutionClass: DicomCodecExecutionClass? = nil,
        requiredOutputOwnership: DicomCodecOutputOwnership? = nil
    ) {
        self.operation = operation
        self.descriptor = descriptor
        self.intent = intent
        self.frameData = frameData
        self.partialDecode = partialDecode
        self.preferredBackend = preferredBackend
        self.allowsFallback = allowsFallback
        self.requiredExecutionClass = requiredExecutionClass
        self.requiredOutputOwnership = requiredOutputOwnership
    }

    var decodeRequest: DicomFrameDecodeRequest {
        DicomFrameDecodeRequest(frameData: frameData ?? Data(), descriptor: descriptor, frameIndex: 0,
                                partialRequest: partialDecode)
    }
}
