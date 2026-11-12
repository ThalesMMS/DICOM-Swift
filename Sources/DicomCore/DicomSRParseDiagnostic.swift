//
//  DicomSRParseDiagnostic.swift
//  DicomCore
//
//  Represents DICOM SR Parse Diagnostic metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomSRParseDiagnostic: Equatable, Sendable {
    public let path: [Int]
    public let code: String
    public let message: String

    public init(path: [Int], code: String, message: String) {
        self.path = path
        self.code = code
        self.message = message
    }
}
