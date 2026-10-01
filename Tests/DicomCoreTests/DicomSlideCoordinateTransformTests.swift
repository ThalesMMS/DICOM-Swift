import XCTest
@testable import DicomCore

final class DicomSlideCoordinateTransformTests: XCTestCase {
    func test_rotatedOrientationOffsetOrigin_roundTripsPixelCenters() throws {
        let transform = try XCTUnwrap(DicomSlideCoordinateTransform(
            origin: .init(xMillimeters: 10, yMillimeters: 20, zMicrometers: 150),
            orientation: [0, 1, 0, -1, 0, 0], pixelSpacingXMillimeters: 0.5,
            pixelSpacingYMillimeters: 0.25, matrixColumns: 5, matrixRows: 3
        ))
        XCTAssertEqual(transform.slidePoint(forMatrixColumn: 1, row: 1), transform.origin)
        let point = transform.slidePoint(forMatrixColumn: 5, row: 3)
        XCTAssertEqual(point.xMillimeters, 9.5)
        XCTAssertEqual(point.yMillimeters, 22)
        XCTAssertEqual(point.zMicrometers, 150)
        let inverse = try XCTUnwrap(transform.matrixPoint(forSlideX: point.xMillimeters, y: point.yMillimeters))
        XCTAssertEqual(inverse.column, 5, accuracy: 1e-12)
        XCTAssertEqual(inverse.row, 3, accuracy: 1e-12)
        XCTAssertEqual(transform.physicalExtentMillimeters.width, 2.5)
        XCTAssertEqual(transform.physicalExtentMillimeters.height, 0.75)
    }

    func test_missingOrInvalidGeometry_returnsNil() {
        for orientation in [[], [1, 0, 0, 1, 0, 0], [2, 0, 0, 0, 1, 0], [Double.nan, 0, 0, 0, 1, 0]] {
            XCTAssertNil(DicomSlideCoordinateTransform(origin: .init(xMillimeters: 0, yMillimeters: 0),
                orientation: orientation, pixelSpacingXMillimeters: 1, pixelSpacingYMillimeters: 1,
                matrixColumns: 1, matrixRows: 1))
        }
        XCTAssertNil(DicomSlideCoordinateTransform(origin: nil, orientation: [1, 0, 0, 0, 1, 0],
            pixelSpacingXMillimeters: 1, pixelSpacingYMillimeters: 1, matrixColumns: 1, matrixRows: 1))
        XCTAssertNil(DicomSlideCoordinateTransform(origin: .init(xMillimeters: 0, yMillimeters: 0),
            orientation: [1, 0, 0, 0, 1, 0], pixelSpacingXMillimeters: nil, pixelSpacingYMillimeters: 1,
            matrixColumns: 1, matrixRows: 1))
    }
}
