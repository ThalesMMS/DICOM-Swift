//
//  DicomJLSwiftFrameDecoder.swift
//  DicomCore
//

import Foundation

enum DicomJLSwiftFrameDecoder {
    typealias TelemetryReporter = @Sendable (DicomJLSwiftDecodeTelemetry) -> Void

    static func decode(
        _ request: DicomFrameDecodeRequest,
        candidate: any DicomFrameCodecBackend = DicomJLSwiftBackend(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        report: @escaping TelemetryReporter = { _ in }
    ) async throws -> DicomCodecDecodedFrame? {
        try Task.checkCancellation()
        let mode = DicomJLSwiftRolloutMode(environment: environment)
        guard mode != .disabled else { return nil }

        let established = DicomCharLSFrameBackend(environment: environment)
        let decision = DicomCodecCapabilities.resolve(request.capabilityRequest, environment: environment)
        guard decision.canExecute else {
            throw DicomCodecSelectionError.unsupported(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reasons: [decision.reason ?? "No qualified decoder is available."]
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
            let retained = request.frameData.count.addingReportingOverflow(production.buffer.data.count)
            let admission = await DicomShadowExecutor.schedule(
                bytes: retained.overflow ? Int.max : retained.partialValue, environment: environment
            ) {
                let start = DispatchTime.now().uptimeNanoseconds
                do {
                    try Task.checkCancellation()
                    let shadow = try await candidate.decode(request)
                    try Task.checkCancellation()
                    let matches = framesMatch(production, shadow)
                    await DicomShadowExecutor.shared.record(matches ? .matched : .mismatched)
                    report(DicomJLSwiftDecodeTelemetry(
                        mode: mode,
                        backend: candidate.capabilities.identifier,
                        durationNanoseconds: elapsed(since: start),
                        width: shadow.width,
                        height: shadow.height,
                        outcome: matches ? .matched : .mismatched
                    ))
                } catch {
                    await DicomShadowExecutor.shared.record(error is CancellationError ? .cancelled : .failed)
                    report(DicomJLSwiftDecodeTelemetry(
                        mode: mode,
                        backend: candidate.capabilities.identifier,
                        durationNanoseconds: elapsed(since: start),
                        width: nil,
                        height: nil,
                        outcome: error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                    ))
                }
            }
            if admission != .admitted {
                report(DicomJLSwiftDecodeTelemetry(
                    mode: mode, backend: candidate.capabilities.identifier, durationNanoseconds: 0,
                    width: nil, height: nil, outcome: .skipped(admission.rawValue)
                ))
            }
            try Task.checkCancellation()
            return production
        case .preferred:
            let backend: any DicomFrameCodecBackend = decision.backendIdentifier == candidate.capabilities.identifier.rawValue
                ? candidate : established
            let frame = try await timedDecode(backend, request: request, mode: mode, report: report)
            if let reason = decision.fallbackReason {
                report(DicomJLSwiftDecodeTelemetry(
                    mode: mode, backend: backend.capabilities.identifier, durationNanoseconds: 0,
                    width: frame.width, height: frame.height, outcome: .fellBack(reason)
                ))
            }
            return frame
        case .forcedForTests:
            return try await timedDecode(candidate, request: request, mode: mode, report: report)
        }
    }

    private static func timedDecode(
        _ backend: any DicomFrameCodecBackend,
        request: DicomFrameDecodeRequest,
        mode: DicomJLSwiftRolloutMode,
        report: @escaping TelemetryReporter
    ) async throws -> DicomCodecDecodedFrame {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try Task.checkCancellation()
            let frame = try await backend.decode(request)
            try Task.checkCancellation()
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
                outcome: error is CancellationError ? .cancelled : .failed(error.localizedDescription)
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
