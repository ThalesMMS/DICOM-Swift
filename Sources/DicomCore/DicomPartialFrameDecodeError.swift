import Foundation

/// Typed validation and execution failures for partial frame decode.
public enum DicomPartialFrameDecodeError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedTransferSyntax(String)
    case backendDisabled
    case invalidRegion
    case invalidResolutionReductionLevel(requested: Int, maximum: Int)
    case invalidQualityLayer(requested: Int, count: Int)
    case unsupportedCombination
    case finalQualityUnavailable(requestedLayer: Int, finalLayer: Int)
    case decodeFailed(String)

    /// Human-readable diagnostic suitable for logs or error presentation.
    public var errorDescription: String? {
        switch self {
        case let .unsupportedTransferSyntax(uid):
            return "Partial frame decode is unavailable for transfer syntax \(uid)."
        case .backendDisabled:
            return "The J2KSwift partial-decode backend is disabled."
        case .invalidRegion:
            return "The requested frame region is empty or outside the source frame."
        case let .invalidResolutionReductionLevel(requested, maximum):
            return "Resolution reduction level \(requested) is outside 0...\(maximum)."
        case let .invalidQualityLayer(requested, count):
            return "Quality layer \(requested) is outside the \(count)-layer codestream."
        case .unsupportedCombination:
            return "J2KSwift cannot combine quality-layer and spatial partial decode."
        case let .finalQualityUnavailable(requestedLayer, finalLayer):
            return "Quality layer \(requestedLayer) is provisional; final quality requires layer \(finalLayer)."
        case let .decodeFailed(reason):
            return "Partial frame decode failed: \(reason)"
        }
    }
}
