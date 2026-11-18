//
//  DicomPlacementError.swift
//  DicomCore
//
//  Describes failures reported during DICOM Placement operations.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public enum DicomPlacementError: Error, Equatable, Sendable {
    case invalidTransition(from: DicomObjectPlacement.State, to: DicomObjectPlacement.State)
    case unknownProvider(String)
    case quotaExceeded(String)
    case journal(String)
}
