//
//  DicomEncapsulatedDocumentDiagnostic.swift
//  DicomCore
//
//  Represents DICOM Encapsulated Document Diagnostic metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomEncapsulatedDocumentDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case mimeMismatch, lengthMismatch, missingMIMEList, missingHL7Identifier, missingModelUnits
        case missingFrameOfReference, missingEquipment, modalityMismatch, invalidRelativeURI
    }
    public let code: Code
    public let reason: String

    public init(code: Code, reason: String) {
        self.code = code
        self.reason = reason
    }
}
