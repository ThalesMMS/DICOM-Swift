import Foundation

/// Codec-neutral request for spatial, resolution, or quality-layer frame decode.
public struct DicomPartialFrameDecodeRequest: Sendable, Equatable, Hashable {
    /// Optional region in full-resolution source coordinates.
    public let sourceRegion: DicomFrameRegion?
    /// Number of power-of-two resolution reductions, where zero means full resolution.
    public let resolutionReductionLevel: Int
    /// Highest cumulative quality layer to decode, where zero is the first layer.
    public let maximumQualityLayer: Int?
    /// Whether provisional quality must be rejected.
    public let requiresFinalQuality: Bool

    /// Creates and validates a partial frame request.
    public init(
        sourceRegion: DicomFrameRegion? = nil,
        resolutionReductionLevel: Int = 0,
        maximumQualityLayer: Int? = nil,
        requiresFinalQuality: Bool = false
    ) throws {
        guard resolutionReductionLevel >= 0 else {
            throw DicomPartialFrameDecodeError.invalidResolutionReductionLevel(
                requested: resolutionReductionLevel,
                maximum: 0
            )
        }
        if let maximumQualityLayer, maximumQualityLayer < 0 {
            throw DicomPartialFrameDecodeError.invalidQualityLayer(requested: maximumQualityLayer, count: 0)
        }
        if let sourceRegion, sourceRegion.width <= 0 || sourceRegion.height <= 0 {
            throw DicomPartialFrameDecodeError.invalidRegion
        }

        self.sourceRegion = sourceRegion
        self.resolutionReductionLevel = resolutionReductionLevel
        self.maximumQualityLayer = maximumQualityLayer
        self.requiresFinalQuality = requiresFinalQuality
    }
}
