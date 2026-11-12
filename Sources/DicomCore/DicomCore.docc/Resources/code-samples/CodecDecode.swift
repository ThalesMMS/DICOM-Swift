//
//  CodecDecode.swift
//  DicomCore
//
//  Demonstrates Codec Decode through the public DicomCore APIs.
//
//  Thales Matheus Mendonça Santos — August 2026
//

import DicomCore
import Foundation

func decodeFirstFrame(_ data: Data) async throws -> DicomCodecArtifactResult {
    try await DicomCodecWorkflowEngine().decode(data, frameIndexes: [0])
}
