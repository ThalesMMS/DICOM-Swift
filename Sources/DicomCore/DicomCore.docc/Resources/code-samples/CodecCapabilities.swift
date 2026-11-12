//
//  CodecCapabilities.swift
//  DicomCore
//
//  Demonstrates Codec Capabilities through the public DicomCore APIs.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import DicomCore
import Foundation

func reportCapabilities() throws {
    let engine = DicomCodecWorkflowEngine()
    let capabilityReport = engine.capabilities()
    let availableBackends = capabilityReport.backends.filter(\.available)
    print(availableBackends.map(\.identifier))
}
