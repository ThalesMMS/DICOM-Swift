//
//  DicomRTReferencedStudy.swift
//  DicomCore
//
//  Represents DICOM RT Referenced Study metadata and state.
//
//  Thales Matheus Mendonça Santos — September 2026
//

public struct DicomRTReferencedStudy: Equatable, Sendable {
    public let referencedSOPClassUID: String?
    public let referencedSOPInstanceUID: String?
    public let series: [DicomRTReferencedSeries]

    public init(referencedSOPClassUID: String? = nil, referencedSOPInstanceUID: String? = nil,
                series: [DicomRTReferencedSeries] = []) {
        self.referencedSOPClassUID = referencedSOPClassUID
        self.referencedSOPInstanceUID = referencedSOPInstanceUID
        self.series = series
    }
}
