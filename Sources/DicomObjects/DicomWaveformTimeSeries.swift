import Foundation

/// A consumer-facing signal. Times are seconds on a common relative time axis.
/// nil samples represent unavailable measurements; units are a displayable symbol.
public struct DicomWaveformTimeSeries: Equatable, Sendable {
    public let startTime: Double
    public let samplingFrequency: Double
    public let physicalSamples: [Double?]
    public let units: String?

    public init(startTime: Double, samplingFrequency: Double, physicalSamples: [Double?], units: String?) {
        self.startTime = startTime
        self.samplingFrequency = samplingFrequency
        self.physicalSamples = physicalSamples
        self.units = units
    }
}
