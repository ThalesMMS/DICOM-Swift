public struct DicomSurfaceSegmentationDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case surfaceNumber, pointCount, nonFiniteCoordinate, indexOutOfBounds, primitiveCount
        case normalsCount, vectorDimensionality, multipleVectorSets, accuracyCount, boundingBoxCount
        case segmentSurfaceReference, duplicateSegmentNumber
    }
    public let surfaceNumber: Int?
    public let segmentNumber: Int?
    public let code: Code
}
