//
//  DicomOpenJPEGFrameBackend.swift
//  DicomCore
//

import Foundation

struct DicomOpenJPEGFrameBackend: DicomFrameCodecBackend {
    let capabilities: DicomFrameCodecCapabilities

    init() {
        let runtimeCapability = DicomCodecCapabilities.capability(for: .openJPEG)
        let availableSyntaxes: Set<String>
        if DicomJPEG2000Codec.supportsHTJ2K {
            availableSyntaxes = DicomJ2KSwiftBackend.allFrameTransferSyntaxes
        } else {
            availableSyntaxes = [
                DicomTransferSyntax.jpeg2000Lossless.rawValue,
                DicomTransferSyntax.jpeg2000.rawValue
            ]
        }
        capabilities = DicomFrameCodecCapabilities(
            identifier: .openJPEGCPU,
            families: [.jpeg2000, .htj2k],
            transferSyntaxUIDs: availableSyntaxes,
            supportedGrayscaleBitDepths: 1...16,
            supportedColorBitDepths: 1...8,
            maximumComponents: 3,
            supportsSignedSamples: true,
            executionClass: .cpu,
            source: runtimeCapability.source,
            version: DicomJPEG2000Codec.version,
            isAvailable: DicomJPEG2000Codec.isAvailable,
            unsupportedReason: DicomJPEG2000Codec.isAvailable
                ? nil
                : "OpenJPEG runtime library is unavailable."
        )
    }

    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
        let decoded = try await Task.detached(priority: .userInitiated) {
            try DicomJPEG2000Codec.decode(request.frameData)
        }.value
        return DicomCodecDecodedFrame(
            buffer: .owned(decoded.bytes),
            width: decoded.width,
            height: decoded.height,
            bitsPerSample: decoded.bitsPerSample,
            componentCount: decoded.componentCount
        )
    }
}
