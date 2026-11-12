//
//  DicomSRDerivedMeasurement.swift
//  DicomCore
//
//  Represents DICOM SR Derived Measurement metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

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
