import Foundation
import XCTest
@testable import DicomData

final class DicomSRRelationshipValidatorTests: XCTestCase {
    func test_forwardAndBackwardReferences_resolveOriginalOneBasedPositions() {
        for children in [[node("NUM", children: [reference([1, 2])]), node("TEXT")],
                         [node("TEXT"), node("NUM", children: [reference([1, 1])])]] {
            XCTAssertEqual(validate(root(children))[.references], .passed)
        }
        let dataSet = root([node("TEXT"), .init(), node("NUM", children: [reference([1, 2])])])
        let report = validate(dataSet)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .valueUnavailable &&
            $0.path == [.tag(0x0040A730), .item(2), .tag(0x0040A730), .item(0), .tag(0x0040DB73)] })
        XCTAssertFalse(report.diagnostics.contains { $0.code == .contentReferenceTargetMissing })
    }

    func test_invalidIdentifiersAndMissingTargets_failWithoutLeakingValues() {
        for identifier: [UInt] in [[], [0], [2], [1, 0], [1, UInt(UInt32.max) + 1]] {
            let report = validate(root([node("NUM", children: [reference(identifier)])]))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .contentReferenceIdentifierInvalid })
        }
        let missing = validate(root([node("NUM", children: [reference([1, 99])])]))
        XCTAssertTrue(missing.diagnostics.contains { $0.code == .contentReferenceTargetMissing &&
            $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A730), .item(0), .tag(0x0040DB73)] })
    }

    func test_referenceTargets_mustBeByValueAndCannotBeAncestors() {
        let chained = root([node("NUM", children: [reference([1, 2, 1])]),
                            node("NUM", children: [reference([1, 1])])])
        XCTAssertTrue(validate(chained).diagnostics.contains { $0.code == .contentReferenceTargetNotByValue })
        for identifier: [UInt] in [[1], [1, 1]] {
            XCTAssertTrue(validate(root([node("NUM", children: [reference(identifier)])])).diagnostics.contains {
                $0.code == .contentReferenceAncestorForbidden
            })
        }
        let rootReference = root([]).setting(.init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1])))
        XCTAssertTrue(validate(rootReference).diagnostics.contains { $0.code == .contentReferenceIdentifierInvalid })
    }

    func test_opaqueTargetSubtree_remainsUnavailableRatherThanMissing() {
        let opaque = node("CONTAINER").setting(.init(tag: 0x0040A730, vr: .UN, value: .bytes(Data([1, 2]))))
        let report = validate(root([opaque, node("NUM", children: [reference([1, 1, 1])])]))
        XCTAssertEqual(report[.references], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceTargetUnavailable })
        XCTAssertFalse(report.diagnostics.contains { $0.code == .contentReferenceTargetMissing })
        let absent = validate(root([node("CONTAINER"), node("NUM", children: [reference([1, 1, 1])])]))
        XCTAssertEqual(absent[.references], .failed)
    }

    func test_referenceItems_cannotContainNestedRelationships() {
        let invalid = reference([1, 2]).setting(sequence([node("TEXT")]))
        let report = validate(root([node("NUM", children: [invalid]), node("TEXT")]))
        XCTAssertTrue(report.diagnostics.contains { $0.code == .relationshipNotAllowed && $0.path.last == .tag(0x0040A730) })
    }

    func test_profileSpecificByReferenceRestrictions_areEnforced() {
        let allowed = root([node("NUM", children: [reference([1, 2])]), node("TEXT")])
        XCTAssertEqual(validate(allowed)[.references], .passed)
        for suffix in ["22", "59"] {
            XCTAssertTrue(validate(allowed.setting(text(0x00080016, sop(suffix), .UI))).diagnostics.contains {
                $0.code == .relationshipNotAllowed
            })
        }
        for relationship in ["CONTAINS", "HAS CONCEPT MOD"] {
            let dataSet = root([node("CONTAINER", children: [reference([1, 2], relationship)]), node("CODE")])
            XCTAssertTrue(validate(dataSet).diagnostics.contains { $0.code == .relationshipNotAllowed })
        }
    }

    func test_relationshipTables_preserveEnhancedComprehensiveAndKOSDifferences() {
        let cases: [(String, String, String, Set<String>)] = [
            ("CONTAINER", "CONTAINS", "NUM", ["22", "33"]),
            ("CONTAINER", "CONTAINS", "IMAGE", ["22", "33", "59"]),
            ("NUM", "HAS OBS CONTEXT", "TEXT", ["33"]),
            ("CONTAINER", "HAS OBS CONTEXT", "COMPOSITE", ["22", "33"]),
            ("CONTAINER", "HAS OBS CONTEXT", "CONTAINER", ["22", "33", "59"]),
            ("IMAGE", "HAS ACQ CONTEXT", "CONTAINER", ["33"]),
            ("IMAGE", "HAS ACQ CONTEXT", "NUM", ["22", "33", "59"]),
            ("NUM", "HAS ACQ CONTEXT", "CODE", ["22", "33"]),
            ("CONTAINER", "HAS CONCEPT MOD", "TEXT", ["22", "33"]),
            ("CONTAINER", "HAS CONCEPT MOD", "CODE", ["22", "33", "59"]),
            ("TEXT", "HAS PROPERTIES", "CONTAINER", ["33"]),
            ("NUM", "INFERRED FROM", "CONTAINER", ["33"]),
            ("PNAME", "HAS PROPERTIES", "TEXT", ["22", "33"]),
            ("PNAME", "HAS PROPERTIES", "NUM", []),
            ("SCOORD", "SELECTED FROM", "IMAGE", ["22", "33"]),
            ("TCOORD", "SELECTED FROM", "WAVEFORM", ["22", "33"]),
            ("IMAGE", "SELECTED FROM", "SCOORD", []),
            ("CONTAINER", "CONTAINS", "SCOORD3D", [])
        ]
        for (source, relationship, target, profiles) in cases {
            for suffix in ["22", "33", "59"] {
                let constraints = DicomSRRelationshipConstraints(rawValue: sop(suffix))!
                XCTAssertEqual(constraints.permits(source: source, relationship: relationship, target: target, byReference: false),
                    profiles.contains(suffix), "\(suffix): \(source) / \(relationship) / \(target)")
            }
        }
        let invalid = root([node("TEXT", children: [node("IMAGE", "SELECTED FROM")])])
        XCTAssertTrue(validate(invalid).diagnostics.contains { $0.code == .relationshipNotAllowed &&
            $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A730), .item(0), .tag(0x0040A010)] })
    }

    func test_unknownProfile_doesNotApproveRelationshipsOrHideMissingTargets() {
        let unknown = root([node("TEXT")]).setting(text(0x00080016, sop("35"), .UI))
        XCTAssertEqual(validate(unknown)[.references], .incomplete)
        let missing = unknown.setting(sequence([node("NUM", children: [reference([1, 3])])]))
        XCTAssertEqual(validate(missing)[.references], .failed)
        XCTAssertTrue(validate(missing).diagnostics.contains { $0.code == .referenceRuleUnavailable })
    }

    func test_limits_boundTraversalAndIdentifierWorkWithoutApprovingPartialGraphs() {
        let dataSet = root([node("NUM", children: [reference([1, 2])]), node("TEXT")])
        for limits in [DicomAttributeValidator.Limits(maximumDepth: 1),
                       .init(maximumRuleEvaluations: 1), .init(maximumRuleEvaluations: 7)] {
            let report = DicomSRRelationshipValidator.validate(dataSet, limits: limits)
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
            XCTAssertLessThanOrEqual(report.diagnostics.count, limits.maximumDiagnostics + 1)
        }
        let invalid = root((0..<10).map { _ in reference([0]) })
        let bounded = DicomSRRelationshipValidator.validate(invalid, limits: .init(maximumDiagnostics: 2))
        XCTAssertEqual(bounded.diagnostics.count, 3)
        XCTAssertEqual(bounded[.references], .failed)
    }

    private func validate(_ dataSet: DicomDataSet) -> DicomValidationReport { DicomSRRelationshipValidator.validate(dataSet) }
    private func sop(_ suffix: String) -> String { "1.2.840.10008.5.1.4.1.1.88." + suffix }
    private func root(_ children: [DicomDataSet]) -> DicomDataSet {
        node("CONTAINER", children: children).removing(0x0040A010).setting(text(0x00080016, sop("33"), .UI))
    }

    private func node(_ type: String, _ relationship: String = "CONTAINS", children: [DicomDataSet] = []) -> DicomDataSet {
        var dataSet = DicomDataSet(elements: [text(0x0040A040, type, .CS), text(0x0040A010, relationship, .CS)])
        if !children.isEmpty { dataSet = dataSet.setting(sequence(children)) }
        return dataSet
    }

    private func reference(_ identifier: [UInt], _ relationship: String = "INFERRED FROM") -> DicomDataSet {
        .init(elements: [text(0x0040A010, relationship, .CS), .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers(identifier))])
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    private func sequence(_ children: [DicomDataSet]) -> DicomDataElement {
        .init(tag: 0x0040A730, vr: .SQ, value: .sequence(children.map { .init(dataSet: $0) }))
    }
}
