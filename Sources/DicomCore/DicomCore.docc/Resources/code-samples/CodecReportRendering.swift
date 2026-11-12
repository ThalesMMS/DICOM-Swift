//
//  CodecReportRendering.swift
//  DicomCore
//
//  Demonstrates Codec Report Rendering through the public DicomCore APIs.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import DicomCore
import Foundation

func renderCapabilities() throws -> String {
    let capabilityReport = DicomCodecWorkflowEngine().capabilities()
    return try DicomCodecCanonicalRenderer.jsonString(capabilityReport)
}
