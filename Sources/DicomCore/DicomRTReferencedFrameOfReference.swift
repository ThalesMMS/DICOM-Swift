//
//  DicomRTReferencedFrameOfReference.swift
//  DicomCore
//
//  Represents DICOM RT Referenced Frame Of Reference metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public struct DicomRTReferencedFrameOfReference: Equatable, Sendable {
    public let frameOfReferenceUID: String
    public let studies: [DicomRTReferencedStudy]

    public init(frameOfReferenceUID: String, studies: [DicomRTReferencedStudy] = []) {
        self.frameOfReferenceUID = frameOfReferenceUID
        self.studies = studies
    }
}
