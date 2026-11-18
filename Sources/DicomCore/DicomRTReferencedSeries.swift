//
//  DicomRTReferencedSeries.swift
//  DicomCore
//
//  Represents DICOM RT Referenced Series metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public struct DicomRTReferencedSeries: Equatable, Sendable {
    public let seriesInstanceUID: String
    public let instances: [DicomSourceImageReference]

    public init(seriesInstanceUID: String, instances: [DicomSourceImageReference] = []) {
        self.seriesInstanceUID = seriesInstanceUID
        self.instances = instances
    }
}
