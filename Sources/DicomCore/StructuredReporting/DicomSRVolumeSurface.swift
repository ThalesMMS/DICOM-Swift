//
//  DicomSRVolumeSurface.swift
//  DicomCore
//
//  Represents DICOM SR Volume Surface metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomSRVolumeSurface: Equatable, Sendable {
    public var graphicType: String
    public var data: [Double]
    public var frameOfReferenceUID: String

    public init(
        graphicType: String,
        data: [Double],
        frameOfReferenceUID: String
    ) {
        self.graphicType = graphicType
        self.data = data
        self.frameOfReferenceUID = frameOfReferenceUID
    }
}
