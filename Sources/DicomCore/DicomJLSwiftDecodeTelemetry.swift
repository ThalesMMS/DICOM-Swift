//
//  DicomJLSwiftDecodeTelemetry.swift
//  DicomCore
//

struct DicomJLSwiftDecodeTelemetry: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case succeeded
        case matched
        case mismatched
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
