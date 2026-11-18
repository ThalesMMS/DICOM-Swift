//
//  DicomRTContourGeometryReport.swift
//  DicomCore
//
//  Represents DICOM RT Contour Geometry Report metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public struct DicomRTContourGeometryReport: Equatable, Sendable {
    public let diagnostics: [DicomRTContourGeometryDiagnostic]
    public let limitations: [DicomRTContourGeometryDiagnostic]
    public var isConsistent: Bool { diagnostics.isEmpty && limitations.isEmpty }

    public init(diagnostics: [DicomRTContourGeometryDiagnostic], limitations: [DicomRTContourGeometryDiagnostic]) {
        self.diagnostics = diagnostics
        self.limitations = limitations
    }
}
