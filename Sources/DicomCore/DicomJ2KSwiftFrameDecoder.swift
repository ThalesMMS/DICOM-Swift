//
//  DicomJ2KSwiftFrameDecoder.swift
//  DicomCore
//

import Foundation
import DicomJPEG2000

enum DicomJ2KSwiftFrameDecoder {
    typealias TelemetryReporter = @Sendable (DicomJ2KSwiftDecodeTelemetry) -> Void

    static func decode(
        _ request: DicomFrameDecodeRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidate: any DicomFrameCodecBackend = DicomJ2KSwiftBackend(),
        report: @escaping TelemetryReporter = { _ in }
    ) async throws -> DicomCodecDecodedFrame? {
        try Task.checkCancellation()
        let mode = DicomJ2KSwiftRolloutMode(environment: environment)
        guard mode != .disabled else { return nil }

        let established = DicomOpenJPEGFrameBackend(environment: environment)
        let decision = DicomCodecCapabilities.resolve(request.capabilityRequest, environment: environment)
        guard decision.canExecute else {
            throw DicomCodecSelectionError.unsupported(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reasons: [decision.reason ?? "No qualified decoder is available."]
            )
        }
        if request.partialRequest != nil {
            return try await timedDecode(candidate, request: request, mode: mode, report: report)
        }
        switch mode {
        case .disabled:
            return nil
        case .shadow:
            guard decision.backendIdentifier == established.capabilities.identifier.rawValue else { return nil }
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
                let shadowStart = DispatchTime.now().uptimeNanoseconds
                do {
                    try Task.checkCancellation()
                    let shadow = try await candidate.decode(request)
                    try Task.checkCancellation()
                    let outcome: DicomJ2KSwiftDecodeTelemetry.Outcome =
                        framesMatch(production, shadow) ? .matched : .mismatched
                    await DicomShadowExecutor.shared.record(outcome == .matched ? .matched : .mismatched)
                    report(DicomJ2KSwiftDecodeTelemetry(
                        mode: mode,
                        backend: candidate.capabilities.identifier,
                        durationNanoseconds: elapsed(since: shadowStart),
                        width: shadow.width,
                        height: shadow.height,
                        outcome: outcome
                    ))
                } catch {
                    await DicomShadowExecutor.shared.record(error is CancellationError ? .cancelled : .failed)
                    report(DicomJ2KSwiftDecodeTelemetry(
                        mode: mode,
                        backend: candidate.capabilities.identifier,
                        durationNanoseconds: elapsed(since: shadowStart),
                        width: nil,
                        height: nil,
                        outcome: error is CancellationError ? .cancelled : .failed(error.localizedDescription)
                    ))
                }
            }
            if admission != .admitted {
                report(DicomJ2KSwiftDecodeTelemetry(
                    mode: mode, backend: candidate.capabilities.identifier, durationNanoseconds: 0,
                    width: nil, height: nil, outcome: .skipped(admission.rawValue)
                ))
            }
            try Task.checkCancellation()
            return production
        case .preferred:
            let backend: any DicomFrameCodecBackend = decision.backendIdentifier == candidate.capabilities.identifier.rawValue
                ? candidate : established
            let frame: DicomCodecDecodedFrame
            do {
                frame = try await timedDecode(backend, request: request, mode: mode, report: report)
            } catch {
                try Task.checkCancellation()
                guard backend.capabilities.identifier == candidate.capabilities.identifier,
                      request.capabilityRequest.allowsFallback, permitsFallback(after: error) else { throw error }
                let fallbackDecision = DicomCodecCapabilities.resolve(.init(
                    operation: .decode, descriptor: request.descriptor, frameData: request.frameData,
                    preferredBackend: established.capabilities.identifier.rawValue, allowsFallback: false
                ), environment: environment)
                guard fallbackDecision.canExecute else { throw error }
                let fallback = try await timedDecode(established, request: request, mode: mode, report: report)
                report(DicomJ2KSwiftDecodeTelemetry(
                    mode: mode, backend: established.capabilities.identifier, durationNanoseconds: 0,
                    width: fallback.width, height: fallback.height, outcome: .fellBack(error.localizedDescription)
                ))
                return fallback
            }
            if let reason = decision.fallbackReason {
                report(DicomJ2KSwiftDecodeTelemetry(
                    mode: mode, backend: backend.capabilities.identifier, durationNanoseconds: 0,
                    width: frame.width, height: frame.height, outcome: .fellBack(reason)
                ))
            }
            return frame
        case .forcedForTests:
            return try await timedDecode(
                candidate,
                request: request,
                mode: mode,
                report: report
            )
        }
    }

    private static func permitsFallback(after error: Error) -> Bool {
        if let error = error as? DicomJ2KSwiftBackendError {
            switch error {
            case .unsupportedShape, .codecVersionMismatch: return true
            case .metadataMismatch: return false
            }
        }
        if let error = error as? J2KError {
            switch error {
            // Corrupted entropy data may still be read by the established decoder (#2899); the fallback telemetry
            // records why.
            case .unsupportedFeature, .notImplemented, .corruptedEntropyData: return true
            default: return false
            }
        }
        return false
    }

    private static func timedDecode(
        _ backend: any DicomFrameCodecBackend,
        request: DicomFrameDecodeRequest,
        mode: DicomJ2KSwiftRolloutMode,
        report: @escaping TelemetryReporter
    ) async throws -> DicomCodecDecodedFrame {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try Task.checkCancellation()
            let frame = try await backend.decode(request)
            try Task.checkCancellation()
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
