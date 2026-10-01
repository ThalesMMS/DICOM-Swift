import Foundation

public struct DicomSRDerivedMeasurement: Equatable, Sendable {
    public enum GroupReference: Equatable, Sendable { case trackingUID(String), index(Int) }
    public var measurement: DicomSRMeasurementValue
    public var groups: [GroupReference]

    public init(
        measurement: DicomSRMeasurementValue,
        groups: [GroupReference]
    ) {
        self.measurement = measurement
        self.groups = groups
    }
}
