//
//  DicomPresentationStateDiagnostic.swift
//  DicomCore
//
//  Represents DICOM Presentation State Diagnostic metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomPresentationStateDiagnostic: Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
