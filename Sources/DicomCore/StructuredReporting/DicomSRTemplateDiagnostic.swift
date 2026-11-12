//
//  DicomSRTemplateDiagnostic.swift
//  DicomCore
//
//  Represents DICOM SR Template Diagnostic metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomSRTemplateDiagnostic: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case missingMandatory, cardinality, conceptMismatch, valueTypeMismatch, relationshipMismatch
        case unitsMismatch, conditionViolated, notExtensibleExtraItem, byReferenceNotPermitted
        case byReferenceUnresolved, includeMissing, templateUnknown, contextGroupNotChecked
        case customConditionNotEvaluated, definedTermSubstituted, extraItem
    }
    public let templateIdentifier: String
    public let rowID: String
    /// Zero-based content path; the document root is [].
    public let path: [Int]
    public let kind: Kind
    public let message: String
}
