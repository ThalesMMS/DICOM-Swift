//
//  DicomSRFindingSite.swift
//  DicomCore
//
//  Represents DICOM SR Finding Site metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

public struct DicomSRFindingSite: Equatable, Sendable {
    public var site: DicomCodedConcept
    public var laterality: DicomCodedConcept?
    public var modifier: DicomCodedConcept?

    public init(
        site: DicomCodedConcept,
        laterality: DicomCodedConcept? = nil,
        modifier: DicomCodedConcept? = nil
    ) {
        self.site = site
        self.laterality = laterality
        self.modifier = modifier
    }
}
