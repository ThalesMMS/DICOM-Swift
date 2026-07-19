//
//  DicomJXLSwiftFrameDecoder.swift
//  DicomCore
//

import Foundation

enum DicomJXLSwiftFrameDecoder {
    typealias TelemetryReporter = @Sendable (DicomJXLSwiftDecodeTelemetry) -> Void

    static func decode(
        _ request: DicomFrameDecodeRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        report: @escaping TelemetryReporter = { _ in }
    ) async throws -> DicomCodecDecodedFrame? {
        guard DicomJXLSwiftRolloutMode(environment: environment) != .disabled else {
            return nil
        }
        let start = Date()
        do {
            let frame = try await DicomJXLSwiftBackend().decode(request)
            report(DicomJXLSwiftDecodeTelemetry(
                frameIndex: request.frameIndex,
                compressedBytes: request.frameData.count,
                decodedBytes: frame.buffer.data.count,
                compressionRatio: request.frameData.isEmpty
                    ? 0
                    : Double(frame.buffer.data.count) / Double(request.frameData.count),
                duration: Date().timeIntervalSince(start),
                reconstructedJPEG: request.descriptor.transferSyntaxUID
                    == DicomTransferSyntax.jpegXLJPEGRecompression.rawValue,
                succeeded: true
            ))
            return frame
        } catch {
            report(DicomJXLSwiftDecodeTelemetry(
                frameIndex: request.frameIndex,
                compressedBytes: request.frameData.count,
                decodedBytes: 0,
                compressionRatio: 0,
                duration: Date().timeIntervalSince(start),
                reconstructedJPEG: request.descriptor.transferSyntaxUID
                    == DicomTransferSyntax.jpegXLJPEGRecompression.rawValue,
                succeeded: false
            ))
            throw error
        }
    }
}
