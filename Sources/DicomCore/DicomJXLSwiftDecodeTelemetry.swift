//
//  DicomJXLSwiftDecodeTelemetry.swift
//  DicomCore
//

import Foundation

struct DicomJXLSwiftDecodeTelemetry: Equatable, Sendable {
    let frameIndex: Int
    let compressedBytes: Int
    let decodedBytes: Int
    let compressionRatio: Double
    let duration: TimeInterval
    let reconstructedJPEG: Bool
    let succeeded: Bool
}
