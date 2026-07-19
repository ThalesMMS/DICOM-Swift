//
//  DicomCodecWorkflowError.swift
//  DicomCore
//

import Foundation

/// Typed, adapter-independent failures from the shared codec workflow.
public enum DicomCodecWorkflowError: Error, Equatable, LocalizedError, Sendable {
    /// Stable error category used by CLI and app adapters.
    public enum Category: String, Codable, Sendable {
        case invalidInput
        case unsupported
        case backendUnavailable
        case corruptFrame
        case validation
    }

    case invalidDICOM(reason: String)
    case invalidFrameIndex(index: Int, frameCount: Int)
    case unsupported(sourceUID: String, targetUID: String?, reasons: [String])
    case backendUnavailable(identifier: String, reason: String)
    case corruptFrame(index: Int, reason: String)
    case artifactValidation(reason: String)

    /// Stable category for this workflow failure.
    public var category: Category {
        switch self {
        case .invalidDICOM, .invalidFrameIndex:
            return .invalidInput
        case .unsupported:
            return .unsupported
        case .backendUnavailable:
            return .backendUnavailable
        case .corruptFrame:
            return .corruptFrame
        case .artifactValidation:
            return .validation
        }
    }

    /// Human-readable adapter-safe failure description.
    public var errorDescription: String? {
        switch self {
        case .invalidDICOM(let reason):
            return "Invalid DICOM input: \(reason)"
        case .invalidFrameIndex(let index, let frameCount):
            return "Frame index \(index) is outside the addressable range of \(frameCount) frame(s)."
        case .unsupported(let source, let target, let reasons):
            let route = target.map { " from \(source) to \($0)" } ?? " for \(source)"
            return "Codec workflow\(route) is unsupported: \(reasons.joined(separator: " "))"
        case .backendUnavailable(let identifier, let reason):
            return "Codec backend \(identifier) is unavailable: \(reason)"
        case .corruptFrame(let index, let reason):
            return "Frame \(index) is corrupt or undecodable: \(reason)"
        case .artifactValidation(let reason):
            return "Codec artifact validation failed: \(reason)"
        }
    }
}
