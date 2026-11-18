//
//  DicomSRQualitativeEvaluation.swift
//  DicomCore
//
//  Represents DICOM SR Qualitative Evaluation metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public enum DicomSRQualitativeEvaluation: Equatable, Sendable {
    case code(concept: DicomCodedConcept, value: DicomCodedConcept)
    case text(concept: DicomCodedConcept, text: String)
}
