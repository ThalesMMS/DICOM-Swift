//
//  CodecInspect.swift
//  DicomCore
//
//  Demonstrates Codec Inspect through the public DicomCore APIs.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import DicomCore
import Foundation

func inspect(_ data: Data) throws -> DicomCodecStructuredReport {
    let report = try DicomCodecWorkflowEngine().inspect(data)
    print(DicomCodecCanonicalRenderer.text(report))
    return report
}
