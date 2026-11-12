//
//  DicomSurfaceSegmentationReport.swift
//  DicomCore
//
//  Represents DICOM Surface Segmentation Report metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public struct DicomSurfaceSegmentationReport: Equatable, Sendable {
    public let diagnostics: [DicomSurfaceSegmentationDiagnostic]
    public var isConsistent: Bool { diagnostics.isEmpty }
}
