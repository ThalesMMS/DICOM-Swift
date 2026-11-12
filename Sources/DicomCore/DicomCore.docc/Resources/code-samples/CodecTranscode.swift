//
//  CodecTranscode.swift
//  DicomCore
//
//  Demonstrates Codec Transcode through the public DicomCore APIs.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import DicomCore
import Foundation

func rewriteAsImplicitVR(_ data: Data) async throws -> DicomCodecArtifactResult {
    try await DicomCodecWorkflowEngine().transcode(
        data,
        to: .implicitVRLittleEndian,
        intent: .reversible,
        verifyDecodedPixels: true
    )
}

func encodeResolutionLayers(_ data: Data) async throws -> DicomCodecArtifactResult {
    try await DicomCodecWorkflowEngine().transcode(
        data,
        to: .jpeg2000Lossless,
        jpeg2000Options: DicomJPEG2000EncodingOptions(
            qualityLayers: 3, decompositionLevels: 3, progression: .rlcp
        )
    )
}
