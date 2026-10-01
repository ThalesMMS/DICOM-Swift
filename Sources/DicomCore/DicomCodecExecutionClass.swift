import Foundation

/// Processor that owns codec execution.
public enum DicomCodecExecutionClass: String, Codable, Hashable, Sendable {
    case cpu
    case metal
}
