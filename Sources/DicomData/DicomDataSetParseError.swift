import Foundation

/// Deterministic failures raised before an encoded dataset exceeds its structural budget.
public enum DicomDataSetParseError: Error, Equatable, Sendable {
    case maximumSequenceDepthExceeded(limit: Int)
    case maximumElementCountExceeded(limit: Int)
    case maximumItemCountExceeded(limit: Int)
}

extension DicomDataSetParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .maximumSequenceDepthExceeded(let limit):
            return "DICOM sequence depth exceeds the limit of \(limit)."
        case .maximumElementCountExceeded(let limit):
            return "DICOM element count exceeds the limit of \(limit)."
        case .maximumItemCountExceeded(let limit):
            return "DICOM sequence item count exceeds the limit of \(limit)."
        }
    }
}
