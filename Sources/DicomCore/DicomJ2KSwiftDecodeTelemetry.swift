//
//  DicomJ2KSwiftDecodeTelemetry.swift
//  DicomCore
//
//  Records DICOM JPEG 2000 Swift Decode outcomes and timing information.
//
//  Thales Matheus Mendonça Santos — July 2026
//

struct DicomJ2KSwiftDecodeTelemetry: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case skipped(String)
        case succeeded
        case matched
        case mismatched
        case cancelled
        case failed(String)
        case fellBack(String)
    }

    let mode: DicomJ2KSwiftRolloutMode
    let backend: DicomCodecBackendIdentifier
    let durationNanoseconds: UInt64
    let width: Int?
    let height: Int?
    let outcome: Outcome
}
