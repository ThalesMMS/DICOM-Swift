import Foundation
import XCTest
@testable import DicomData

final class DicomSpatialCoordinatesMacroTests: XCTestCase {
    func test_graphicTypes_acceptExactDimensionsAndCardinalities() {
        for kind in kinds {
            let dimension = kind == .spatial ? 2 : 3
            let entries = kind == .spatial ? [("POINT", 1), ("MULTIPOINT", 2), ("POLYLINE", 3), ("CIRCLE", 2), ("ELLIPSE", 4)] :
                [("POINT", 1), ("MULTIPOINT", 2), ("POLYLINE", 3), ("POLYGON", 4), ("ELLIPSE", 4), ("ELLIPSOID", 6)]
            for (type, count) in entries {
                var values = (0..<(count * dimension)).map(Double.init)
                if type == "POLYGON" { values.replaceSubrange((values.count - 3)..<values.count, with: values.prefix(3)) }
                XCTAssertEqual(validate(item(type, values), kind)[.attributes], .passed, "\(kind) \(type)")
            }
        }
    }

    func test_wrongCountsAndIncompleteTuples_failAtGraphicData() {
        for kind in kinds {
            let dimension = kind == .spatial ? 2 : 3
            for (type, count) in [("POINT", 2), ("MULTIPOINT", 1), ("POLYLINE", 1), ("ELLIPSE", 3)] {
                let report = validate(item(type, Array(repeating: 1, count: count * dimension)), kind)
                XCTAssertTrue(report.diagnostics.contains { $0.code == .invalidMultiplicity && $0.path == [.tag(0x00700022)] && $0.requirement == .type1 })
            }
            let odd = item("MULTIPOINT", Array(repeating: 1, count: dimension * 2 + 1))
            XCTAssertTrue(validate(odd, kind).diagnostics.contains { $0.code == .invalidMultiplicity })
        }
        for (kind, type, count) in [(DicomSpatialCoordinatesMacro.Kind.spatial, "CIRCLE", 6), (.spatial3D, "ELLIPSOID", 15), (.spatial3D, "POLYGON", 9)] {
            XCTAssertTrue(validate(item(type, Array(repeating: 1, count: count)), kind).diagnostics.contains { $0.code == .invalidMultiplicity })
        }
    }

    func test_threeDimensionalValues_allowNegativeCoordinatesAndRequireTheirOwnReferenceUID() {
        let source = item("POINT", [-1, -2, -3])
        XCTAssertEqual(validate(source, .spatial3D)[.attributes], .passed)
        for dataSet in [source.removing(0x30060024), source.setting(text(0x30060024, "", .UI))] {
            XCTAssertEqual(validate(dataSet, .spatial3D)[.attributes], .failed)
        }
        XCTAssertTrue(validate(item("POINT", [-1, 0]), .spatial).diagnostics.contains { $0.code == .attributeValueNotAllowed })
        XCTAssertEqual(validate(item("POINT", [0, -0.0]), .spatial)[.attributes], .passed)
    }

    func test_nonFiniteAndOutOfFLRange_failWithoutProjectionRepair() {
        for value in [Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude] {
            for kind in kinds {
                let dimension = kind == .spatial ? 2 : 3
                XCTAssertTrue(validate(item("POINT", [value] + Array(repeating: 0, count: dimension - 1)), kind)
                    .diagnostics.contains { $0.code == .attributeValueNotAllowed })
            }
        }
    }

    func test_polygonRequiresExactClosingTriplet_butPolylineMayRemainOpenAndNonplanar() {
        let open: [Double] = [0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0]
        XCTAssertTrue(validate(item("POLYGON", open), .spatial3D).diagnostics.contains { $0.code == .attributeValueContradiction })
        XCTAssertEqual(validate(item("POLYLINE", open), .spatial3D)[.attributes], .passed)
        XCTAssertEqual(validate(item("MULTIPOINT", open), .spatial3D)[.attributes], .passed)
        var closed = open
        closed += [0, 0, 0]
        let report = validate(item("POLYGON", closed), .spatial3D)
        XCTAssertEqual(report[.attributes], .passed) // Attribute counts/closure only; coplanarity is separate geometric evidence.
        XCTAssertEqual(report[.pixelsAndGeometry], .notEvaluated)
    }

