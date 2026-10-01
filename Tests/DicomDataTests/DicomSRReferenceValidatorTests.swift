import Foundation
import XCTest
@testable import DicomData

final class DicomSRReferenceValidatorTests: XCTestCase {
    func test_matchingEvidence_requiresExternalIdentityBeforePassingReferences() {
        let dataSet = document()
        let unavailable = DicomSRReferenceValidator.validate(dataSet, kind: .structuredReport)
        XCTAssertEqual(unavailable.report[.references], .incomplete)
        XCTAssertTrue(unavailable.report.diagnostics.contains { $0.code == .referenceTargetUnavailable })
        let complete = validate(dataSet)
        XCTAssertEqual(complete.report[.references], .passed)
        XCTAssertEqual(complete.report[.attributes], .notEvaluated)
        XCTAssertEqual(complete.documentConditions.currentProcedureEvidenceRequired, .satisfied)
    }

    func test_missingEvidence_reportsOriginalContentItemWithoutDisclosingIdentity() throws {
        let dataSet = document().removing(0x0040A375)
        let report = validate(dataSet).report
        XCTAssertEqual(report[.references], .failed)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .referenceEvidenceMissing && $0.path == [.tag(0x0040A730), .item(0), .tag(0x00081199), .item(0), .tag(0x00081155)]
        })
        let json = String(decoding: try JSONEncoder().encode(report.diagnostics), as: UTF8.self)
        XCTAssertFalse(json.contains("2.25.232130"))
    }

    func test_srAcceptsPertinentEvidenceButForbidsOverlapWithCurrentEvidence() {
        let study = evidence()
        let pertinent = document().removing(0x0040A375).setting(sequence(0x0040A385, [study]))
        XCTAssertEqual(validate(pertinent).report[.references], .passed)
        let overlap = document().setting(sequence(0x0040A385, [study]))
        XCTAssertTrue(validate(overlap).report.diagnostics.contains {
            $0.code == .referenceEvidenceConflict && $0.path.first == .tag(0x0040A385)
        })
    }

    func test_kosRejectsExtraneousEvidenceAndDoesNotSubstitutePertinentEvidence() {
        let extra = evidence(instance: "2.25.23213004")
        let dataSet = document().setting(sequence(0x0040A375, [evidence(), extra]))
        let report = DicomSRReferenceValidator.validate(dataSet, kind: .keyObjectSelection).report
        XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceEvidenceUnexpected })
        XCTAssertFalse(validate(dataSet).report.diagnostics.contains { $0.code == .referenceEvidenceUnexpected })
        let pertinent = document().removing(0x0040A375).setting(sequence(0x0040A385, [evidence()]))
        XCTAssertTrue(DicomSRReferenceValidator.validate(pertinent, kind: .keyObjectSelection).report.diagnostics.contains {
            $0.code == .referenceEvidenceMissing
        })
    }

    func test_identityContradictions_includeClassStudySeriesAndActualTargetUID() {
        let wrongClass = evidence(sopClass: "1.2.840.10008.5.1.4.1.1.4")
        XCTAssertTrue(validate(document().setting(sequence(0x0040A375, [wrongClass]))).report.diagnostics.contains {
            $0.code == .referenceIdentityContradiction && $0.path.last == .tag(0x00081150)
        })
        for duplicate in [wrongClass, evidence(study: "2.25.23213009"), evidence(series: "2.25.23213008")] {
            XCTAssertTrue(validate(document().setting(sequence(0x0040A375, [evidence(), duplicate]))).report.diagnostics.contains {
                $0.code == .referenceIdentityContradiction
            })
        }
        for tag in [0x00080018, 0x00080016, 0x0020000D, 0x0020000E] {
            let wrong = target().setting(text(tag, "2.25.23213099", .UI))
            XCTAssertEqual(DicomSRReferenceValidator.validate(document(), kind: .structuredReport,
                targets: ["2.25.23213003": wrong]).report[.references], .failed)
        }
    }

    func test_accompanyingPresentationStateAndRealWorldMap_areEvidenceMembers() {
        let presentation = sop(instance: "2.25.23213004", sopClass: "1.2.840.10008.5.1.4.1.1.11.1")
        let map = sop(instance: "2.25.23213005", sopClass: "1.2.840.10008.5.1.4.1.1.67")
        let image = sop().setting(sequence(0x00081199, [presentation])).setting(sequence(0x0008114B, [map]))
        let content = DicomDataSet(elements: [text(0x0040A040, "IMAGE", .CS), sequence(0x00081199, [image])])
        let dataSet = document().setting(sequence(0x0040A730, [content]))
        let missing = validate(dataSet).report.diagnostics.filter { $0.code == .referenceEvidenceMissing }
        XCTAssertEqual(missing.count, 2)
        XCTAssertTrue(missing.contains { $0.path == [.tag(0x0040A730), .item(0), .tag(0x00081199), .item(0),
            .tag(0x0008114B), .item(0), .tag(0x00081155)] })
        let complete = dataSet.setting(sequence(0x0040A375, [evidence(), evidence(instance: "2.25.23213004", sopClass: "1.2.840.10008.5.1.4.1.1.11.1"),
            evidence(instance: "2.25.23213005", sopClass: "1.2.840.10008.5.1.4.1.1.67")]))
        XCTAssertFalse(validate(complete).report.diagnostics.contains { $0.code == .referenceEvidenceMissing })
    }

    func test_opaqueOrMalformedSequences_doNotProveAbsentReferences() {
        for element in [DicomDataElement(tag: 0x0040A375, vr: .UN, value: .bytes(Data([1, 2]))),
                        text(0x0040A375, "INVALID", .LO)] {
            let report = validate(document().setting(element)).report
            XCTAssertNotEqual(report[.references], .passed)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .referenceEvidenceMissing })
        }
        let unknown = document().setting(sequence(0x0040A730, [.init(elements: [text(0x0040A040, "FUTURE", .CS)])]))
        let report = DicomSRReferenceValidator.validate(unknown, kind: .keyObjectSelection).report
        XCTAssertEqual(report[.references], .incomplete)
        XCTAssertFalse(report.diagnostics.contains { $0.code == .referenceEvidenceUnexpected })
    }

    func test_kosMultiStudyCondition_requiresCompleteGraphToProveFalse() {
        let single = DicomSRReferenceValidator.validate(document(), kind: .keyObjectSelection)
        XCTAssertEqual(single.documentConditions.identicalDocumentsRequired, .unsatisfied)
        let multi = document().setting(sequence(0x0040A375, [evidence(),
            evidence(instance: "2.25.23213004", study: "2.25.23213009", series: "2.25.23213008")]))
        XCTAssertEqual(DicomSRReferenceValidator.validate(multi, kind: .keyObjectSelection)
            .documentConditions.identicalDocumentsRequired, .satisfied)
        let absent = DicomSRReferenceValidator.validate(document().removing(0x0040A375), kind: .keyObjectSelection)
        XCTAssertEqual(absent.documentConditions.identicalDocumentsRequired, .undetermined)
        let interrupted = DicomSRReferenceValidator.validate(multi, kind: .keyObjectSelection,
            limits: .init(maximumRuleEvaluations: 6))
        XCTAssertEqual(interrupted.documentConditions.identicalDocumentsRequired, .undetermined)
        XCTAssertTrue(interrupted.report.diagnostics.contains { $0.code == .evaluationLimitReached })
    }

    func test_signatureRelations_remainExplicitlyUnqualified() {
        for tag in [0x04000402, 0x04000403] {
            let image = sop().setting(text(tag, "1", .IS))
            let child = DicomDataSet(elements: [text(0x0040A040, "IMAGE", .CS), sequence(0x00081199, [image])])
            let report = validate(document().setting(sequence(0x0040A730, [child]))).report
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceRuleUnavailable && $0.path.last == .tag(tag) })
        }
    }

    func test_intradocumentReferences_areQualifiedByTheComposedRelationshipComponent() {
        let byReference = DicomDataSet(elements: [.init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1, 1]))])
        let dataSet = document().setting(sequence(0x0040A730, [byReference]))
        let objects = validate(dataSet).report
        XCTAssertEqual(objects[.references], .passed) // No external content references were introduced.
        let relationships = DicomSRRelationshipValidator.validate(dataSet)
        XCTAssertEqual(objects.merging(relationships)[.references], .failed) // Target is another reference, not a value.
    }

    func test_limits_boundDepthWidthAndDiagnosticsPreservingEarlierErrors() {
        let child = DicomDataSet(elements: [text(0x0040A040, "IMAGE", .CS), sequence(0x00081199, [sop()])])
        let wide = document().removing(0x0040A375).setting(sequence(0x0040A730, Array(repeating: child, count: 50)))
        let report = DicomSRReferenceValidator.validate(wide, kind: .structuredReport,
            limits: .init(maximumDiagnostics: 2)).report
        XCTAssertEqual(report[.references], .failed)
        XCTAssertEqual(report.diagnostics.count, 3)
        XCTAssertEqual(report.diagnostics.last?.code, .evaluationLimitReached)
        var deep = child
        for _ in 0..<20 { deep = .init(elements: [text(0x0040A040, "CONTAINER", .CS), sequence(0x0040A730, [deep])]) }
        let truncated = DicomSRReferenceValidator.validate(deep, kind: .structuredReport,
            limits: .init(maximumDepth: 4)).report
        XCTAssertEqual(truncated[.references], .incomplete)
        XCTAssertEqual(truncated.diagnostics.first?.code, .evaluationLimitReached)
    }

    func test_unusableSourceAndTargetUIDs_areUnavailableInsteadOfSuccessfulMatches() {
        for invalid in ["", "PRIVATE SENTINEL", "2.25.01", "2.25.*"] {
            let child = DicomDataSet(elements: [text(0x0040A040, "IMAGE", .CS), sequence(0x00081199, [sop(instance: invalid)])])
            let dataSet = document().setting(sequence(0x0040A730, [child]))
            let report = validate(dataSet).report
            XCTAssertEqual(report[.references], .incomplete)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .valueUnavailable })
        }
        let noTargetUID = target().removing(0x00080018)
        let report = DicomSRReferenceValidator.validate(document(), kind: .structuredReport,
            targets: ["2.25.23213003": noTargetUID]).report
        XCTAssertEqual(report[.references], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .valueUnavailable })
    }

    func test_conflictingContentClasses_failEvenWithoutUsableEvidenceOrTargets() {
        let children = [sop(), sop(sopClass: "1.2.840.10008.5.1.4.1.1.4")].map {
            DicomDataSet(elements: [text(0x0040A040, "IMAGE", .CS), sequence(0x00081199, [$0])])
        }
        let dataSet = document().setting(sequence(0x0040A730, children))
            .setting(.init(tag: 0x0040A375, vr: .UN, value: .bytes(Data([1, 2]))))
        let report = DicomSRReferenceValidator.validate(dataSet, kind: .structuredReport).report
        XCTAssertEqual(report[.references], .failed)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .referenceIdentityContradiction && $0.path == [.tag(0x0040A730), .item(1),
                .tag(0x00081199), .item(0), .tag(0x00081150)]
        })
    }

    func test_oneSeriesInTwoStudies_isContradictoryEvenForDistinctInstances() {
        let dataSet = document().setting(sequence(0x0040A375, [evidence(),
            evidence(instance: "2.25.23213004", study: "2.25.23213009")]))
        let report = DicomSRReferenceValidator.validate(dataSet, kind: .structuredReport).report
        XCTAssertEqual(report[.references], .failed)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceIdentityContradiction })
    }

    private func validate(_ dataSet: DicomDataSet) -> DicomSRReferenceValidator.Result {
        DicomSRReferenceValidator.validate(dataSet, kind: .structuredReport, targets: ["2.25.23213003": target()])
    }

    private func document() -> DicomDataSet {
        .init(elements: [text(0x0040A040, "CONTAINER", .CS), text(0x0020000D, "2.25.23213001", .UI),
            sequence(0x0040A730, [.init(elements: [text(0x0040A040, "IMAGE", .CS), sequence(0x00081199, [sop()])])]),
            sequence(0x0040A375, [evidence()])])
    }

    private func evidence(instance: String = "2.25.23213003", study: String = "2.25.23213001",
                          series: String = "2.25.23213002", sopClass: String = "1.2.840.10008.5.1.4.1.1.2.1") -> DicomDataSet {
        .init(elements: [text(0x0020000D, study, .UI), sequence(0x00081115, [
            .init(elements: [text(0x0020000E, series, .UI), sequence(0x00081199, [sop(instance: instance, sopClass: sopClass)])])
        ])])
    }

    private func sop(instance: String = "2.25.23213003", sopClass: String = "1.2.840.10008.5.1.4.1.1.2.1") -> DicomDataSet {
        .init(elements: [text(0x00081150, sopClass, .UI), text(0x00081155, instance, .UI)])
    }

    private func target() -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.2.1", .UI), text(0x00080018, "2.25.23213003", .UI),
            text(0x0020000D, "2.25.23213001", .UI), text(0x0020000E, "2.25.23213002", .UI)])
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
