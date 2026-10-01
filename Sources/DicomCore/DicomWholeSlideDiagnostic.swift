/// PHI-free findings. Frame and level indexes are zero-based; messages contain no source values.
public struct DicomWholeSlideDiagnostic: Sendable, Equatable {
    public enum Code: String, Sendable {
        case frameCountMismatch, framePositionMissing, opticalPathIdentificationMissing
        case positionOutsideMatrix, opticalPathMismatch, tilesOverlapObserved
        case focalPlaneGeometryMissing, invalidOrientation, concatenationCoverageUnverified
        case pyramidLevelMismatch, pyramidScaleMismatch, pyramidGeometryMissing
    }
    public let code: Code
    public let message: String
    public let frameIndex: Int?
    public let levelIndex: Int?

    public init(code: Code, frameIndex: Int? = nil, levelIndex: Int? = nil) {
        self.code = code
        self.message = code.rawValue
        self.frameIndex = frameIndex
        self.levelIndex = levelIndex
    }
}
