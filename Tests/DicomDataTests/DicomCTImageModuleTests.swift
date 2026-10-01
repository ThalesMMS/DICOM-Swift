import Foundation
import XCTest
@testable import DicomData

final class DicomCTImageModuleTests: XCTestCase {
    func test_codeMacroCorpus_exportsNestedPositiveAndNegativeCases() throws {
        let code = DicomDataSet(elements: [text(0x00080100, "113690", vr: .SH),
            text(0x00080102, "DCM", vr: .SH), text(0x00080104, "IEC Head Dosimetry Phantom", vr: .LO)])
        let variants: [(String, DicomDataValue, DicomValidationReport.Outcome)] = [
            ("code-baseline", .sequence([.init(dataSet: code)]), .passed),
            ("code-missing-meaning", .sequence([.init(dataSet: code.removing(0x00080104))]), .failed),
            ("code-missing-value", .sequence([.init(dataSet: code.removing(0x00080100))]), .failed),
            ("code-multiple-values", .sequence([.init(dataSet: code.setting(
                text(0x00080120, "urn:example:synthetic:2321", vr: .UR)))]), .failed),
            ("code-empty-phantom", .sequence([]), .failed),
            ("code-equivalent-missing-meaning", .sequence([.init(dataSet: code.setting(
                .init(tag: 0x00080121, vr: .SQ, value: .sequence([.init(dataSet: code.removing(0x00080104))]))))]), .failed)
        ]
        for (name, value, expected) in variants {
            let dataSet = fixture().setting(.init(tag: 0x00189346, vr: .SQ, value: value))
            XCTAssertEqual(DicomCTImageModule.validate(dataSet)[.attributes], expected)
            try DicomImageModuleCorpus.export(dataSet, modality: "CT", name: name, outcome: expected)
        }
    }

