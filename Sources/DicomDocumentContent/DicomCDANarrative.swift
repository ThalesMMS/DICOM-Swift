//
//  DicomCDANarrative.swift
//  DicomDocumentContent
//
//  Represents DICOM CDA Narrative metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomCDANarrative: Equatable, Sendable {
    public let title: String
    public let sections: [DicomCDASection]
    public let hasStructuredBody: Bool
}
