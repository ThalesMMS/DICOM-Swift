//
//  DicomCodecArtifactResult.swift
//  DicomCore
//

import Foundation

/// In-memory bytes plus their canonical codec workflow report.
public struct DicomCodecArtifactResult: Sendable {
    /// Generated in-memory artifact bytes.
    public let data: Data
    /// Canonical semantic report describing how the artifact was produced and validated.
    public let report: DicomCodecStructuredReport

    /// Creates an artifact result from bytes and their canonical report.
    public init(data: Data, report: DicomCodecStructuredReport) {
        self.data = data
        self.report = report
    }
}
