import Foundation

public enum DicomSTLContentError: LocalizedError, Equatable, Sendable {
    case documentTooLarge
    case tooManyFacets
    case malformedSTL
    case nonFiniteValue
    case degenerateFacet
    case missingScale
    case unsupportedScale

    public var errorDescription: String? {
        switch self {
        case .documentTooLarge:
            return "The STL document is too large to display safely."
        case .tooManyFacets:
            return "The STL document contains too many facets to display safely."
        case .malformedSTL:
            return "The STL document is malformed."
        case .nonFiniteValue:
            return "The STL document contains a non-finite coordinate or normal."
        case .degenerateFacet:
            return "The STL document contains a degenerate facet."
        case .missingScale:
            return "The DICOM STL document does not declare its model scale."
        case .unsupportedScale:
            return "The DICOM STL document declares an unsupported model scale."
        }
    }
}
