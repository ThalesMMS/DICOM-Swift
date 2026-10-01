import Foundation

public enum DicomSoftcopyPresentationStateKind: String, Equatable, Sendable {
    case grayscale
    case color
    case blending
    case pseudoColor
}
