//
//  DicomSurfaceVectorSet.swift
//  DicomCore
//
//  Represents DICOM Surface Vector Set metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public struct DicomSurfaceVectorSet: Equatable, Sendable {
    public let dimensionality: Int
    public let coordinates: [Float]
    public let accuracy: [Float]?

    public init(dimensionality: Int = 3, coordinates: [Float], accuracy: [Float]? = nil) {
        self.dimensionality = dimensionality
        self.coordinates = coordinates
        self.accuracy = accuracy
    }
}