    func test_part10Corpus_exportsValidEncodingForIndependentIODComparison() throws {
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("baseline", fixture(), .passed),
            ("missing-rescale", fixture().removing(0x00281053), .failed),
            ("wrong-high-bit", fixture().setting(number(0x00280102, 14)), .failed),
            ("wrong-precision", fixture().setting(number(0x00280101, 11)), .failed),
            ("contradictory-units", fixture().setting(text(0x00281054, "US", vr: .LO)), .failed),
            ("derived-unknown-units", fixture().setting(.init(tag: 0x00080008, vr: .CS,
                value: .strings(["DERIVED", "PRIMARY", "AXIAL"]))), .incomplete)
        ]
        for (name, dataSet, expected) in cases {
            XCTAssertEqual(DicomCTImageModule.validate(dataSet)[.attributes], expected)
            try DicomImageModuleCorpus.export(dataSet, modality: "CT", name: name, outcome: expected)
        }
    }

    func test_originalAxialCorpus_checksRequiredAttributesAndStoredPrecision() {
        let valid = fixture()
        XCTAssertEqual(DicomCTImageModule.validate(valid)[.attributes], .passed)
        for tag in [0x00080008, 0x00280002, 0x00280004, 0x00280100, 0x00280101, 0x00280102,
                    0x00281052, 0x00281053, 0x00180060, 0x00200012] {
            XCTAssertTrue(DicomCTImageModule.validate(valid.removing(tag)).diagnostics.contains {
                $0.code == .requiredAttributeMissing && $0.path == [.tag(tag)]
            })
        }
        for bits in 12...16 {
            let sample = valid.setting(number(0x00280101, UInt(bits))).setting(number(0x00280102, UInt(bits - 1)))
            XCTAssertEqual(DicomCTImageModule.validate(sample)[.attributes], .passed)
        }
        for invalid in [number(0x00280101, 11), number(0x00280101, 17), number(0x00280102, 12),
                        number(0x00280100, 8), number(0x00280002, 3), text(0x00280004, "RGB", vr: .CS)] {
            XCTAssertEqual(DicomCTImageModule.validate(valid.setting(invalid))[.attributes], .failed)
        }
    }

    func test_rescaleUnits_cannotContradictOriginalHUOrGuessDerivedUnits() {
        XCTAssertEqual(DicomCTImageModule.validate(fixture().setting(text(0x00281054, "US", vr: .LO)))[.attributes], .failed)
        let derived = fixture().setting(.init(tag: 0x00080008, vr: .CS, value: .strings(["DERIVED", "PRIMARY", "AXIAL"])))
        XCTAssertEqual(DicomCTImageModule.validate(derived)[.attributes], .incomplete)
        XCTAssertEqual(DicomCTImageModule.validate(derived, rescaleUnitsAreHU: .satisfied)[.attributes], .passed)
        XCTAssertEqual(DicomCTImageModule.validate(derived, rescaleUnitsAreHU: .unsatisfied)[.attributes], .failed)
        XCTAssertEqual(DicomCTImageModule.validate(derived.setting(text(0x00281054, "US", vr: .LO)))[.attributes], .passed)
        let localizer = fixture().setting(.init(tag: 0x00080008, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY", "LOCALIZER"])))
        XCTAssertEqual(DicomCTImageModule.validate(localizer)[.attributes], .incomplete)
    }

    func test_multiEnergy_requiresRescaleTypeAndForbidsLegacyAdditionalSources() {
        let multi = fixture().setting(text(0x00189361, "YES", vr: .CS))
        XCTAssertTrue(DicomCTImageModule.validate(multi).diagnostics.contains { $0.path == [.tag(0x00281054)] })
        let withUnits = multi.setting(text(0x00281054, "HU", vr: .LO))
        XCTAssertEqual(DicomCTImageModule.validate(withUnits)[.attributes], .passed)
        let source = DicomDataElement(tag: 0x00189360, vr: .SQ, value: .sequence([.init(dataSet: sourceFixture())]))
        XCTAssertTrue(DicomCTImageModule.validate(withUnits.setting(source)).diagnostics.contains {
            $0.code == .conditionalAttributeForbidden && $0.path == [.tag(0x00189360)]
        })
    }

    func test_proportionalWeighting_requiresFactorInParentAndEachAdditionalSource() {
        let code = DicomDataSet(elements: [text(0x00080100, "113097", vr: .SH), text(0x00080102, "DCM", vr: .SH)])
        let dataSet = fixture().setting(.init(tag: 0x00089215, vr: .SQ, value: .sequence([.init(dataSet: code)])))
            .setting(.init(tag: 0x00189360, vr: .SQ, value: .sequence([.init(dataSet: sourceFixture())])))
        let missing = DicomCTImageModule.validate(dataSet)
        XCTAssertTrue(missing.diagnostics.contains { $0.path == [.tag(0x00189353)] })
        XCTAssertTrue(missing.diagnostics.contains { $0.path == [.tag(0x00189360), .item(0), .tag(0x00189353)] })
        let completeSource = sourceFixture().setting(.init(tag: 0x00189353, vr: .FL, value: .floats([0.4])))
        let complete = dataSet.setting(.init(tag: 0x00189353, vr: .FL, value: .floats([0.6])))
            .setting(.init(tag: 0x00189360, vr: .SQ, value: .sequence([.init(dataSet: completeSource)])))
        XCTAssertEqual(DicomCTImageModule.validate(complete)[.attributes], .passed)
        let unknown = fixture().setting(.init(tag: 0x00089215, vr: .SQ, value: .sequence([.init(dataSet: .init())])))
        XCTAssertEqual(DicomCTImageModule.validate(unknown)[.attributes], .incomplete)
    }

    func test_waterDiameter_requiresOneCodeItemAndDoesNotClaimUncheckedTerminologyPassed() {
        let dataSet = fixture().setting(.init(tag: 0x00181271, vr: .FD, value: .floats([200])))
        XCTAssertTrue(DicomCTImageModule.validate(dataSet).diagnostics.contains { $0.path == [.tag(0x00181272)] })
        for count in [0, 2] {
            let codes = DicomDataElement(tag: 0x00181272, vr: .SQ,
                value: .sequence(Array(repeating: .init(dataSet: .init()), count: count)))
            XCTAssertEqual(DicomCTImageModule.validate(dataSet.setting(codes))[.attributes], .failed)
        }
        let one = DicomDataElement(tag: 0x00181272, vr: .SQ, value: .sequence([.init(dataSet: .init())]))
        XCTAssertEqual(DicomCTImageModule.validate(dataSet.setting(one))[.attributes], .failed)
    }

    func test_ctCodeSequences_validateEveryItemAndRetainContextGroupLimitations() {
        let base = fixture().setting(.init(tag: 0x00181271, vr: .FD, value: .floats([200])))
        let method = DicomDataSet(elements: [text(0x00080100, "113981", vr: .SH),
            text(0x00080102, "DCM", vr: .SH), text(0x00080104, "Synthetic method", vr: .LO)])
        let phantom = method.setting(text(0x00080100, "113690", vr: .SH))
        let codes = base.setting(.init(tag: 0x00181272, vr: .SQ, value: .sequence([.init(dataSet: method)])))
            .setting(.init(tag: 0x00189346, vr: .SQ, value: .sequence([.init(dataSet: phantom)])))
        // Standard-scheme codes resolve their version requirement; context group membership is not a schema rule.
        XCTAssertEqual(DicomCTImageModule.validate(codes)[.attributes], .passed)
        for (tag, item) in [(0x00181272, method), (0x00189346, phantom)] {
            let missingMeaning = codes.setting(.init(tag: tag, vr: .SQ,
                value: .sequence([.init(dataSet: item.removing(0x00080104))])))
            XCTAssertTrue(DicomCTImageModule.validate(missingMeaning).diagnostics.contains {
                $0.code == .requiredAttributeMissing && $0.path == [.tag(tag), .item(0), .tag(0x00080104)]
            })
            let tooMany = codes.setting(.init(tag: tag, vr: .SQ,
                value: .sequence([.init(dataSet: item), .init(dataSet: item)])))
            XCTAssertTrue(DicomCTImageModule.validate(tooMany).diagnostics.contains {
                $0.code == .sequenceItemCountInvalid && $0.path == [.tag(tag)]
            })
        }
    }

    func test_exhaustedBudget_doesNotAppendUnboundedModuleDiagnostics() {
        var dataSet = fixture().setting(text(0x00189361, "YES", vr: .CS))
            .setting(.init(tag: 0x00189360, vr: .SQ, value: .sequence([.init(dataSet: sourceFixture())])))
        for tag in [0x00181272, 0x00189346, 0x00189392, 0x00189362, 0x00082218, 0x00540220] {
            dataSet.set(.init(tag: tag, vr: .SQ, value: .sequence([.init(dataSet: .init())])))
        }
        let report = DicomCTImageModule.validate(dataSet, limits: .init(maximumRuleEvaluations: 0, maximumDiagnostics: 1))
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertEqual(report.diagnostics.count, 1)
        XCTAssertEqual(report.diagnostics.first?.code, .evaluationLimitReached)
    }

    func test_moduleLimitations_shareTheOrdinaryDiagnosticBudget() {
        var dataSet = fixture()
        for tag in [0x00189392, 0x00189362, 0x00082218, 0x00540220] {
            dataSet.set(.init(tag: tag, vr: .SQ, value: .sequence([.init(dataSet: .init())])))
        }
        // Empty algorithm/view items fail their Type 1 fields within the single-diagnostic budget.
        let report = DicomCTImageModule.validate(dataSet, limits: .init(maximumDiagnostics: 1))
        XCTAssertEqual(report[.attributes], .failed)
        XCTAssertEqual(report.diagnostics.count, 2)
        XCTAssertEqual(report.diagnostics.first?.code, .requiredAttributeMissing)
        XCTAssertEqual(report.diagnostics.last?.code, .evaluationLimitReached)
    }

    func test_ruleProjection_keepsOversizedWeightingEvidenceUnknown() {
        let weighted = DicomDataSet(elements: [text(0x00080100, "113097", vr: .SH), text(0x00080102, "DCM", vr: .SH)])
        let items = Array(repeating: DicomSequenceItem(dataSet: weighted), count: 100_001)
        let dataSet = fixture().setting(.init(tag: 0x00089215, vr: .SQ, value: .sequence(items)))
        let report = DicomAttributeValidator.validate(dataSet, rules: DicomCTImageModule.rules(for: dataSet))
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionUndetermined && $0.path == [.tag(0x00189353)] })
    }

    func test_weightingCondition_cannotUseItemsBeyondItsWorkBudget() {
        let unrelated = DicomDataSet(elements: [text(0x00080100, "999999", vr: .SH), text(0x00080102, "DCM", vr: .SH)])
        let weighted = unrelated.setting(text(0x00080100, "113097", vr: .SH))
        var items = Array(repeating: DicomSequenceItem(dataSet: unrelated), count: 100)
        items.append(.init(dataSet: weighted))
        let dataSet = fixture().setting(.init(tag: 0x00089215, vr: .SQ, value: .sequence(items)))
        let limited = DicomCTImageModule.validate(dataSet, limits: .init(maximumRuleEvaluations: 100))
        XCTAssertEqual(limited[.attributes], .incomplete)
        XCTAssertEqual(limited.diagnostics.first?.code, .evaluationLimitReached)
        XCTAssertEqual(limited.diagnostics.first?.path, [.tag(0x00089215)])
        let depth = DicomCTImageModule.validate(dataSet, limits: .init(maximumDepth: 0, maximumRuleEvaluations: 1000))
        XCTAssertEqual(depth[.attributes], .incomplete)
        XCTAssertEqual(depth.diagnostics.first?.path, [.tag(0x00089215)])
        XCTAssertTrue(DicomCTImageModule.validate(dataSet, limits: .init(maximumRuleEvaluations: 1000)).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00189353)]
        })
    }

    private func fixture() -> DicomDataSet {
        .init(elements: [
            .init(tag: 0x00080008, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY", "AXIAL"])),
            number(0x00280002, 1), text(0x00280004, "MONOCHROME2", vr: .CS), number(0x00280100, 16),
            number(0x00280101, 16), number(0x00280102, 15), text(0x00281052, "-1024", vr: .DS),
            text(0x00281053, "1", vr: .DS), text(0x00180060, "120", vr: .DS), text(0x00200012, "1", vr: .IS)
        ])
    }

    private func sourceFixture() -> DicomDataSet {
        .init(elements: [text(0x00180060, "80", vr: .DS), .init(tag: 0x00189330, vr: .FD, value: .floats([100])),
            .init(tag: 0x00180090, vr: .DS, value: .strings(["400"])), text(0x00181190, "1", vr: .DS),
            text(0x00181160, "WEDGE", vr: .SH), text(0x00187050, "ALUMINUM", vr: .CS)])
    }

    private func text(_ tag: Int, _ value: String, vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement {
        .init(tag: tag, vr: .US, value: .unsignedIntegers([value]))
    }
}
