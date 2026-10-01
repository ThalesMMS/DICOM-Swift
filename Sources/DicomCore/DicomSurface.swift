//
//  DicomSurface.swift
//  DicomCore
//

/// A validated patient-coordinate surface from a Surface Segmentation object.
public struct DicomSurface: Equatable, Sendable {
    /// The one-based surface number within the object.
    public let number: Int
    /// Optional descriptive comments supplied by the producer.
    public let comments: String?
    /// Recommended PCS-Value CIELab triplet, when present.
    public let recommendedDisplayCIELabValue: [UInt16]
    /// Recommended opacity in the closed range from zero through one.
    public let recommendedPresentationOpacity: Float?
    /// Recommended presentation type supplied by the producer.
    public let recommendedPresentationType: String?
    /// Surface vertices in DICOM patient coordinates, measured in millimeters.
    public let points: [SIMD3<Float>]
    /// Optional per-vertex patient-coordinate normal vectors.
    public let normals: [SIMD3<Float>]
    /// Validated one-based indexed primitives that reference ``points``.
    public let primitives: [DicomSurfacePrimitive]

    public let finiteVolume: DicomSurfaceFlag
    public let manifold: DicomSurfaceFlag
    public let surfaceProcessing: Bool?
    public let surfaceProcessingRatio: Float?
    public let surfaceProcessingDescription: String?
    public let surfaceProcessingAlgorithm: DicomAlgorithmIdentification?
    public let numberOfSurfacePoints: Int
    public let pointCoordinatesAccuracy: [Float]?
    public let meanPointDistance: Float?
    public let maximumPointDistance: Float?
    public let pointsBoundingBox: [Double]?
    public let axisOfRotation: SIMD3<Float>?
    public let centerOfRotation: SIMD3<Float>?
    public let vectors: [DicomSurfaceVectorSet]

    /// Creates a validated surface value.
    public init(
        number: Int,
        comments: String? = nil,
        recommendedDisplayCIELabValue: [UInt16] = [],
        recommendedPresentationOpacity: Float? = nil,
        recommendedPresentationType: String? = nil,
        points: [SIMD3<Float>],
        normals: [SIMD3<Float>] = [],
        primitives: [DicomSurfacePrimitive],
        finiteVolume: DicomSurfaceFlag = .unknown,
        manifold: DicomSurfaceFlag = .unknown,
        surfaceProcessing: Bool? = nil,
        surfaceProcessingRatio: Float? = nil,
        surfaceProcessingDescription: String? = nil,
        surfaceProcessingAlgorithm: DicomAlgorithmIdentification? = nil,
        numberOfSurfacePoints: Int? = nil,
        pointCoordinatesAccuracy: [Float]? = nil,
        meanPointDistance: Float? = nil,
        maximumPointDistance: Float? = nil,
        pointsBoundingBox: [Double]? = nil,
        axisOfRotation: SIMD3<Float>? = nil,
        centerOfRotation: SIMD3<Float>? = nil,
        vectors: [DicomSurfaceVectorSet] = []
    ) {
        self.number = number
        self.comments = comments
        self.recommendedDisplayCIELabValue = recommendedDisplayCIELabValue
        self.recommendedPresentationOpacity = recommendedPresentationOpacity
        self.recommendedPresentationType = recommendedPresentationType
        self.points = points
        let vectorSets = vectors.isEmpty && !normals.isEmpty
            ? [DicomSurfaceVectorSet(coordinates: normals.flatMap { [$0.x, $0.y, $0.z] })] : vectors
        self.vectors = vectorSets
        if let vector = vectorSets.first, vector.dimensionality == 3, vector.coordinates.count.isMultiple(of: 3) {
            self.normals = stride(from: 0, to: vector.coordinates.count, by: 3).map {
                SIMD3(vector.coordinates[$0], vector.coordinates[$0 + 1], vector.coordinates[$0 + 2])
            }
        } else {
            self.normals = []
        }
        self.primitives = primitives
        self.finiteVolume = finiteVolume
        self.manifold = manifold
        self.surfaceProcessing = surfaceProcessing
        self.surfaceProcessingRatio = surfaceProcessingRatio
        self.surfaceProcessingDescription = surfaceProcessingDescription
        self.surfaceProcessingAlgorithm = surfaceProcessingAlgorithm
        self.numberOfSurfacePoints = numberOfSurfacePoints ?? points.count
        self.pointCoordinatesAccuracy = pointCoordinatesAccuracy
        self.meanPointDistance = meanPointDistance
        self.maximumPointDistance = maximumPointDistance
        self.pointsBoundingBox = pointsBoundingBox
        self.axisOfRotation = axisOfRotation
        self.centerOfRotation = centerOfRotation
    }
}
