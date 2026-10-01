import Foundation
import XCTest
@testable import DicomCore

extension DicomSRDocumentModuleCorpusTests {
    func test_spatialTargetCorpus_resolvesWireIdentityOriginAndBounds() throws {
        let cases: [(String, [Double], String?, DicomValidationReport.Outcome)] = [
            ("frame-zero", [0, 0], nil, .passed), ("frame-edge", [9, 7], nil, .passed),
            ("frame-column-out", [10, 7], nil, .failed), ("frame-row-out", [9, 8], nil, .failed),
            ("tiled-frame-out", [50, 60], "FRAME", .failed), ("tiled-volume", [90, 70], "VOLUME", .passed),
            ("tiled-volume-out", [91, 70], "VOLUME", .failed), ("tiled-origin-missing", [9, 7], nil, .passed),
            ("volume-matrix-missing", [1, 1], "VOLUME", .incomplete), ("target-missing", [1, 1], nil, .incomplete),
            ("target-wrong-identity", [1, 1], nil, .incomplete), ("target-row-missing", [1, 1], nil, .incomplete),
            ("target-row-zero", [1, 1], nil, .failed), ("target-frame-out", [1, 1], nil, .incomplete)
        ]
        for (name, point, origin, expected) in cases {
            let fixture = try spatialTargetFixture(point: point, origin: origin, frame: name == "target-frame-out" ? "3" : nil)
            var target = fixture.target
            if name.hasPrefix("tiled-") {
                target = target.setting(spatialDimension(0x00480006, 90, .UL)).setting(spatialDimension(0x00480007, 70, .UL))
            }
            if name == "target-wrong-identity" { target = target.setting(text(0x00080018, "2.25.23219999", .UI)) }
            if name == "target-row-missing" { target = target.removing(0x00280010) }
            if name == "target-row-zero" { target = target.setting(spatialDimension(0x00280010, 0, .US)) }
            let sourceRead = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: fixture.source, purpose: .instance))
            let targetRead = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: target, purpose: .instance))
            XCTAssertEqual(sourceRead.report.merging(targetRead.report).outcome(requiring: [.structure, .vrAndVM]), .passed, name)
            let source = try XCTUnwrap(sourceRead.dataSet)
            let targets = name == "target-missing" ? [:] : ["2.25.23212003": try XCTUnwrap(targetRead.dataSet)]
            let resolved = DicomSRSpatialReferenceValidator.validate(source, targets: targets)
            let composed = DicomSRContentValidator.validate(source, targets: targets)
            XCTAssertEqual(resolved.report[.pixelsAndGeometry], expected, name)
            XCTAssertEqual(composed[.pixelsAndGeometry], expected, name)
            XCTAssertFalse(composed.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path.isEmpty }, name)
            if expected == .failed || ["target-wrong-identity", "target-frame-out", "tiled-origin-missing"].contains(name) {
                XCTAssertTrue(composed.diagnostics.contains { $0.code == .semanticProjectionUnavailable &&
                    $0.path == [.tag(0x0040A730), .item(0)] }, name)
                XCTAssertNotEqual(composed[.operation], .passed, name)
            }
            if name == "tiled-origin-missing" {
                XCTAssertTrue(composed.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.requirement == .type1C &&
                    $0.path == [.tag(0x0040A730), .item(0), .tag(0x00480301)] }, name)
            }
            if expected == .passed {
                XCTAssertFalse(composed.diagnostics.contains { $0.code == .referenceTargetUnavailable && $0.layer == .pixelsAndGeometry }, name)
            }
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_SPATIAL_TARGET_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                for (dataSet, suffix) in [(fixture.source, "dcm"), (target, "target.dcm")] {
                    try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance))
                        .write(to: path.appendingPathExtension(suffix))
                }
                try JSONSerialization.data(withJSONObject: ["structureAndVRVM": "passed",
                    "bounds": resolved.report[.pixelsAndGeometry].rawValue, "references": resolved.report[.references].rawValue,
                    "composedGeometry": composed[.pixelsAndGeometry].rawValue,
                    "tiled": resolved.spatialConditions[[0]]?.referencedImageIsTiled == .satisfied ? "satisfied" :
                        resolved.spatialConditions[[0]]?.referencedImageIsTiled == .unsatisfied ? "unsatisfied" : "undetermined",
                    "diagnostics": resolved.report.diagnostics.map { $0.code.rawValue }])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }

    func test_spatialTargetFacts_rejectCallerContradictionsAndShareTraversalBudget() throws {
        let fixture = try spatialTargetFixture(point: [1, 1])
        let targets = ["2.25.23212003": fixture.target]
        var contrary = DicomSpatialCoordinatesMacro.Conditions()
        contrary.referencedImageIsTiled = .satisfied
        let report = DicomSRContentValidator.validate(fixture.source, spatialConditions: [[0]: contrary], targets: targets)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .attributeValueContradiction &&
            $0.path == [.tag(0x0040A730), .item(0), .tag(0x00480301)] })
        XCTAssertTrue(report.diagnostics.contains { $0.code == .semanticProjectionUnavailable &&
            $0.path == [.tag(0x0040A730), .item(0)] })
        let graph = DicomSRSpatialReferenceValidator.validate(fixture.source, targets: targets)
        let limited = DicomSRContentValidator.validate(fixture.source, targets: targets,
            limits: .init(maximumRuleEvaluations: graph.evaluations))
        XCTAssertEqual(limited[.operation], .incomplete)
        XCTAssertEqual(limited[.pixelsAndGeometry], .incomplete)
        XCTAssertTrue(limited.diagnostics.contains { $0.code == .evaluationLimitReached })
        let invalid = try spatialTargetFixture(point: [10, 8])
        let capped = DicomSRContentValidator.validate(invalid.source, targets: targets, limits: .init(maximumDiagnostics: 1))
        XCTAssertEqual(capped[.pixelsAndGeometry], .failed)
        XCTAssertLessThanOrEqual(capped.diagnostics.count, 4) // Shared cap plus terminal attribute, operation and geometry limitations.
    }

    private func spatialTargetFixture(point: [Double], origin: String? = nil, frame: String? = nil) throws -> (source: DicomDataSet, target: DicomDataSet) {
        let base = try fixture(suffix: "33")
        var image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet).setting(text(0x0040A010, "SELECTED FROM", .CS))
        if let frame {
            let pair = try XCTUnwrap(image.sequenceItems(for: .referencedSOPSequence).first?.dataSet).setting(text(0x00081160, frame, .IS))
            image = image.setting(sequence(0x00081199, [pair]))
        }
        var coordinate = image.removing(0x00081199).setting(text(0x0040A010, "CONTAINS", .CS))
            .setting(text(0x0040A040, "SCOORD", .CS)).setting(text(0x00700023, "POINT", .CS))
            .setting(.init(tag: 0x00700022, vr: .FL, value: .floats(point))).setting(sequence(0x0040A730, [image]))
        if let origin { coordinate = coordinate.setting(text(0x00480301, origin, .CS)) }
        let target = target().setting(spatialDimension(0x00280010, 7, .US)).setting(spatialDimension(0x00280011, 9, .US))
            .setting(text(0x00280008, "2", .IS))
        return (base.setting(sequence(0x0040A730, [coordinate])), target)
    }

    private func spatialDimension(_ tag: Int, _ value: UInt, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .unsignedIntegers([value]))
    }
}
