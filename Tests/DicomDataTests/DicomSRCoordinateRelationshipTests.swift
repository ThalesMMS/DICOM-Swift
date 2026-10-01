import Foundation
import XCTest
@testable import DicomData

final class DicomSRCoordinateRelationshipTests: XCTestCase {
    func test_coordinatesWithoutSelection_failAtOriginalSourceContentSequence() {
        for type in ["SCOORD", "TCOORD"] {
            for children in [[], [node("CODE", "HAS CONCEPT MOD")]] {
                let report = validate(root([node("TEXT"), node(type, children: children)]))
                XCTAssertEqual(report[.references], .failed)
                XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredRelationshipMissing &&
                    $0.path == [.tag(0x0040A730), .item(1), .tag(0x0040A730)] })
            }
        }
    }

    func test_selectedFromByValue_andForwardBackwardReferencesSatisfyRequirement() {
        for type in ["SCOORD", "TCOORD"] {
            XCTAssertEqual(validate(root([node(type, children: [node("IMAGE", "SELECTED FROM")])]))[.references], .passed)
            for children in [[node(type, children: [reference([1, 2])]), node("IMAGE")],
                             [node("IMAGE"), node(type, children: [reference([1, 1])])]] {
                XCTAssertEqual(validate(root(children))[.references], .passed)
            }
        }
        XCTAssertEqual(validate(root([node("TCOORD", children: [node("WAVEFORM", "SELECTED FROM")])]))[.references], .passed)
        let spatial = node("SCOORD", "SELECTED FROM", children: [node("IMAGE", "SELECTED FROM")])
        XCTAssertEqual(validate(root([node("TCOORD", children: [spatial])]))[.references], .passed)
    }

    func test_wrongTargetOrRelationship_cannotSatisfySelectionRequirement() {
        for target in [node("WAVEFORM", "SELECTED FROM"), node("IMAGE", "HAS PROPERTIES")] {
            let report = validate(root([node("SCOORD", children: [target])]))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .relationshipNotAllowed })
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredRelationshipMissing })
        }
        let report = validate(root([node("TCOORD", children: [node("TEXT", "SELECTED FROM")])]))
        XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredRelationshipMissing })
    }

    func test_opaqueChildrenOrUnresolvedSelectionMetadata_cannotProveMissingRelationship() {
        let opaque = node("SCOORD").setting(.init(tag: 0x0040A730, vr: .UN, value: .bytes(Data([0, 0]))))
        let unknownRelationship = node("IMAGE", "SELECTED FROM").removing(0x0040A010)
        let unknownType = node("IMAGE", "SELECTED FROM").removing(0x0040A040)
        let unknownReference = reference([1, 2]).setting(.init(tag: 0x0040DB73, vr: .UN, value: .bytes(Data([0, 0]))))
        for source in [opaque, node("SCOORD", children: [unknownRelationship]), node("SCOORD", children: [unknownType]),
                       node("SCOORD", children: [unknownReference])] {
            let report = validate(root([source]))
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .requiredRelationshipMissing })
        }
    }

    func test_missingSelectionTarget_preservesItsSpecificError() {
        let report = validate(root([node("SCOORD", children: [reference([1, 99])])]))
        XCTAssertEqual(report[.references], .failed)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .contentReferenceTargetMissing })
    }

    func test_interruptedTraversal_doesNotConvertUnseenSelectionsIntoAbsence() {
        let source = node("SCOORD", children: [node("IMAGE", "SELECTED FROM")])
        let report = DicomSRRelationshipValidator.validate(root([source]), limits: .init(maximumRuleEvaluations: 2))
        XCTAssertEqual(report[.references], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
        XCTAssertFalse(report.diagnostics.contains { $0.code == .requiredRelationshipMissing })
    }

    func test_spatial3D_doesNotInheritTheTwoDimensionalSelectionRequirement() {
        let source = root([node("SCOORD3D")]).setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.88.34", .UI))
        let report = validate(source)
        // Comprehensive 3D (A.35.13) is qualified since #2345: SCOORD3D needs no SELECTED FROM IMAGE.
        XCTAssertEqual(report[.references], .passed)
        XCTAssertFalse(report.diagnostics.contains { $0.code == .requiredRelationshipMissing })
    }

    func test_requiredSelectionChecks_shareTheDiagnosticBudgetAndStableTraversalOrder() {
        let source = root((0..<10).map { _ in node("SCOORD") })
        let report = DicomSRRelationshipValidator.validate(source, limits: .init(maximumDiagnostics: 2))
        XCTAssertEqual(report[.references], .failed)
        XCTAssertEqual(report.diagnostics.map(\.code), [.requiredRelationshipMissing, .requiredRelationshipMissing, .evaluationLimitReached])
        for (index, diagnostic) in report.diagnostics.enumerated() {
            XCTAssertEqual(diagnostic.path, [.tag(0x0040A730), .item(index), .tag(0x0040A730)])
        }
    }

    private func validate(_ dataSet: DicomDataSet) -> DicomValidationReport { DicomSRRelationshipValidator.validate(dataSet) }
    private func root(_ children: [DicomDataSet]) -> DicomDataSet {
        node("CONTAINER", children: children).removing(0x0040A010)
            .setting(text(0x00080016, "1.2.840.10008.5.1.4.1.1.88.33", .UI))
    }
    private func node(_ type: String, _ relationship: String = "CONTAINS", children: [DicomDataSet] = []) -> DicomDataSet {
        var result = DicomDataSet(elements: [text(0x0040A040, type, .CS), text(0x0040A010, relationship, .CS)])
        if !children.isEmpty { result = result.setting(.init(tag: 0x0040A730, vr: .SQ, value: .sequence(children.map { .init(dataSet: $0) }))) }
        return result
    }
    private func reference(_ identifier: [UInt]) -> DicomDataSet {
        .init(elements: [text(0x0040A010, "SELECTED FROM", .CS), .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers(identifier))])
    }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
}
