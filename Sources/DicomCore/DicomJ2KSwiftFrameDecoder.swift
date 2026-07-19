//
//  DicomJ2KSwiftFrameDecoder.swift
//  DicomCore
//

import Foundation

enum DicomJ2KSwiftFrameDecoder {
    typealias TelemetryReporter = @Sendable (DicomJ2KSwiftDecodeTelemetry) -> Void

    static func decode(
        _ request: DicomFrameDecodeRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        report: @escaping TelemetryReporter = { _ in }
    ) async throws -> DicomCodecDecodedFrame? {
        let mode = DicomJ2KSwiftRolloutMode(environment: environment)
        guard mode != .disabled else { return nil }

        let candidate = DicomJ2KSwiftBackend()
        let established = DicomOpenJPEGFrameBackend()
        if request.partialRequest != nil {
            if let reason = candidate.capabilities.unsupportedReason(for: request) {
                throw DicomCodecSelectionError.unsupported(
                    transferSyntaxUID: request.descriptor.transferSyntaxUID,
                    reasons: [reason]
                )
            }
            return try await timedDecode(
                candidate,
                request: request,
                mode: mode,
                report: report
            )
        }
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
                let shadowStart = DispatchTime.now().uptimeNanoseconds
                do {
                    let shadow = try await candidate.decode(request)
                    let outcome: DicomJ2KSwiftDecodeTelemetry.Outcome =
                        framesMatch(production, shadow) ? .matched : .mismatched
                    report(DicomJ2KSwiftDecodeTelemetry(
                        mode: mode,
                        backend: candidate.capabilities.identifier,
                        durationNanoseconds: elapsed(since: shadowStart),
                        width: shadow.width,
                        height: shadow.height,
                        outcome: outcome
                    ))
                } catch {
                    report(DicomJ2KSwiftDecodeTelemetry(
                        mode: mode,
                        backend: candidate.capabilities.identifier,
                        durationNanoseconds: elapsed(since: shadowStart),
                        width: nil,
                        height: nil,
                        outcome: .failed(error.localizedDescription)
                    ))
                }
            }
            return production
        case .preferred:
            if let qualificationReason = candidate.capabilities.unsupportedReason(for: request) {
                guard established.capabilities.unsupportedReason(for: request) == nil else {
                    throw DicomCodecSelectionError.unsupported(
                        transferSyntaxUID: request.descriptor.transferSyntaxUID,
                        reasons: [qualificationReason]
                    )
                }
                let fallback = try await timedDecode(
                    established,
                    request: request,
                    mode: mode,
                    report: report
                )
                report(DicomJ2KSwiftDecodeTelemetry(
                    mode: mode,
                    backend: established.capabilities.identifier,
                    durationNanoseconds: 0,
                    width: fallback.width,
                    height: fallback.height,
                    outcome: .fellBack(qualificationReason)
                ))
                return fallback
            }
            do {
                return try await timedDecode(
                    candidate,
                    request: request,
                    mode: mode,
                    report: report
                )
            } catch {
                let candidateError = error.localizedDescription
                guard established.capabilities.unsupportedReason(for: request) == nil else {
                    throw error
                }
                let fallback = try await timedDecode(
                    established,
                    request: request,
                    mode: mode,
                    report: report
                )
                report(DicomJ2KSwiftDecodeTelemetry(
                    mode: mode,
                    backend: established.capabilities.identifier,
                    durationNanoseconds: 0,
                    width: fallback.width,
                    height: fallback.height,
                    outcome: .fellBack(candidateError)
                ))
                return fallback
            }
        case .forcedForTests:
            return try await timedDecode(
                candidate,
                request: request,
                mode: mode,
                report: report
            )
        }
    }

    private static func timedDecode(
        _ backend: any DicomFrameCodecBackend,
        request: DicomFrameDecodeRequest,
        mode: DicomJ2KSwiftRolloutMode,
        report: @escaping TelemetryReporter
    ) async throws -> DicomCodecDecodedFrame {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let frame = try await backend.decode(request)
            report(DicomJ2KSwiftDecodeTelemetry(
                mode: mode,
                backend: backend.capabilities.identifier,
                durationNanoseconds: elapsed(since: start),
                width: frame.width,
                height: frame.height,
                outcome: .succeeded
            ))
            return frame
        } catch {
            report(DicomJ2KSwiftDecodeTelemetry(
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
