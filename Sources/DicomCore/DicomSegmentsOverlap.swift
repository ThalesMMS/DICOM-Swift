//
//  DicomSegmentsOverlap.swift
//  DicomCore
//
//  Segments Overlap (0062,0013).
//
//  Thales Matheus Mendonça Santos — September 2026
//

/// Segments Overlap (0062,0013).
public enum DicomSegmentsOverlap: String, Equatable, Sendable {
    case yes = "YES"
    case undefined = "UNDEFINED"
    case no = "NO"
}
