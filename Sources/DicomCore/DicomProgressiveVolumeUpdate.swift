import Foundation

/// A decoded volume paired with the progressive representation that produced it.
public struct DicomProgressiveVolumeUpdate: Sendable {
    /// Progressive ordering and quality metadata.
    public let layer: DicomProgressiveLayer
    /// Volume decoded from the cumulative representation.
    public let volume: DicomSeriesVolume

    /// Creates a progressive decoded-volume update.
    public init(layer: DicomProgressiveLayer, volume: DicomSeriesVolume) {
        self.layer = layer
        self.volume = volume
    }
}
