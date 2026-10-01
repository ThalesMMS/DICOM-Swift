import Foundation
import XCTest
@testable import DicomCore

final class DicomSRSpatialContentTests: XCTestCase {
    func test_spatialItems_requireTheirTypedValuesAndFrameOfReference() {
        for type in ["SCOORD", "SCOORD3D"] {
            let source = item(type)
            let report = validate(source)
            for tag in [0x00700022, 0x00700023] {
                XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(tag)] })
            }
            if type == "SCOORD3D" {
                XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x30060024)] })
            }
        }
    }

    func test_spatialPoint_cardinalityUsesItsDeclaredDimension() {
        for (type, values) in [("SCOORD", [1.0, 2, 3]), ("SCOORD3D", [1.0, 2])] {
            let source = item(type).setting(text(0x00700023, "POINT", .CS))
                .setting(.init(tag: 0x00700022, vr: .FL, value: .floats(values)))
            XCTAssertTrue(validate(source).diagnostics.contains { $0.code == .invalidMultiplicity && $0.path == [.tag(0x00700022)] })
        }
    }

    func test_originalItemPaths_selectOnlyTheirOwnTiledImageCondition() {
        let spatial = item("SCOORD").setting(text(0x00700023, "POINT", .CS))
            .setting(.init(tag: 0x00700022, vr: .FL, value: .floats([1, 2])))
        let root = DicomDataSet(elements: [text(0x0040A040, "CONTAINER", .CS), text(0x0040A050, "SEPARATE", .CS),
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence([.init(dataSet: spatial), .init(dataSet: spatial)]))])
        var facts = DicomSpatialCoordinatesMacro.Conditions()
        facts.referencedImageIsTiled = .unsatisfied
        let report = DicomSRContentValidator.validate(root, spatialConditions: [[1]: facts])
        XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionUndetermined &&
            $0.path == [.tag(0x0040A730), .item(0), .tag(0x00480301)] })
        XCTAssertFalse(report.diagnostics.contains { $0.path == [.tag(0x0040A730), .item(1), .tag(0x00480301)] })
    }

    private func validate(_ source: DicomDataSet) -> DicomValidationReport {
        DicomAttributeValidator.validate(source, rules: DicomSRContentRules.rules(for: source, isRoot: false, versionRequirements: [:]))
    }
    private func item(_ type: String) -> DicomDataSet { .init(elements: [text(0x0040A040, type, .CS), text(0x0040A010, "CONTAINS", .CS)]) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
}
