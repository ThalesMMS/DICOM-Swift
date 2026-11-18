//
//  DicomCodecExecutionClass.swift
//  DicomCore
//
//  Processor that owns codec execution.
//
//  Thales Matheus Mendonça Santos — September 2026
//

import Foundation

/// Processor that owns codec execution.
public enum DicomCodecExecutionClass: String, Codable, Hashable, Sendable {
    case cpu
    case metal
}
