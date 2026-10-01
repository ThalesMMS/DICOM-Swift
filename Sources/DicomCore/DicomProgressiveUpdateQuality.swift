import Foundation

/// Describes the presentation role of one progressive image update.
public enum DicomProgressiveUpdateQuality: String, Sendable, Equatable {
    case preview
    case refinement
    case final
}
