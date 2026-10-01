import Foundation

/// One complete, cumulative JPEG 2000 or HTJ2K image entity returned by JPIP.
public struct DicomJPIPLayerPayload: Sendable, Equatable {
    /// Progressive ordering and quality metadata.
    public let layer: DicomProgressiveLayer
    /// Complete image entity suitable for the caller's JPEG 2000 or HTJ2K decoder.
    public let data: Data
    /// Normalized response media type without parameters.
    public let mediaType: String?

    public let reconstructionInfo: DicomJPIPReconstructionInfo?

    /// Creates a cumulative JPIP layer payload.
    public init(layer: DicomProgressiveLayer, data: Data, mediaType: String? = nil,
                reconstructionInfo: DicomJPIPReconstructionInfo? = nil) {
        self.layer = layer
        self.data = data
        self.mediaType = mediaType
        self.reconstructionInfo = reconstructionInfo
    }
}
