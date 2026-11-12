//
//  DicomSRMeasurementSource.swift
//  DicomCore
//
//  Represents DICOM SR Measurement Source metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public enum DicomSRMeasurementSource: Equatable, Sendable {
    case image(DicomSourceImageReference)
    case scoord(DicomSRImageRegion)
    case scoord3D(DicomSRVolumeSurface)
}
