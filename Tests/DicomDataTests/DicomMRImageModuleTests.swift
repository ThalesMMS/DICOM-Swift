import Foundation
import XCTest
@testable import DicomData

final class DicomMRImageModuleTests: XCTestCase {
    func test_part10Corpus_exportsValidEncodingForIndependentIODComparison() throws {
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("baseline", fixture(), .passed),
            ("missing-repetition", fixture().removing(0x00180080), .failed),
            ("ir-missing-time", fixture().setting(text(0x00180020, "IR", vr: .CS)), .failed),
            ("ir-empty-time", fixture().setting(text(0x00180020, "IR", vr: .CS))
                .setting(.init(tag: 0x00180082, vr: .DS, value: .empty)), .passed),
            ("wrong-high-bit", fixture().setting(number(0x00280102, 14)), .failed),
            ("gating-unknown", fixture().setting(text(0x00180022, "LOCAL_GATING", vr: .CS)), .incomplete),
            ("ep-first", fixture().setting(.init(tag: 0x00180020, vr: .CS, value: .strings(["EP", "GR"])))
                .removing(0x00180080), .passed),
            ("ep-second", fixture().setting(.init(tag: 0x00180020, vr: .CS, value: .strings(["GR", "EP"])))
                .removing(0x00180080), .passed),
            ("sk-second", fixture().setting(text(0x00180020, "EP", vr: .CS))
                .setting(.init(tag: 0x00180021, vr: .CS, value: .strings(["MTC", "SK"]))).removing(0x00180080), .failed)
        ]
        for (name, dataSet, expected) in cases {
            XCTAssertEqual(DicomMRImageModule.validate(dataSet)[.attributes], expected)
            try DicomImageModuleCorpus.export(dataSet, modality: "MR", name: name, outcome: expected)
        }
    }

    func test_spinEchoCorpus_acceptsMandatoryValuesAndRejectsEachMissingRequirement() {
        let valid = fixture()
        XCTAssertEqual(DicomMRImageModule.validate(valid)[.attributes], .passed)
        for tag in [0x00080008, 0x00280002, 0x00280004, 0x00280100, 0x00280101, 0x00280102,
                    0x00180020, 0x00180021, 0x00180022, 0x00180023, 0x00180080, 0x00180081, 0x00180091] {
            let report = DicomMRImageModule.validate(valid.removing(tag))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(tag)] })
        }
        XCTAssertEqual(DicomMRImageModule.validate(valid)[.codestream], .notEvaluated)
        XCTAssertEqual(DicomMRImageModule.validate(valid)[.operation], .notEvaluated)
    }

    func test_inversionRecovery_requiresEvenAnEmptyTimeAndForbidsItWhenNotApplicable() {
        let inversion = fixture().setting(text(0x00180020, "IR", vr: .CS))
        XCTAssertTrue(DicomMRImageModule.validate(inversion).diagnostics.contains { $0.path == [.tag(0x00180082)] })
        let time = DicomDataElement(tag: 0x00180082, vr: .DS, value: .empty)
        XCTAssertEqual(DicomMRImageModule.validate(inversion.setting(time))[.attributes], .passed)
        XCTAssertTrue(DicomMRImageModule.validate(fixture().setting(time)).diagnostics.contains {
            $0.code == .conditionalAttributeForbidden && $0.path == [.tag(0x00180082)]
        })
    }

    func test_echoPlanarAndSegmentedKSpace_distinguishRepetitionTimeConditions() {
        let echoPlanar = fixture().setting(text(0x00180020, "EP", vr: .CS)).removing(0x00180080)
        XCTAssertEqual(DicomMRImageModule.validate(echoPlanar)[.attributes], .passed)
        let segmented = echoPlanar.setting(text(0x00180021, "SK", vr: .CS))
        XCTAssertTrue(DicomMRImageModule.validate(segmented).diagnostics.contains { $0.path == [.tag(0x00180080)] })
        XCTAssertEqual(DicomMRImageModule.validate(echoPlanar.setting(text(0x00180080, "10", vr: .DS)))[.attributes], .passed)
    }

    func test_cardiacGating_coversKnownAbsentAndUnknownConditions() {
        for option in ["CG", "PPG"] {
            let gated = fixture().setting(text(0x00180022, option, vr: .CS))
            XCTAssertTrue(DicomMRImageModule.validate(gated).diagnostics.contains { $0.path == [.tag(0x00181060)] })
            XCTAssertEqual(DicomMRImageModule.validate(gated.setting(.init(tag: 0x00181060, vr: .DS, value: .empty)))[.attributes], .passed)
        }
        let unknown = fixture().setting(text(0x00180022, "LOCAL_GATING", vr: .CS))
        XCTAssertEqual(DicomMRImageModule.validate(unknown)[.attributes], .incomplete)
        XCTAssertEqual(DicomMRImageModule.validate(unknown, heartGating: .unsatisfied)[.attributes], .passed)
        XCTAssertEqual(DicomMRImageModule.validate(unknown, heartGating: .satisfied)[.attributes], .failed)
        let empty = fixture().setting(.init(tag: 0x00180022, vr: .CS, value: .empty))
        XCTAssertEqual(DicomMRImageModule.validate(empty)[.attributes], .incomplete)
    }

    func test_pixelAndSequenceContradictions_areRejectedWithoutRestrictingDefinedTerms() {
        for invalid in [number(0x00280002, 3), number(0x00280100, 8), number(0x00280101, 17),
                        number(0x00280102, 11), text(0x00280004, "RGB", vr: .CS),
                        text(0x00180023, "4D", vr: .CS), text(0x00180020, "UNKNOWN", vr: .CS)] {
            XCTAssertEqual(DicomMRImageModule.validate(fixture().setting(invalid))[.attributes], .failed)
        }
        let conflicting = DicomDataElement(tag: 0x00180020, vr: .CS, value: .strings(["SE", "GR"]))
        XCTAssertTrue(DicomMRImageModule.validate(fixture().setting(conflicting)).diagnostics.contains {
            $0.code == .attributeValueContradiction && $0.path == [.tag(0x00180020)]
        })
        XCTAssertEqual(DicomMRImageModule.validate(fixture().setting(text(0x00180021, "LOCAL_VARIANT", vr: .CS)))[.attributes], .passed)
    }

    func test_gatingCondition_reservesWorkBeforeUsingLateScanOptions() {
        let options = Array(repeating: "FS", count: 100) + ["CG"]
        let dataSet = fixture().setting(.init(tag: 0x00180022, vr: .CS, value: .strings(options)))
        let limited = DicomMRImageModule.validate(dataSet, heartGating: .unsatisfied,
            limits: .init(maximumRuleEvaluations: 100))
        XCTAssertEqual(limited[.attributes], .incomplete)
        XCTAssertEqual(limited.diagnostics.first?.code, .evaluationLimitReached)
        XCTAssertEqual(limited.diagnostics.first?.path, [.tag(0x00180022)])
        XCTAssertTrue(DicomMRImageModule.validate(dataSet, limits: .init(maximumRuleEvaluations: 1000)).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00181060)]
        })
    }

    func test_ruleProjection_doesNotReplaceOversizedSourceEvidenceWithExternalFallback() {
        let options = Array(repeating: "FS", count: 100_000) + ["CG"]
        let dataSet = fixture().setting(.init(tag: 0x00180022, vr: .CS, value: .strings(options)))
        let report = DicomAttributeValidator.validate(dataSet, rules: DicomMRImageModule.rules(for: dataSet, heartGating: .unsatisfied))
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionUndetermined && $0.path == [.tag(0x00181060)] })
    }

    private func fixture() -> DicomDataSet {
        .init(elements: [
            .init(tag: 0x00080008, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY", "OTHER"])),
            number(0x00280002, 1), text(0x00280004, "MONOCHROME2", vr: .CS),
            number(0x00280100, 16), number(0x00280101, 16), number(0x00280102, 15),
            text(0x00180020, "SE", vr: .CS), text(0x00180021, "NONE", vr: .CS),
            text(0x00180022, "FS", vr: .CS), text(0x00180023, "2D", vr: .CS),
            text(0x00180080, "500", vr: .DS), text(0x00180081, "10", vr: .DS),
            text(0x00180091, "1", vr: .IS)
        ])
    }

    private func text(_ tag: Int, _ value: String, vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement {
        .init(tag: tag, vr: .US, value: .unsignedIntegers([value]))
    }
}
