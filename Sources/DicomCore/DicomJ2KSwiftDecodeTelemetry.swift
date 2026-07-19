//
//  DicomJ2KSwiftDecodeTelemetry.swift
//  DicomCore
//

struct DicomJ2KSwiftDecodeTelemetry: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case succeeded
        case matched
        case mismatched
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
