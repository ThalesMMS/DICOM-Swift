//
//  CodecValidate.swift
//  DicomCore
//
//  Demonstrates Codec Validate through the public DicomCore APIs.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import DicomCore
import Foundation

func validate(_ data: Data) throws -> DicomCodecStructuredReport {
    let report = try DicomCodecWorkflowEngine().validate(data)
    if !report.success {
        for diagnostic in report.diagnostics where diagnostic.severity == .error {
            print("\(diagnostic.code): \(diagnostic.message)")
        }
    }
    return report
}
