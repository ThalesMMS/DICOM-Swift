import Foundation
import XCTest
@testable import DicomCore

extension DicomSRDocumentModuleCorpusTests {
    func test_spatialCoordinateCorpus_checksDimensionsValuesAndOriginalPaths() throws {
        let two: [(String, [Double])] = [("POINT", [1, 1]), ("MULTIPOINT", [1, 1, 2, 2]),
            ("POLYLINE", [0, 0, 1, 0, 1, 1]), ("CIRCLE", [2, 2, 3, 2]), ("ELLIPSE", [0, 2, 4, 2, 2, 1, 2, 3])]
        let three: [(String, [Double])] = [("POINT", [-1, 0, 1]), ("MULTIPOINT", [-1, 0, 1, 2, 3, 4]),
            ("POLYLINE", [0, 0, 0, 1, 0, 0, 1, 1, 1]), ("POLYGON", [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0]),
            ("ELLIPSE", [-2, 0, 0, 2, 0, 0, 0, -1, 0, 0, 1, 0]),
            ("ELLIPSOID", [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, 0, 0, -1, 0, 0, 1])]
        var total = 0
        for kind in [DicomSpatialCoordinatesMacro.Kind.spatial, .spatial3D] {
            // The legacy builder does not offer Comprehensive 3D SR; this corpus exercises owned raw datasets.
            let base = try fixture(suffix: "33").setting(text(0x00080016,
                "1.2.840.10008.5.1.4.1.1.88." + (kind == .spatial ? "33" : "34"), .UI))
            let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
            let selectedImage = image.setting(text(0x0040A010, "SELECTED FROM", .CS))
            func coordinate(_ type: String, _ values: [Double]) -> DicomDataSet {
                var result = image.removing(0x00081199).setting(text(0x0040A040, kind.rawValue, .CS))
                    .setting(text(0x00700023, type, .CS)).setting(.init(tag: 0x00700022, vr: .FL, value: .floats(values)))
                if kind == .spatial { result = result.setting(sequence(0x0040A730, [selectedImage])) }
                else { result = result.setting(text(0x30060024, "2.25.232199", .UI)) }
                return result
            }
            var facts = DicomSpatialCoordinatesMacro.Conditions()
            facts.referencedImageIsTiled = .unsatisfied
            var cases: [(String, DicomDataSet, DicomAttributeRule.Truth, DicomValidationReport.Outcome)] = []
            let dimension = kind == .spatial ? 2 : 3
            for (type, values) in kind == .spatial ? two : three {
                let name = type.lowercased()
                cases.append((name, coordinate(type, values), .unsatisfied, .passed))
                cases.append((name + "-tuple", coordinate(type, values + [0]), .unsatisfied, .failed))
                let wrong = type == "POINT" ? values + values : Array(values.prefix(type == "POLYGON" ? 9 : dimension))
                cases.append((name + "-count", coordinate(type, wrong), .unsatisfied, .failed))
            }
            if kind == .spatial {
                let point = coordinate("POINT", [1, 1])
                cases += [("negative", coordinate("POINT", [-1, 1]), .unsatisfied, .failed),
                    ("missing-data", point.removing(0x00700022), .unsatisfied, .failed),
                    ("missing-type", point.removing(0x00700023), .unsatisfied, .failed),
                    ("origin-unproven", point, .undetermined, .incomplete),
                    ("origin-frame", point.setting(text(0x00480301, "FRAME", .CS)), .unsatisfied, .passed),
                    ("origin-volume", point.setting(text(0x00480301, "VOLUME", .CS)), .unsatisfied, .passed),
                    ("origin-invalid", point.setting(text(0x00480301, "FUTURE", .CS)), .unsatisfied, .failed),
                    ("fiducial-empty", point.setting(.init(tag: 0x0070031A, vr: .UI, value: .empty)), .unsatisfied, .passed)]
            } else {
                let point = coordinate("POINT", [-1, 0, 1])
                cases += [("missing-reference", point.removing(0x30060024), .unsatisfied, .failed),
                    ("empty-reference", point.setting(.init(tag: 0x30060024, vr: .UI, value: .empty)), .unsatisfied, .failed),
                    ("polygon-open", coordinate("POLYGON", [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0]), .unsatisfied, .failed)]
            }
            total += cases.count
            for (name, item, tiled, expected) in cases {
                facts.referencedImageIsTiled = tiled
                var source = base.setting(sequence(0x0040A730, [item]))
                if kind == .spatial3D { source = source.removing(0x0040A375) }
                let read = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: source, purpose: .instance))
                XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed, name)
                let owned = try XCTUnwrap(read.dataSet)
                let raw = try XCTUnwrap(owned.sequenceItems(for: .contentSequence).first?.dataSet)
                let report = DicomSpatialCoordinatesMacro.validate(raw, kind: kind, conditions: facts)
                XCTAssertEqual(report[.attributes], expected, name)
                XCTAssertEqual(report[.pixelsAndGeometry], .notEvaluated)
                let composed = DicomSRContentValidator.validate(owned, spatialConditions: [[0]: facts])
                for diagnostic in report.diagnostics {
                    XCTAssertTrue(composed.diagnostics.contains { $0.code == diagnostic.code && $0.severity == diagnostic.severity &&
                        $0.path == [.tag(0x0040A730), .item(0)] + diagnostic.path && $0.requirement == diagnostic.requirement }, name)
                }
                if let directory = ProcessInfo.processInfo.environment["DICOM_SR_SPATIAL_CORPUS_DIRECTORY"] {
                    let folder = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let path = folder.appendingPathComponent(kind.rawValue.lowercased() + "-" + name)
                    try DicomDataSetWriter.part10Data(from: source, options: .init(validationPurpose: .instance))
                        .write(to: path.appendingPathExtension("dcm"))
                    try JSONSerialization.data(withJSONObject: ["attributes": report[.attributes].rawValue,
                        "diagnostics": report.diagnostics.map { $0.code.rawValue }, "structureAndVRVM": "passed",
                        "geometry": "notEvaluated", "tiled": tiled == .undetermined ? "unknown" : "false"])
                        .write(to: path.appendingPathExtension("json"))
                }
            }
        }
        XCTAssertEqual(total, 44)
    }
}
