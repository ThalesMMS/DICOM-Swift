import Foundation
import XCTest
@testable import DicomCore

final class DicomSRSpatialGeometryTests: XCTestCase {
    func test_nonplanarPolygon_failsGeometryAtOriginalItemPath() {
        let polygon = item("SCOORD3D", "POLYGON", [0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0])
        let report = DicomSRContentValidator.validate(root([.init(), polygon]))
        XCTAssertEqual(report[.pixelsAndGeometry], .failed)
        XCTAssertTrue(report.diagnostics.contains { $0.layer == .pixelsAndGeometry && $0.severity == .error &&
            $0.path == [.tag(0x0040A730), .item(1), .tag(0x00700022)] })
    }

    func test_ellipseWithDifferentAxisCenters_failsGeometricLayer() {
        let ellipse = item("SCOORD", "ELLIPSE", [0, 2, 4, 2, 3, 1, 3, 3])
        XCTAssertEqual(DicomSRContentValidator.validate(root([ellipse]))[.pixelsAndGeometry], .failed)
    }

    func test_incompleteSpatialTraversal_cannotLeaveEarlierGeometryApproved() {
        let ellipse = item("SCOORD3D", "ELLIPSE", [-2, 0, 0, 2, 0, 0, 0, -1, 0, 0, 1, 0])
        let report = DicomSRContentValidator.validate(root(Array(repeating: ellipse, count: 20)),
            limits: .init(maximumRuleEvaluations: 500))
        XCTAssertEqual(report[.pixelsAndGeometry], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached && $0.layer == .pixelsAndGeometry })
    }

    func test_intrinsicTwoDimensionalShape_doesNotApproveUnknownImageBounds() {
        let ellipse = item("SCOORD", "ELLIPSE", [0, 2, 4, 2, 2, 1, 2, 3]).removing(0x30060024)
        let report = DicomSRContentValidator.validate(root([ellipse]))
        XCTAssertEqual(report[.pixelsAndGeometry], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceTargetUnavailable && $0.layer == .pixelsAndGeometry })
    }

    func test_opaqueContentAfterOrBeforeGeometry_cannotApproveUnvisitedShapes() {
        let ellipse = item("SCOORD3D", "ELLIPSE", [-2, 0, 0, 2, 0, 0, 0, -1, 0, 0, 1, 0])
        let opaque = DicomDataSet(elements: [text(0x0040A040, "CONTAINER"), text(0x0040A010, "CONTAINS"),
            text(0x0040A050, "SEPARATE"), .init(tag: 0x0040A730, vr: .UN, value: .bytes(Data([0, 0])))])
        for children in [[ellipse, opaque], [opaque, ellipse]] {
            let report = DicomSRContentValidator.validate(root(children))
            let index = children[0].contains(0x00700022) ? 1 : 0
            XCTAssertEqual(report[.pixelsAndGeometry], .incomplete)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .valueUnavailable && $0.layer == .pixelsAndGeometry &&
                $0.path == [.tag(0x0040A730), .item(index), .tag(0x0040A730)] })
        }
    }

    private func root(_ items: [DicomDataSet]) -> DicomDataSet {
        .init(elements: [text(0x0040A040, "CONTAINER"), text(0x0040A050, "SEPARATE"),
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))])
    }
    private func item(_ type: String, _ graphic: String, _ values: [Double]) -> DicomDataSet {
        .init(elements: [text(0x0040A040, type), text(0x0040A010, "CONTAINS"), text(0x00700023, graphic),
            .init(tag: 0x00700022, vr: .FL, value: .floats(values)), .init(tag: 0x30060024, vr: .UI, value: .strings(["2.25.2321"]))])
    }
    private func text(_ tag: Int, _ value: String) -> DicomDataElement { .init(tag: tag, vr: .CS, value: .strings([value])) }
}
