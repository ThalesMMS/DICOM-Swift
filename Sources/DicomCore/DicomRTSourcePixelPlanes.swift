import simd

public struct DicomRTSourcePixelPlanes: Equatable, Sendable {
    public let position: SIMD3<Double>
    public let orientation: DicomPlaneOrientation
    public let spacing: SIMD2<Double>
    public let rows: Int
    public let columns: Int
    public let spacingBetweenSlices: Double
    public let numberOfFrames: Int
    public let sliceThickness: Double?

    public init(position: SIMD3<Double>, orientation: DicomPlaneOrientation, spacing: SIMD2<Double>,
                rows: Int, columns: Int, spacingBetweenSlices: Double, numberOfFrames: Int, sliceThickness: Double? = nil) {
        self.position = position
        self.orientation = orientation
        self.spacing = spacing
        self.rows = rows
        self.columns = columns
        self.spacingBetweenSlices = spacingBetweenSlices
        self.numberOfFrames = numberOfFrames
        self.sliceThickness = sliceThickness
    }
}
