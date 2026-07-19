//
//  DicomCharLSFrameBackend.swift
//  DicomCore
//

import Foundation

struct DicomCharLSFrameBackend: DicomFrameCodecBackend {
    let capabilities: DicomFrameCodecCapabilities

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let runtime = DicomCodecCapabilities.capability(for: .charLS, environment: environment)
        capabilities = DicomFrameCodecCapabilities(
            identifier: .charLSCPU,
            families: [.jpegLS],
            transferSyntaxUIDs: Set(runtime.transferSyntaxUIDs),
            encodeTransferSyntaxUIDs: Set(runtime.transferSyntaxUIDs),
            operations: [.decode, .encode],
            supportedGrayscaleBitDepths: runtime.supportedGrayscaleBitDepths,
            supportedColorBitDepths: runtime.supportedColorBitDepths,
            maximumComponents: 3,
            supportsSignedSamples: true,
            executionClass: .cpu,
            source: runtime.source,
            version: runtime.version,
            isAvailable: runtime.isAvailable,
            unsupportedReason: runtime.unsupportedReason
        )
    }

    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
        try Task.checkCancellation()
        if let reason = capabilities.unsupportedReason(for: request) {
            throw DicomCodecSelectionError.unsupported(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reasons: [reason]
            )
        }
        let decoded = try DicomJPEGLSCodec.decode(request.frameData)
        let descriptor = request.descriptor
        guard decoded.width == descriptor.columns, decoded.height == descriptor.rows,
              decoded.bitsPerSample == descriptor.bitsStored,
              decoded.componentCount == descriptor.samplesPerPixel else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "CharLS codestream metadata does not match the DICOM descriptor"
            )
        }
        try Self.validateNear(decoded.nearLossless, transferSyntaxUID: descriptor.transferSyntaxUID)
        return DicomCodecDecodedFrame(
            buffer: .owned(DicomJLSwiftBackend.normalizedSignedData(decoded.bytes, descriptor: descriptor)),
            width: decoded.width,
            height: decoded.height,
            bitsPerSample: decoded.bitsPerSample,
            componentCount: decoded.componentCount
        )
    }

    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data {
        try Task.checkCancellation()
        if let reason = capabilities.unsupportedReason(for: request.descriptor, operation: .encode) {
            throw DicomCodecSelectionError.unsupported(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reasons: [reason]
            )
        }
        guard request.targetTransferSyntaxUID == request.descriptor.transferSyntaxUID else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "the request descriptor names transfer syntax \(request.descriptor.transferSyntaxUID)"
            )
        }
        let frame = request.frame
        let descriptor = request.descriptor
        guard frame.width == descriptor.columns, frame.height == descriptor.rows,
              frame.bitsPerSample == descriptor.bitsStored,
              frame.componentCount == descriptor.samplesPerPixel else {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "the input frame shape does not match the DICOM descriptor"
            )
        }
        let near = try Self.nearParameter(
            for: request.intent,
            transferSyntaxUID: request.targetTransferSyntaxUID
        )
        return try DicomJPEGLSCodec.encode(
            bytes: frame.buffer.data,
            width: frame.width,
            height: frame.height,
            bitsPerSample: frame.bitsPerSample,
            componentCount: frame.componentCount,
            nearLossless: near
        )
    }

    private static func validateNear(_ near: Int, transferSyntaxUID: String) throws {
        if transferSyntaxUID == DicomTransferSyntax.jpegLSLossless.rawValue, near != 0 {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the lossless transfer syntax contains NEAR=\(near)"
            )
        }
        if transferSyntaxUID == DicomTransferSyntax.jpegLSNearLossless.rawValue, near == 0 {
            throw DicomJLSwiftBackendError.metadataMismatch(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the near-lossless transfer syntax contains NEAR=0"
            )
        }
    }

    private static func nearParameter(
        for intent: DicomEncodingIntent,
        transferSyntaxUID: String
    ) throws -> Int {
        switch (transferSyntaxUID, intent) {
        case (DicomTransferSyntax.jpegLSLossless.rawValue, .reversible):
            return 0
        case (DicomTransferSyntax.jpegLSNearLossless.rawValue, .jpegLSNearLossless(let near))
            where (1...255).contains(near):
            return near
        default:
            throw DicomJLSwiftBackendError.invalidEncodingIntent(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the transfer syntax requires matching reversible or explicit NEAR intent"
            )
        }
    }
}
