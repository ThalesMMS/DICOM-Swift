//
//  DCMDecoder+Metadata.swift
//  DicomCore
//
//  Structured metadata helpers for DCMDecoder.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

extension DCMDecoder {

    /// Returns all available DICOM tags as a dictionary
    /// - Returns: Dictionary of tag hex string to value
    public func getAllTags() -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: allTagKeys().map { tag in
                (String(format: "%08X", tag), info(for: tag))
            }
        )
    }

    /// Returns patient demographics in a structured format
    /// - Returns: Dictionary with patient information
    public func getPatientInfo() -> [String: String] {
        [
            "Name": info(for: DicomTag.patientName.rawValue),
            "ID": info(for: DicomTag.patientID.rawValue),
            "Sex": info(for: DicomTag.patientSex.rawValue),
            "Age": info(for: DicomTag.patientAge.rawValue)
        ]
    }

    /// Returns study information in a structured format
    /// - Returns: Dictionary with study information
    public func getStudyInfo() -> [String: String] {
        [
            "StudyInstanceUID": info(for: DicomTag.studyInstanceUID.rawValue),
            "StudyID": info(for: DicomTag.studyID.rawValue),
            "StudyDate": info(for: DicomTag.studyDate.rawValue),
            "StudyTime": info(for: DicomTag.studyTime.rawValue),
            "StudyDescription": info(for: DicomTag.studyDescription.rawValue),
            "ReferringPhysician": info(for: DicomTag.referringPhysicianName.rawValue)
        ]
    }

    /// Returns series information in a structured format
    /// - Returns: Dictionary with series information
    public func getSeriesInfo() -> [String: String] {
        [
            "SeriesInstanceUID": info(for: DicomTag.seriesInstanceUID.rawValue),
            "SeriesNumber": info(for: DicomTag.seriesNumber.rawValue),
            "SeriesDate": info(for: DicomTag.seriesDate.rawValue),
            "SeriesTime": info(for: DicomTag.seriesTime.rawValue),
            "SeriesDescription": info(for: DicomTag.seriesDescription.rawValue),
            "Modality": info(for: DicomTag.modality.rawValue)
        ]
    }
}
