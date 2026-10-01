/// PHI-free dose parser findings; DVH indexes are zero-based sequence indexes.
public struct DicomRTDoseDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case offsetsCountMismatch
        case nonMonotonicOffsets
        case signedNonErrorDose
        case dvhDataCountMismatch
        case dvhReferencedROIInvalid
        case absoluteZNonTransverseOrientation
    }

    public let code: Code
    public let message: String
    public let dvhIndex: Int?

    public init(code: Code, dvhIndex: Int? = nil) {
        self.code = code
        self.message = code.rawValue
        self.dvhIndex = dvhIndex
    }
}
