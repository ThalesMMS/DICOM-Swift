//
//  DicomSRLanguage.swift
//  DicomCore
//
//  Represents DICOM SR Language metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomSRLanguage: Equatable, Sendable {
    public var code: DicomCodedConcept
    public var country: DicomCodedConcept?

    public init(
        code: DicomCodedConcept,
        country: DicomCodedConcept? = nil
    ) {
        self.code = code
        self.country = country
    }
}
