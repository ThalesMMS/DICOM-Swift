import Foundation

/// Metadata that orders and qualifies one cumulative progressive image representation.
public struct DicomProgressiveLayer: Sendable, Equatable {
    /// Zero-based requested quality-layer index.
    public let index: Int
    /// Number of updates requested for this sequence, when known.
    public let totalLayerCount: Int?
    /// Presentation role of this update.
    public let quality: DicomProgressiveUpdateQuality
    /// Byte range occupied by the complete representation in its response.
    public let byteRange: Range<Int>?
    /// Normalized completion estimate for the requested sequence.
    public let fractionComplete: Double
    /// Whether this is the last update requested by the client.
    public let isFinal: Bool

    /// Creates metadata for a cumulative progressive image update.
    public init(
        index: Int,
        totalLayerCount: Int? = nil,
        quality: DicomProgressiveUpdateQuality,
        byteRange: Range<Int>? = nil,
        fractionComplete: Double,
        isFinal: Bool
    ) {
        self.index = index
        self.totalLayerCount = totalLayerCount
        self.quality = quality
        self.byteRange = byteRange
        self.fractionComplete = fractionComplete
        self.isFinal = isFinal
    }
}
