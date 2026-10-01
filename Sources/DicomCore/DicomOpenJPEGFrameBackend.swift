//
//  DicomOpenJPEGFrameBackend.swift
//  DicomCore
//

import Foundation

struct DicomOpenJPEGFrameBackend: DicomFrameCodecBackend {
    let capabilities: DicomFrameCodecCapabilities
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
        let runtimeCapability = DicomCodecCapabilities.capability(for: .openJPEG, environment: environment)
        let availableSyntaxes: Set<String>
        if runtimeCapability.isAvailable,
           DicomJPEG2000Codec.htj2kUnsupportedReason(
               runtimeAvailable: true,
               runtimeMessage: runtimeCapability.unsupportedReason ?? "OpenJPEG is available.",
               version: runtimeCapability.version
           ) == nil {
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
            version: runtimeCapability.version,
            isAvailable: runtimeCapability.isAvailable,
            unsupportedReason: runtimeCapability.isAvailable
                ? nil
                : runtimeCapability.unsupportedReason ?? "OpenJPEG runtime library is unavailable."
        )
    }

    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
        try Task.checkCancellation()
        let decoded = try await DicomCancellableDetachedOperation.run {
            try DicomJPEG2000Codec.decode(request.frameData, environment: environment)
        }
        return DicomCodecDecodedFrame(
            buffer: .owned(decoded.bytes),
            width: decoded.width,
            height: decoded.height,
            bitsPerSample: decoded.bitsPerSample,
            componentCount: decoded.componentCount
        )
    }
}
