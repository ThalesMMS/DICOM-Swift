import Foundation

/// Matrix coordinates are one-based pixel centers: (1, 1) maps exactly to the origin.
public struct DicomSlideCoordinateTransform: Sendable, Equatable {
    public let origin: DicomSlideOrigin
    public let orientation: [Double]
    public let pixelSpacingXMillimeters: Double
    public let pixelSpacingYMillimeters: Double
    public let matrixColumns: Int
    public let matrixRows: Int

    public init?(
        origin: DicomSlideOrigin?, orientation: [Double],
        pixelSpacingXMillimeters: Double?, pixelSpacingYMillimeters: Double?,
        matrixColumns: Int, matrixRows: Int
    ) {
        guard let origin, let x = pixelSpacingXMillimeters, let y = pixelSpacingYMillimeters,
              x.isFinite, y.isFinite, x > 0, y > 0, matrixColumns > 0, matrixRows > 0,
              [origin.xMillimeters, origin.yMillimeters, origin.zMicrometers].allSatisfy(\.isFinite),
              Self.isOrthonormal(orientation) else { return nil }
        self.origin = origin
        self.orientation = orientation
        self.pixelSpacingXMillimeters = x
        self.pixelSpacingYMillimeters = y
        self.matrixColumns = matrixColumns
        self.matrixRows = matrixRows
    }

    public static func isOrthonormal(_ values: [Double]) -> Bool {
        guard values.count == 6, values.allSatisfy(\.isFinite) else { return false }
        let rowNorm = (0..<3).reduce(0.0) { $0 + values[$1] * values[$1] }
        let colNorm = (3..<6).reduce(0.0) { $0 + values[$1] * values[$1] }
        let dot = (0..<3).reduce(0.0) { $0 + values[$1] * values[$1 + 3] }
        return abs(rowNorm - 1) <= 1e-6 && abs(colNorm - 1) <= 1e-6 && abs(dot) <= 1e-6
    }

    public func slidePoint(forMatrixColumn column: Double, row: Double) -> DicomSlideOrigin {
        let x = (column - 1) * pixelSpacingXMillimeters
        let y = (row - 1) * pixelSpacingYMillimeters
        return DicomSlideOrigin(
            xMillimeters: origin.xMillimeters + x * orientation[0] + y * orientation[3],
            yMillimeters: origin.yMillimeters + x * orientation[1] + y * orientation[4],
            zMicrometers: origin.zMicrometers + 1000 * (x * orientation[2] + y * orientation[5])
        )
    }

    /// Returns nil for planes whose XY projection is singular (an XY-only inverse is undefined).
    public func matrixPoint(forSlideX x: Double, y: Double) -> (column: Double, row: Double)? {
        let determinant = orientation[0] * orientation[4] - orientation[3] * orientation[1]
        guard x.isFinite, y.isFinite, abs(determinant) > 1e-12 else { return nil }
        let dx = x - origin.xMillimeters
        let dy = y - origin.yMillimeters
        return (
            1 + (dx * orientation[4] - dy * orientation[3]) / determinant / pixelSpacingXMillimeters,
            1 + (dy * orientation[0] - dx * orientation[1]) / determinant / pixelSpacingYMillimeters
        )
    }

    /// Full pixel footprint along the matrix axes, including the two half-pixel borders.
    public var physicalExtentMillimeters: (width: Double, height: Double) {
        (Double(matrixColumns) * pixelSpacingXMillimeters, Double(matrixRows) * pixelSpacingYMillimeters)
    }
}

public extension DicomWholeSlideMicroscopyMetadata {
    var slideCoordinateTransform: DicomSlideCoordinateTransform? {
        DicomSlideCoordinateTransform(
            origin: totalPixelMatrixOrigin, orientation: imageOrientationSlide,
            pixelSpacingXMillimeters: pixelSpacingXMillimeters,
            pixelSpacingYMillimeters: pixelSpacingYMillimeters,
            matrixColumns: matrixWidth, matrixRows: matrixHeight
        )
    }
}
