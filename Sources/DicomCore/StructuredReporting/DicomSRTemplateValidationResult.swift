//
//  DicomSRTemplateValidationResult.swift
//  DicomCore
//
//  Represents DICOM SR Template Validation Result metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomSRTemplateValidationResult: Equatable, Sendable {
    public var errors: [DicomSRTemplateDiagnostic] = []
    public var limitations: [DicomSRTemplateDiagnostic] = []
    public var informational: [DicomSRTemplateDiagnostic] = []
    public var isValid: Bool { errors.isEmpty }

    public init() {}
}
