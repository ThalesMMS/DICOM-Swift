//
//  DicomRTContourGeometricType.swift
//  DicomCore
//
//  Represents DICOM RT Contour Geometric Type metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public enum DicomRTContourGeometricType: String, CaseIterable, Sendable {
    case point = "POINT"
    case openPlanar = "OPEN_PLANAR"
    case openNonplanar = "OPEN_NONPLANAR"
    case closedPlanar = "CLOSED_PLANAR"
    case closedPlanarXOR = "CLOSEDPLANAR_XOR"
}