    func test_tiledImageCondition_isExplicitAndOriginEnumerationIsChecked() {
        let source = item("POINT", [1, 1])
        XCTAssertEqual(DicomSpatialCoordinatesMacro.validate(source, kind: .spatial)[.attributes], .incomplete)
        for truth in [DicomAttributeRule.Truth.satisfied, .unsatisfied, .undetermined] {
            var facts = DicomSpatialCoordinatesMacro.Conditions()
            facts.referencedImageIsTiled = truth
            let absent = DicomSpatialCoordinatesMacro.validate(source, kind: .spatial, conditions: facts)
            XCTAssertEqual(absent[.attributes], truth == .satisfied ? .failed : truth == .unsatisfied ? .passed : .incomplete)
            for origin in ["FRAME", "VOLUME"] {
                let present = source.setting(text(0x00480301, origin, .CS))
                XCTAssertEqual(DicomSpatialCoordinatesMacro.validate(present, kind: .spatial, conditions: facts)[.attributes],
                               truth == .undetermined ? .incomplete : .passed)
            }
        }
        XCTAssertTrue(validate(source.setting(text(0x00480301, "FUTURE", .CS)), .spatial)
            .diagnostics.contains { $0.code == .attributeValueNotAllowed })
    }

    func test_opaqueOrUnknownGraphicType_cannotInventShapeAndKindsHaveSeparateEnums() {
        let source = item("POINT", [1, 2])
        for dataSet in [source.removing(0x00700023), source.setting(text(0x00700023, "FUTURE", .CS)),
                       source.setting(.init(tag: 0x00700023, vr: .UN, value: .bytes(Data([0, 0]))))] {
            let report = validate(dataSet, .spatial)
            XCTAssertNotEqual(report[.attributes], .passed)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .invalidMultiplicity })
        }
        for (kind, type) in [(DicomSpatialCoordinatesMacro.Kind.spatial, "ELLIPSOID"), (.spatial, "POLYGON"), (.spatial3D, "CIRCLE")] {
            XCTAssertTrue(validate(item(type, [1, 2, 3, 4, 5, 6]), kind).diagnostics.contains { $0.code == .attributeValueNotAllowed })
        }
        for vr in [DicomVR.UN, .FD] {
            let opaque = source.setting(.init(tag: 0x00700022, vr: vr, value: .floats([1, 2])))
            XCTAssertEqual(validate(opaque, .spatial)[.attributes], .incomplete)
        }
    }

    func test_valueScanning_isBoundedAndOptionalFiducialUIDMayBeEmpty() {
        let source = item("MULTIPOINT", Array(repeating: 1, count: 1000))
        let report = DicomSpatialCoordinatesMacro.validate(source, kind: .spatial, limits: .init(maximumRuleEvaluations: 20))
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached && $0.path == [.tag(0x00700022)] })
        XCTAssertEqual(validate(item("POINT", [1, 2]).setting(.init(tag: 0x0070031A, vr: .UI, value: .empty)), .spatial)[.attributes], .passed)
        XCTAssertEqual(validate(item("POINT", []).setting(.init(tag: 0x00700022, vr: .FL, value: .empty)), .spatial)[.attributes], .failed)
    }

    private let kinds: [DicomSpatialCoordinatesMacro.Kind] = [.spatial, .spatial3D]
    private func validate(_ source: DicomDataSet, _ kind: DicomSpatialCoordinatesMacro.Kind) -> DicomValidationReport {
        var facts = DicomSpatialCoordinatesMacro.Conditions()
        facts.referencedImageIsTiled = .unsatisfied
        return DicomSpatialCoordinatesMacro.validate(source, kind: kind, conditions: facts)
    }
    private func item(_ type: String, _ values: [Double]) -> DicomDataSet {
        .init(elements: [text(0x00700023, type, .CS), .init(tag: 0x00700022, vr: .FL, value: .floats(values)), text(0x30060024, "2.25.2321", .UI)])
    }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
}
