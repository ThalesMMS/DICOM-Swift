/// PHI-free registration parser findings. Item and matrix indexes are zero-based.
public struct DicomSpatialRegistrationDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case matrixValueCount, nonFiniteMatrix, invalidLastRow, unknownMatrixType
        case missingFrameAndReferences, matrixRegistrationItemCount, missingRequiredAttribute
        case invalidGridDimensions, invalidGridResolution, invalidGridOrientation, invalidGridPosition
        case vectorGridLengthMismatch, invalidVector, noGrid, invalidSequenceCardinality
    }
    public let code: Code
    public let message: String
    public let itemIndex: Int?
    public let matrixIndex: Int?

    public init(code: Code, itemIndex: Int? = nil, matrixIndex: Int? = nil) {
        self.code = code
        self.message = code.rawValue
        self.itemIndex = itemIndex
        self.matrixIndex = matrixIndex
    }
}
