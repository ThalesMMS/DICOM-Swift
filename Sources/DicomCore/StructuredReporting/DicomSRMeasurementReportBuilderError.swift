//
//  DicomSRMeasurementReportBuilderError.swift
//  DicomCore
//
//  Describes failures reported during DICOM SR Measurement Report Builder operations.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public enum DicomSRMeasurementReportBuilderError: Error, Equatable, Sendable {
    case byReferenceRequiresComprehensive
    case scoord3DRequiresComprehensive3D
    case unsupportedSOPClass
    case missingTrackingUID
    case invalidGroupReference
    case conflictingNumericRepresentations
    case invalidTemplate([DicomSRTemplateDiagnostic])
}
