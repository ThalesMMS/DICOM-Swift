//
//  CodecCompare.swift
//  DicomCore
//
//  Demonstrates Codec Compare through the public DicomCore APIs.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import DicomCore
import Foundation

func compareFirstFrame(_ compressedData: Data) async throws -> DicomCodecStructuredReport {
    let report = try await DicomCodecWorkflowEngine().compare(compressedData, frameIndex: 0)
    if !report.success {
        print(DicomCodecCanonicalRenderer.text(report))
    }
    return report
}
