//
//  DicomSegmentationSegmentAttribution.swift
//  DicomCore
//
//  LABELMAP frames carry all segments and use `unattributed` with segmentNumber zero. For
//  BINARY/FRACTIONAL, `unattributed` indicates a missing or unknown segment reference.
//
//  Thales Matheus Mendonça Santos — September 2026
//

/// LABELMAP frames carry all segments and use `unattributed` with segmentNumber zero.
/// For BINARY/FRACTIONAL, `unattributed` indicates a missing or unknown segment reference.
public enum DicomSegmentationSegmentAttribution: Equatable, Sendable {
    case declared
    case inferredSingleSegment
    case unattributed
}
