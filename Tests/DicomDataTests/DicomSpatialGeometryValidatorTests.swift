import Foundation
import XCTest
@testable import DicomData

final class DicomSpatialGeometryValidatorTests: XCTestCase {
    func test_exactShapesAndNonplanarPointCollections_haveScopedGeometricProof() {
        let cases: [(DicomSpatialCoordinatesMacro.Kind, String, [Double])] = [
            (.spatial, "POINT", [1, 2]), (.spatial, "CIRCLE", [2, 2, 3, 2]),
            (.spatial, "ELLIPSE", [0, 2, 4, 2, 2, 1, 2, 3]),
            (.spatial3D, "ELLIPSE", [-2, -2, 0, 2, 2, 0, -1, 1, 0, 1, -1, 0]),
            (.spatial3D, "ELLIPSOID", ellipsoid),
            (.spatial3D, "MULTIPOINT", nonplanar), (.spatial3D, "POLYLINE", nonplanar),
            (.spatial3D, "POLYGON", [0, 0, 0, 1, 0, 0, 2, 0, 0, 2, 2, 0, 0, 0, 0]),
            (.spatial3D, "POLYGON", [0, 0, 0, 2, 2, 0, 0, 2, 0, 2, 0, 0, 0, 0, 0])
        ]
        for (kind, type, values) in cases {
            let report = validate(type, values, kind)
            XCTAssertEqual(report[.pixelsAndGeometry], .passed, type)
            XCTAssertEqual(report[.attributes], .notEvaluated)
        }
    }

    func test_nonplanarPolygonsAndContradictoryAxes_failSpecifically() {
        let cases: [(DicomSpatialCoordinatesMacro.Kind, String, [Double])] = [
            (.spatial3D, "POLYGON", nonplanar + [0, 0, 0]),
            (.spatial, "ELLIPSE", [0, 2, 4, 2, 3, 1, 3, 3]), // Different centers.
            (.spatial, "ELLIPSE", [0, 2, 4, 2, 1, 1, 3, 3]), // Oblique axes.
            (.spatial, "ELLIPSE", [1, 2, 3, 2, 2, 0, 2, 4]), // Major/minor order reversed.
            (.spatial3D, "ELLIPSOID", [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, -1, 0, -1, 1, 0, 1]),
            (.spatial3D, "ELLIPSOID", [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, 1, 0, -1, 1, 0, 1])
        ]
        for (kind, type, values) in cases {
            let report = validate(type, values, kind)
            XCTAssertEqual(report[.pixelsAndGeometry], .failed, type)
            XCTAssertEqual(report.diagnostics.map(\.code), [.spatialGeometryInvalid])
            XCTAssertEqual(report.diagnostics.first?.path, [.tag(0x00700022)])
            XCTAssertEqual(report.diagnostics.first?.requirement, .type1)
        }
    }

    func test_degenerateShapes_doNotAcquireAnInventedPlaneOrAxis() {
        for (type, values) in [("CIRCLE", [1.0, 1, 1, 1]), ("ELLIPSE", [0.0, 2, 4, 2, 2, 2, 2, 2])] {
            XCTAssertEqual(validate(type, values, .spatial).diagnostics.map(\.code), [.spatialGeometryDegenerate])
        }
        let collinear = validate("POLYGON", [0, 0, 0, 1, 1, 1, 2, 2, 2, 0, 0, 0], .spatial3D)
        XCTAssertEqual(collinear[.pixelsAndGeometry], .incomplete)
        XCTAssertEqual(collinear.diagnostics.map(\.code), [.spatialGeometryDegenerate])
    }

