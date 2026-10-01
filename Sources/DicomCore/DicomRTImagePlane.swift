import simd

public struct DicomRTImagePlane: Equatable, Sendable {
    public let position: SIMD3<Double>
    public let orientation: DicomPlaneOrientation
    public let spacing: SIMD2<Double>
    public let rows: Int
    public let columns: Int

    public init(position: SIMD3<Double>, orientation: DicomPlaneOrientation, spacing: SIMD2<Double>,
                rows: Int, columns: Int) {
        self.position = position
        self.orientation = orientation
        self.spacing = spacing
        self.rows = rows
        self.columns = columns
    }
}
