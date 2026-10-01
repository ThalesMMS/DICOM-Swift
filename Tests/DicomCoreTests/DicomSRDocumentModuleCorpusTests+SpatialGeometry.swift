import Foundation
import XCTest
@testable import DicomCore

extension DicomSRDocumentModuleCorpusTests {
    func test_spatialGeometryCorpus_qualifiesShapeSeparatelyFromAttributesAndTargetBounds() throws {
        let ellipse: [Double] = [0, 2, 4, 2, 2, 1, 2, 3]
        let ellipsoid: [Double] = [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, 0, 0, -1, 0, 0, 1]
        let plane: [Double] = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 0]
        var nearEllipse = ellipse
        nearEllipse[7] = Double(Float(3).nextUp)
        var nearPlane = plane
        nearPlane[11] = Double(Float.leastNonzeroMagnitude)
        let cases: [(String, String, [Double], DicomValidationReport.Outcome)] = [
            ("2d-ellipse", "ELLIPSE", ellipse, .passed),
            ("2d-center", "ELLIPSE", [0, 2, 4, 2, 3, 1, 3, 3], .failed),
            ("2d-oblique", "ELLIPSE", [0, 2, 4, 2, 1, 1, 3, 3], .failed),
            ("2d-order", "ELLIPSE", [1, 2, 3, 2, 2, 0, 2, 4], .failed),
            ("2d-rounding", "ELLIPSE", nearEllipse, .incomplete),
            ("2d-zero-axis", "ELLIPSE", [0, 2, 4, 2, 2, 2, 2, 2], .incomplete),
            ("2d-circle", "CIRCLE", [2, 2, 3, 2], .passed),
            ("2d-zero-radius", "CIRCLE", [2, 2, 2, 2], .incomplete),
            ("3d-ellipse", "ELLIPSE", [-2, -2, 0, 2, 2, 0, -1, 1, 0, 1, -1, 0], .passed),
            ("3d-ellipsoid", "ELLIPSOID", ellipsoid, .passed),
            ("3d-center", "ELLIPSOID", [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, 1, 0, -1, 1, 0, 1], .failed),
            ("3d-oblique", "ELLIPSOID", [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, -1, 0, -1, 1, 0, 1], .failed),
            ("3d-zero-axis", "ELLIPSOID", [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0], .incomplete),
            ("3d-plane", "POLYGON", plane, .passed),
            ("3d-nonplanar", "POLYGON", [0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0], .failed),
            ("3d-collinear", "POLYGON", [0, 0, 0, 1, 1, 1, 2, 2, 2, 0, 0, 0], .incomplete),
            ("3d-leading-collinear", "POLYGON", [0, 0, 0, 1, 0, 0, 2, 0, 0, 2, 2, 0, 0, 0, 0], .passed),
            ("3d-self-intersecting", "POLYGON", [0, 0, 0, 2, 2, 0, 0, 2, 0, 2, 0, 0, 0, 0, 0], .passed),
            ("3d-rounding", "POLYGON", nearPlane, .incomplete),
            ("3d-polyline", "POLYLINE", [0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0], .passed),
            ("3d-huge", "ELLIPSOID", ellipsoid.map { $0 * pow(2, 100) }, .passed),
            ("3d-subnormal", "ELLIPSOID", ellipsoid.map { $0 * Double(Float.leastNonzeroMagnitude) }, .passed)
        ]
        for (name, graphic, values, expected) in cases {
            let kind: DicomSpatialCoordinatesMacro.Kind = name.hasPrefix("2d-") ? .spatial : .spatial3D
            let base = try fixture(suffix: "33").setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.88." + (kind == .spatial ? "33" : "34"), .UI))
            let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
            var item = image.removing(0x00081199).setting(text(0x0040A040, kind.rawValue, .CS))
                .setting(text(0x00700023, graphic, .CS)).setting(.init(tag: 0x00700022, vr: .FL, value: .floats(values)))
            if kind == .spatial { item = item.setting(sequence(0x0040A730, [image.setting(text(0x0040A010, "SELECTED FROM", .CS))])) }
            else { item = item.setting(text(0x30060024, "2.25.232199", .UI)) }
            var source = base.setting(sequence(0x0040A730, [item]))
            if kind == .spatial3D { source = source.removing(0x0040A375) }
            let read = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: source, purpose: .instance))
            XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed, name)
            let owned = try XCTUnwrap(read.dataSet)
            let raw = try XCTUnwrap(owned.sequenceItems(for: .contentSequence).first?.dataSet)
            var facts = DicomSpatialCoordinatesMacro.Conditions()
            facts.referencedImageIsTiled = .unsatisfied
            XCTAssertEqual(DicomSpatialCoordinatesMacro.validate(raw, kind: kind, conditions: facts)[.attributes], .passed, name)
            let geometry = DicomSpatialGeometryValidator.validate(raw, kind: kind)
            XCTAssertEqual(geometry[.pixelsAndGeometry], expected, name)
            let composed = DicomSRContentValidator.validate(owned, spatialConditions: [[0]: facts])
            XCTAssertEqual(composed[.pixelsAndGeometry], kind == .spatial && expected == .passed ? .incomplete : expected, name)
            for diagnostic in geometry.diagnostics {
                XCTAssertTrue(composed.diagnostics.contains { $0.code == diagnostic.code && $0.layer == .pixelsAndGeometry &&
                    $0.path == [.tag(0x0040A730), .item(0)] + diagnostic.path }, name)
            }
            if expected == .failed { XCTAssertNotEqual(composed[.operation], .passed, name) }
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_GEOMETRY_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try DicomDataSetWriter.part10Data(from: source, options: .init(validationPurpose: .instance))
                    .write(to: path.appendingPathExtension("dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": "passed", "structureAndVRVM": "passed",
                    "shape": geometry[.pixelsAndGeometry].rawValue, "composedGeometry": composed[.pixelsAndGeometry].rawValue,
                    "diagnostics": geometry.diagnostics.map { $0.code.rawValue }])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }
}
