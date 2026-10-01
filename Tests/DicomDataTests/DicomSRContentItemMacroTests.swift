import Foundation
import XCTest
@testable import DicomData

final class DicomSRContentItemMacroTests: XCTestCase {
    func test_scalarValue_requirementsAreConditionalAndExcludeOtherScalarValues() {
        let values: [(String, Int, DicomVR, String)] = [("TEXT", 0x0040A160, .UT, "SYNTHETIC"),
            ("DATETIME", 0x0040A120, .DT, "20260908140000"), ("DATE", 0x0040A121, .DA, "20260908"),
            ("TIME", 0x0040A122, .TM, "140000"), ("PNAME", 0x0040A123, .PN, "SYNTHETIC^OBSERVER"),
            ("UIDREF", 0x0040A124, .UI, "2.25.23219001")]
        for (kind, tag, vr, value) in values {
            let base = item(kind)
            let missing = validate(base)
            XCTAssertTrue(missing.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.requirement == .type1C && $0.path == [.tag(tag)] })
            XCTAssertEqual(validate(base.setting(text(tag, value, vr)))[.attributes], .passed)
            XCTAssertTrue(validate(base.setting(text(tag, "", vr))).diagnostics.contains { $0.code == .requiredValueEmpty })
            let wrong = base.setting(text(tag, value, vr)).setting(text(0x0040A040, "CODE", .CS))
            XCTAssertTrue(validate(wrong).diagnostics.contains { $0.code == .conditionalAttributeForbidden && $0.path == [.tag(tag)] })
        }
    }

    func test_headingAndReferencePurpose_areSelfEvidencingAndNeverForbidden() {
        for kind in ["CONTAINER", "IMAGE", "COMPOSITE", "WAVEFORM", "SCOORD", "SCOORD3D", "TCOORD"] {
            var base = item(kind).removing(0x0040A043)
            if kind == "CONTAINER" { base = base.setting(text(0x0040A050, "SEPARATE", .CS)) }
            var facts = conditions()
            facts.containerHasHeading = .undetermined
            facts.referencePurposeInConceptName = .undetermined
            XCTAssertEqual(validate(base, facts: facts)[.attributes], .passed)
            XCTAssertFalse(validate(base, facts: facts).diagnostics.contains { $0.path == [.tag(0x0040A043)] })
            XCTAssertEqual(validate(base.setting(sequence(0x0040A043, [code()])), facts: facts)[.attributes], .passed)
            facts.containerHasHeading = .satisfied
            facts.referencePurposeInConceptName = .satisfied
            XCTAssertTrue(validate(base, facts: facts).diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A043)] })
            facts.containerHasHeading = .unsatisfied
            facts.referencePurposeInConceptName = .unsatisfied
            XCTAssertEqual(validate(base, facts: facts)[.attributes], .passed)
            XCTAssertEqual(validate(base.setting(sequence(0x0040A043, [code()])), facts: facts)[.attributes], .passed)
        }
        let root = item("CONTAINER").removing(0x0040A010).removing(0x0040A043).setting(text(0x0040A050, "SEPARATE", .CS))
        XCTAssertTrue(DicomSRContentItemMacro.validate(root, isRoot: true, conditions: conditions()).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A043)] })
    }

    func test_observationDateTime_isRequiredWhenDifferentAndAllowedOtherwise() {
        let base = item("TEXT").setting(text(0x0040A160, "SYNTHETIC", .UT))
        var facts = conditions()
        facts.observationTimeDiffers = .satisfied
        XCTAssertTrue(validate(base, facts: facts).diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A032)] })
        let observed = base.setting(text(0x0040A032, "20260908120000", .DT))
        XCTAssertEqual(validate(observed, facts: facts)[.attributes], .passed)
        facts.observationTimeDiffers = .unsatisfied
        XCTAssertEqual(validate(observed, facts: facts)[.attributes], .passed)
        facts.observationTimeDiffers = .undetermined
        XCTAssertEqual(validate(base, facts: facts)[.attributes], .incomplete)
    }

    func test_templateIdentification_isConditionalAndDCMRIdentifiersAreUnprefixedDigits() {
        let base = item("CONTAINER").setting(text(0x0040A050, "SEPARATE", .CS))
        var facts = conditions()
        facts.containerHasHeading = .satisfied
        facts.identifyingTemplateRequired = .satisfied
        XCTAssertTrue(validate(base, facts: facts).diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A504)] })
        for identifier in ["1500", "9999999999999999", "1500  "] {
            XCTAssertEqual(validate(base.setting(template(identifier)), facts: facts)[.attributes], .passed)
        }
        for identifier in ["01500", "0", "TID 1500", "1500.1", "+1500"] {
            XCTAssertTrue(validate(base.setting(template(identifier)), facts: facts).diagnostics.contains {
                $0.code == .attributeValueNotAllowed && $0.path == [.tag(0x0040A504), .item(0), .tag(0x0040DB00)] })
        }
        XCTAssertEqual(validate(base.setting(template("PRIVATE_A", resource: "PRIVATE")), facts: facts)[.attributes], .passed)
        facts.identifyingTemplateRequired = .unsatisfied
        XCTAssertTrue(validate(base.setting(template("1500")), facts: facts).diagnostics.contains { $0.code == .conditionalAttributeForbidden })
        facts.identifyingTemplateRequired = .undetermined
        XCTAssertEqual(validate(base, facts: facts)[.attributes], .passed)
        XCTAssertEqual(validate(base.setting(template("1500")), facts: facts)[.attributes], .passed)
    }

    func test_unformattedText_acceptsCRLFAndRejectsFormattingControls() {
        for value in ["SYNTHETIC", "Line one\r\nLine two", "Two\r\n\r\nlines", "Unicode não formatado"] {
            XCTAssertEqual(validate(item("TEXT").setting(text(0x0040A160, value, .UT)))[.attributes], .passed)
        }
        for value in ["A\tB", "A\u{000B}B", "A\u{000C}B", "A\nB", "A\rB", "A\r", "\nB", "A\u{0000}B", "A\u{001B}B", "A\u{0085}B"] {
            XCTAssertTrue(validate(item("TEXT").setting(text(0x0040A160, value, .UT))).diagnostics.contains {
                $0.code == .attributeValueNotAllowed && $0.path == [.tag(0x0040A160)] })
        }
    }

    func test_unknownOrMultivaluedValueType_doesNotInventConditionalAbsence() {
        for element in [text(0x0040A040, "FUTURE", .CS), .init(tag: 0x0040A040, vr: .CS, value: .strings(["TEXT", "NUM"])),
                        .init(tag: 0x0040A040, vr: .UN, value: .bytes(Data([1, 2])))] {
            let report = validate(item("TEXT").setting(element).setting(text(0x0040A160, "SYNTHETIC", .UT)))
            XCTAssertNotEqual(report[.attributes], .passed)
            XCTAssertFalse(report.diagnostics.contains { $0.code == .conditionalAttributeForbidden && $0.path == [.tag(0x0040A160)] })
        }
    }

    private func conditions() -> DicomSRContentItemMacro.Conditions {
        var result = DicomSRContentItemMacro.Conditions()
        result.containerHasHeading = .unsatisfied
        result.referencePurposeInConceptName = .unsatisfied
        result.observationTimeDiffers = .unsatisfied
        result.identifyingTemplateRequired = .unsatisfied
        return result
    }
    private func validate(_ dataSet: DicomDataSet, facts: DicomSRContentItemMacro.Conditions? = nil) -> DicomValidationReport {
        DicomSRContentItemMacro.validate(dataSet, conditions: facts ?? conditions(), versionRequirements: ["DCM": .unsatisfied])
    }
    private func item(_ type: String) -> DicomDataSet {
        .init(elements: [text(0x0040A040, type, .CS), text(0x0040A010, "CONTAINS", .CS), sequence(0x0040A043, [code()])])
    }
    private func code() -> DicomDataSet {
        .init(elements: [text(0x00080100, "126000", .SH), text(0x00080102, "DCM", .SH), text(0x00080104, "SYNTHETIC", .LO)])
    }
    private func template(_ identifier: String, resource: String = "DCMR") -> DicomDataElement {
        sequence(0x0040A504, [.init(elements: [text(0x00080105, resource, .CS), text(0x0040DB00, identifier, .CS)])])
    }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings([value])) }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
