import Foundation
import XCTest
@testable import DicomCore

final class DicomSRTemporalContentTests: XCTestCase {
    func test_temporalItem_requiresRangeAndExactlyOneRepresentation() {
        let empty = item()
        let report = validate(empty)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A130)] })
        let conflict = empty.setting(text(0x0040A130, "POINT", .CS)).setting(text(0x0040A138, "0", .DS))
            .setting(text(0x0040A13A, "20260908", .DT))
        XCTAssertTrue(validate(conflict).diagnostics.contains { $0.code == .conditionalAttributeForbidden })
    }

    func test_temporalItem_rejectsWrongRangeCardinality() {
        let source = item().setting(text(0x0040A130, "SEGMENT", .CS)).setting(text(0x0040A138, "0", .DS))
        XCTAssertTrue(validate(source).diagnostics.contains { $0.code == .invalidMultiplicity && $0.path == [.tag(0x0040A138)] })
    }

    func test_byReferenceItem_doesNotAcquireTemporalValueRequirements() {
        let source = DicomDataSet(elements: [text(0x0040A010, "SELECTED FROM", .CS),
            .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1, 1]))])
        XCTAssertEqual(validate(source)[.attributes], .passed)
    }

    func test_composedTraversal_preservesOriginalConditionAndDiagnosticPaths() {
        let temporal = item().setting(text(0x0040A130, "POINT", .CS))
            .setting(.init(tag: 0x0040A132, vr: .UL, value: .unsignedIntegers([1])))
        let base = DicomDataSet(elements: [text(0x0040A040, "CONTAINER", .CS), text(0x0040A050, "SEPARATE", .CS),
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence([.init(dataSet: temporal), .init(dataSet: temporal)]))])
        var facts = DicomTemporalCoordinatesMacro.Conditions()
        facts.referencesWaveform = .satisfied
        facts.channelsUseSingleMultiplexGroup = .satisfied
        let report = DicomSRContentValidator.validate(base, temporalConditions: [[1]: facts])
        XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionUndetermined &&
            $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A132)] })
        XCTAssertFalse(report.diagnostics.contains { $0.layer == .attributes && $0.path == [.tag(0x0040A730), .item(1), .tag(0x0040A132)] })
        for index in 0...1 {
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceTargetUnavailable && $0.layer == .pixelsAndGeometry &&
                $0.path == [.tag(0x0040A730), .item(index), .tag(0x0040A132)] })
        }
    }

    private func validate(_ source: DicomDataSet) -> DicomValidationReport {
        DicomAttributeValidator.validate(source, rules: DicomSRContentRules.rules(for: source, isRoot: false, versionRequirements: [:]))
    }
    private func item() -> DicomDataSet { .init(elements: [text(0x0040A040, "TCOORD", .CS), text(0x0040A010, "CONTAINS", .CS)]) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
}