    func test_storageRoundingAmbiguity_isIncompleteRatherThanPassedOrRejected() {
        var values: [Double] = [0, 2, 4, 2, 2, 1, 2, Double(Float(3).nextUp)]
        let near = validate("ELLIPSE", values, .spatial)
        XCTAssertEqual(near[.pixelsAndGeometry], .incomplete)
        XCTAssertEqual(near.diagnostics.map(\.code), [.spatialGeometryPrecisionUnavailable])
        values[7] = Double(Float(3.001))
        XCTAssertEqual(validate("ELLIPSE", values, .spatial)[.pixelsAndGeometry], .failed)
        values[7] = 3.1 // An owned Double is not silently rounded to FL to qualify a shape.
        XCTAssertEqual(validate("ELLIPSE", values, .spatial).diagnostics.map(\.code), [.spatialGeometryPrecisionUnavailable])
    }

    func test_scaleTranslationAndSubnormalStorage_doNotNeedFixedSpatialTolerance() {
        for exponent in [-149, -120, 0, 80, 100] {
            let scale = pow(2.0, Double(exponent))
            let translation = exponent >= 0 ? scale * 16 : 0
            let shape = ellipsoid.enumerated().map { index, value in Double(Float(value * scale + (index % 3 == 0 ? translation : 0))) }
            XCTAssertEqual(validate("ELLIPSOID", shape, .spatial3D)[.pixelsAndGeometry], .passed, "scale \(exponent)")
            var invalid = shape
            invalid[12] += scale * 8
            invalid[15] += scale * 8
            XCTAssertEqual(validate("ELLIPSOID", invalid, .spatial3D)[.pixelsAndGeometry], .failed, "scale \(exponent)")
        }
    }

    func test_expansions_preserveSmallResidualsAcrossLargeCancellation() {
        let large = DicomSpatialGeometryScalar(Double(Float.greatestFiniteMagnitude))
        let tiny = DicomSpatialGeometryScalar(Double(Float.leastNonzeroMagnitude))
        let residual = (large + tiny) - large
        XCTAssertFalse(residual.isZero)
        XCTAssertGreaterThan(residual.sign, 0)
        XCTAssertEqual((residual - tiny).isZero, true)
        let product = (large + tiny) * (large - tiny) - large * large
        XCTAssertFalse(product.isZero)
        XCTAssertLessThan(product.sign, 0)
        XCTAssertTrue((product + tiny * tiny).isZero)
        let cubic = (large + tiny) * (large - tiny) * (large + tiny) - large * large * large - large * large * tiny + large * tiny * tiny
        XCTAssertFalse(cubic.isZero)
        XCTAssertLessThan(cubic.sign, 0)
        XCTAssertTrue((cubic + tiny * tiny * tiny).isZero)
    }

    func test_opaqueMalformedAndUnbudgetedValues_neverPassGeometry() {
        for source in [DicomDataSet(), item("POINT", [1, 2, 3]), item("POINT", [Double.nan, 1]),
                       item("POINT", [1, 2]).setting(.init(tag: 0x00700022, vr: .UN, value: .bytes(Data([0, 0]))))] {
            XCTAssertNotEqual(DicomSpatialGeometryValidator.validate(source, kind: .spatial)[.pixelsAndGeometry], .passed)
        }
        let source = item("POLYGON", Array(repeating: 0, count: 3000))
        let result = DicomSpatialGeometryValidator.evaluate(source, kind: .spatial3D, limits: .init(maximumRuleEvaluations: 20))
        XCTAssertLessThanOrEqual(result.evaluations, 20)
        XCTAssertEqual(result.report.diagnostics.map(\.code), [.evaluationLimitReached])
        XCTAssertEqual(result.report[.pixelsAndGeometry], .incomplete)
    }

    private let ellipsoid: [Double] = [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, 0, 0, -1, 0, 0, 1]
    private let nonplanar: [Double] = [0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0]
    private func validate(_ type: String, _ values: [Double], _ kind: DicomSpatialCoordinatesMacro.Kind) -> DicomValidationReport {
        DicomSpatialGeometryValidator.validate(item(type, values), kind: kind)
    }
    private func item(_ type: String, _ values: [Double]) -> DicomDataSet {
        .init(elements: [.init(tag: 0x00700023, vr: .CS, value: .strings([type])), .init(tag: 0x00700022, vr: .FL, value: .floats(values))])
    }
}
