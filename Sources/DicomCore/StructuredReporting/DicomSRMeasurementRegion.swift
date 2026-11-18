//
//  DicomSRMeasurementRegion.swift
//  DicomCore
//
//  Represents DICOM SR Measurement Region metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public enum DicomSRMeasurementRegion: Equatable, Sendable {
    case none
    case imageRegion(DicomSRImageRegion)
    case imageRegions([DicomSRImageRegion])
    case volumeSurface([DicomSRVolumeSurface])
    case referencedSegmentationFrame(DicomSourceImageReference, sourceImages: [DicomSourceImageReference])
    case referencedSegment(DicomSourceImageReference, sourceImages: [DicomSourceImageReference], sourceSeriesUID: String?)
}
