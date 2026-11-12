//
//  DicomSurfaceFlag.swift
//  DicomCore
//
//  Represents DICOM Surface Flag metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public enum DicomSurfaceFlag: String, Sendable {
    case yes = "YES"
    case no = "NO"
    case unknown = "UNKNOWN"
}
