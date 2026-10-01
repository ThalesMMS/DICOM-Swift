import Foundation

public enum DicomCDAContentError: LocalizedError, Equatable, Sendable {
    case documentTooLarge
    case unsafeXML
    case malformedXML
    case noReadableSections

    public var errorDescription: String? {
        switch self {
        case .documentTooLarge:
            return "The CDA document is too large to display safely."
        case .unsafeXML:
            return "The CDA document declares XML entities that cannot be opened safely."
        case .malformedXML:
            return "The CDA document contains malformed XML."
        case .noReadableSections:
            return "The CDA document has no readable narrative sections."
        }
    }
}
