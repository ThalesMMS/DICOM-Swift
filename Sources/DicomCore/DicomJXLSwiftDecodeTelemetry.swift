//
//  DicomJXLSwiftDecodeTelemetry.swift
//  DicomCore
//
//  Records DICOM JPEG XL Swift Decode outcomes and timing information.
//
//  Thales Matheus Mendonça Santos — July 2026
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
