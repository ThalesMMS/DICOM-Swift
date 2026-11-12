//
//  DicomJLSwiftDecodeTelemetry.swift
//  DicomCore
//
//  Records DICOM JL Swift Decode outcomes and timing information.
//
//  Thales Matheus Mendonça Santos — July 2026
//

struct DicomJLSwiftDecodeTelemetry: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case skipped(String)
        case succeeded
        case matched
        case mismatched
        case cancelled
        case failed(String)
        case fellBack(String)
    }

    let mode: DicomJLSwiftRolloutMode
    let backend: DicomCodecBackendIdentifier
    let durationNanoseconds: UInt64
    let width: Int?
    let height: Int?
    let outcome: Outcome
}
