import Foundation

/// An explicit JPEG 2000 encoding request that cannot be represented by the qualified encoder.
public enum DicomJPEG2000EncodingError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedConfiguration(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedConfiguration(let reason): return "Unsupported JPEG 2000 encoding configuration: \(reason)"
        }
    }
}
