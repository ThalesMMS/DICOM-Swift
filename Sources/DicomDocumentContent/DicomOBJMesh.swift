import Foundation

public struct DicomOBJMesh: Equatable, Sendable {
    public struct Corner: Equatable, Sendable {
        public let vertex: Int
        public let textureCoordinate: Int?
        public let normal: Int?
    }
    public struct Triangle: Equatable, Sendable {
        public let corners: [Corner]
        public let groups: [String]
        public let material: String?
    }
    public internal(set) var vertices: [SIMD3<Float>] = []
    public internal(set) var normals: [SIMD3<Float>] = []
    public internal(set) var textureCoordinates: [SIMD3<Float>] = []
    public internal(set) var triangles: [Triangle] = []
    public internal(set) var materialLibraries: [String] = []
    public internal(set) var objectNames: [String] = []
}
