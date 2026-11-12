//
//  DicomSRImageRegion.swift
//  DicomCore
//
//  Represents DICOM SR Image Region metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomSRImageRegion: Equatable, Sendable {
    public var graphicType: String
    public var data: [Double]
    public var image: DicomSourceImageReference

    public init(
        graphicType: String,
        data: [Double],
        image: DicomSourceImageReference
    ) {
        self.graphicType = graphicType
        self.data = data
        self.image = image
    }
}
