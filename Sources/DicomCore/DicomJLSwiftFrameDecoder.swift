//
//  DicomJLSwiftFrameDecoder.swift
//  DicomCore
//

import Foundation

enum DicomJLSwiftFrameDecoder {
    typealias TelemetryReporter = @Sendable (DicomJLSwiftDecodeTelemetry) -> Void

    static func decode(
        _ request: DicomFrameDecodeRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        report: @escaping TelemetryReporter = { _ in }
    ) async throws -> DicomCodecDecodedFrame? {
        let mode = DicomJLSwiftRolloutMode(environment: environment)
        guard mode != .disabled else { return nil }

        let candidate = DicomJLSwiftBackend()
        let established = DicomCharLSFrameBackend(environment: environment)
        switch mode {
        case .disabled:
            return nil
        case .shadow:
            guard established.capabilities.unsupportedReason(for: request) == nil else {
                return nil
            }
            let production = try await timedDecode(
                established,
                request: request,
                mode: mode,
                report: report
            )
            Task.detached(priority: .utility) {
                let start = DispatchTime.now().uptimeNanoseconds
                do {
                    let shadow = try await candidate.decode(request)
                    report(DicomJLSwiftDecodeTelemetry(
                        mode: mode,
                        backend: candidate.capabilities.identifier,
                        durationNanoseconds: elapsed(since: start),
                        width: shadow.width,
                        height: shadow.height,
                        outcome: framesMatch(production, shadow) ? .matched : .mismatched
                    ))
                } catch {
                    report(DicomJLSwiftDecodeTelemetry(
                        mode: mode,
                        backend: candidate.capabilities.identifier,
                        durationNanoseconds: elapsed(since: start),
                        width: nil,
                        height: nil,
                        outcome: .failed(error.localizedDescription)
                    ))
                }
            }
            return production
        case .preferred:
            if let reason = candidate.capabilities.unsupportedReason(for: request) {
                return try await fallback(
                    established,
                    request: request,
                    mode: mode,
                    reason: reason,
                    report: report
                )
            }
            do {
                return try await timedDecode(candidate, request: request, mode: mode, report: report)
            } catch {
                return try await fallback(
                    established,
                    request: request,
                    mode: mode,
                    reason: error.localizedDescription,
                    report: report
                )
            }
        case .forcedForTests:
            return try await timedDecode(candidate, request: request, mode: mode, report: report)
        }
    }

    private static func fallback(
        _ backend: any DicomFrameCodecBackend,
        request: DicomFrameDecodeRequest,
        mode: DicomJLSwiftRolloutMode,
        reason: String,
        report: @escaping TelemetryReporter
    ) async throws -> DicomCodecDecodedFrame {
        guard backend.capabilities.unsupportedReason(for: request) == nil else {
            throw DicomCodecSelectionError.unsupported(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reasons: [reason, backend.capabilities.unsupportedReason(for: request) ?? "CharLS unavailable"]
            )
        }
        let frame = try await timedDecode(backend, request: request, mode: mode, report: report)
        report(DicomJLSwiftDecodeTelemetry(
            mode: mode,
            backend: backend.capabilities.identifier,
            durationNanoseconds: 0,
            width: frame.width,
            height: frame.height,
            outcome: .fellBack(reason)
        ))
        return frame
    }

    private static func timedDecode(
        _ backend: any DicomFrameCodecBackend,
        request: DicomFrameDecodeRequest,
        mode: DicomJLSwiftRolloutMode,
        report: @escaping TelemetryReporter
    ) async throws -> DicomCodecDecodedFrame {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let frame = try await backend.decode(request)
            report(DicomJLSwiftDecodeTelemetry(
                mode: mode,
                backend: backend.capabilities.identifier,
                durationNanoseconds: elapsed(since: start),
                width: frame.width,
                height: frame.height,
                outcome: .succeeded
            ))
            return frame
        } catch {
            report(DicomJLSwiftDecodeTelemetry(
                mode: mode,
                backend: backend.capabilities.identifier,
                durationNanoseconds: elapsed(since: start),
                width: nil,
                height: nil,
                outcome: .failed(error.localizedDescription)
            ))
            throw error
        }
    }

    private static func elapsed(since start: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds - start
    }

    private static func framesMatch(
        _ lhs: DicomCodecDecodedFrame,
        _ rhs: DicomCodecDecodedFrame
    ) -> Bool {
        lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.bitsPerSample == rhs.bitsPerSample
            && lhs.componentCount == rhs.componentCount
            && lhs.buffer.data == rhs.buffer.data
    }
}
