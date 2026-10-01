public struct DicomSTLMesh: Equatable, Sendable {
    public let verticesMillimeters: [SIMD3<Float>]
    public let normals: [SIMD3<Float>]
    public let indices: [UInt32]

    public init(
        verticesMillimeters: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        indices: [UInt32]
    ) {
        self.verticesMillimeters = verticesMillimeters
        self.normals = normals
        self.indices = indices
    }

    public var facetCount: Int {
        indices.count / 3
    }
}
