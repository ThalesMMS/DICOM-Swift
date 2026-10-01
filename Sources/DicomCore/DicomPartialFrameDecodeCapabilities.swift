import Foundation

/// Partial-decode operations qualified for one compressed frame codestream.
public struct DicomPartialFrameDecodeCapabilities: Sendable, Equatable {
    /// Whether direct source-space region decode is available.
    public let supportsRegion: Bool
    /// Whether direct reduced-resolution decode is available.
    public let supportsResolutionReduction: Bool
    /// Whether cumulative quality-layer decode is available.
    public let supportsQualityLayers: Bool
    /// Whether region and reduced-resolution decode can be combined.
    public let supportsCombinedRegionAndResolution: Bool
    /// Whether a quality layer can be combined with a spatial partial request.
    public let supportsQualityWithSpatialReduction: Bool
    /// Largest supported number of power-of-two resolution reductions.
    public let maximumResolutionReductionLevel: Int?
    /// Number of quality layers declared by the codestream.
    public let qualityLayerCount: Int?
    /// Packet bytes per quality layer when a tier-2 index was taken (`DicomDecodedFrameReader.qualityLayerIndex`);
    /// nil for the header-only probe. The fraction of the first layer is the incremental-cost signal a consumer
    /// uses before scheduling a low-layer preview (issue #2382).
    public let qualityLayerByteTotals: [Int]?

    /// Creates an explicit capability report.
    public init(
        supportsRegion: Bool,
        supportsResolutionReduction: Bool,
        supportsQualityLayers: Bool,
        supportsCombinedRegionAndResolution: Bool,
        supportsQualityWithSpatialReduction: Bool,
        maximumResolutionReductionLevel: Int?,
        qualityLayerCount: Int?,
        qualityLayerByteTotals: [Int]? = nil
    ) {
        self.supportsRegion = supportsRegion
        self.supportsResolutionReduction = supportsResolutionReduction
        self.supportsQualityLayers = supportsQualityLayers
        self.supportsCombinedRegionAndResolution = supportsCombinedRegionAndResolution
        self.supportsQualityWithSpatialReduction = supportsQualityWithSpatialReduction
        self.maximumResolutionReductionLevel = maximumResolutionReductionLevel
        self.qualityLayerCount = qualityLayerCount
        self.qualityLayerByteTotals = qualityLayerByteTotals
    }

    /// Fraction of the packet bytes held by layers `0...layer`, when the index exists.
    public func byteFraction(throughLayer layer: Int) -> Double? {
        guard let totals = qualityLayerByteTotals, totals.indices.contains(layer) else { return nil }
        let total = totals.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(totals.prefix(layer + 1).reduce(0, +)) / Double(total)
    }

    /// Capability report for a syntax or runtime without direct partial decode.
    public static let unavailable = DicomPartialFrameDecodeCapabilities(
        supportsRegion: false,
        supportsResolutionReduction: false,
        supportsQualityLayers: false,
        supportsCombinedRegionAndResolution: false,
        supportsQualityWithSpatialReduction: false,
        maximumResolutionReductionLevel: nil,
        qualityLayerCount: nil
    )
}
