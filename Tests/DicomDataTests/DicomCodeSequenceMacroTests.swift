import Foundation
import XCTest
@testable import DicomData

final class DicomCodeSequenceMacroTests: XCTestCase {
    private let policy: [String: DicomAttributeRule.Truth] = ["99FIXED": .unsatisfied, "99VERSIONED": .satisfied]

    func test_codeAlternatives_acceptShortLongAndURNAndRejectMultipleOrMissingValues() {
        let alternatives: [(Int, DicomVR, String)] = [
            (0x00080100, .SH, "EXAMPLE"),
            (0x00080119, .UC, "EXAMPLE_LONG_CODE_123"),
            (0x00080120, .UR, "urn:example:synthetic:2321")
        ]
        for (tag, vr, value) in alternatives {
            let code = fixture().setting(text(tag, value, vr))
            XCTAssertEqual(validate(code)[.attributes], .passed)
            let empty = code.setting(.init(tag: tag, vr: vr, value: .empty))
            XCTAssertEqual(validate(empty)[.attributes], .failed)
        }
        XCTAssertTrue(validate(fixture()).diagnostics.contains { $0.code == .exclusiveAttributeChoiceInvalid && $0.path.isEmpty })
        let multiple = fixture().setting(text(0x00080100, "SHORT", .SH)).setting(text(0x00080119, "EXAMPLE_LONG_CODE_123", .UC))
        XCTAssertEqual(validate(multiple)[.attributes], .failed)
    }

    func test_representationSelection_rejectsWrongLengthOrNotationAndKeepsShortURIUnresolved() {
        for element in [text(0x00080100, "TOO_LONG_FOR_SHORT_CODE", .SH), text(0x00080119, "SHORT", .UC),
                        text(0x00080119, "urn:example:synthetic:2321", .UC), text(0x00080120, "NO_URI_NOTATION_HERE", .UR)] {
            XCTAssertEqual(validate(fixture().setting(element))[.attributes], .failed)
        }
        for element in [text(0x00080100, "urn:x:1", .SH), text(0x00080120, "urn:x:1", .UR)] {
            let report = validate(fixture().setting(element))
            XCTAssertEqual(report[.attributes], .incomplete)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionUndetermined && $0.path == [.tag(element.tag)] })
        }
    }

    func test_schemeAndVersion_requireEvidenceAndNeverGuessPrivateSchemeVersioning() {
        let short = fixture().setting(text(0x00080100, "CODE", .SH))
        XCTAssertEqual(DicomCodeSequenceMacro.validate(short)[.attributes], .incomplete)
        XCTAssertEqual(validate(short)[.attributes], .passed)
        XCTAssertEqual(validate(short.removing(0x00080102))[.attributes], .failed)
        let versioned = short.setting(text(0x00080102, "99VERSIONED", .SH))
        XCTAssertTrue(validate(versioned).diagnostics.contains { $0.path == [.tag(0x00080103)] && $0.code == .requiredAttributeMissing })
        XCTAssertEqual(validate(versioned.setting(text(0x00080103, "1", .SH)))[.attributes], .passed)
        XCTAssertEqual(validate(short.setting(text(0x00080103, "1", .SH)))[.attributes], .passed)
    }

    func test_urn_canOmitSchemeButCannotHaveOrphanVersionEvenWhenVersionIsEmpty() {
        let urn = fixture().removing(0x00080102).setting(text(0x00080120, "urn:example:synthetic:2321", .UR))
        XCTAssertEqual(DicomCodeSequenceMacro.validate(urn)[.attributes], .passed)
        for value in ["", "1"] {
            let report = validate(urn.setting(text(0x00080103, value, .SH)))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionalAttributeForbidden && $0.path == [.tag(0x00080103)] })
        }
    }

    func test_contextAndExtension_conditionsRequireMappingVersionAndCreator() {
        let basic = fixture().setting(text(0x00080100, "CODE", .SH))
        let context = basic.setting(text(0x0008010F, "100", .CS))
        let missing = validate(context)
        for tag in [0x00080105, 0x00080106] {
            XCTAssertTrue(missing.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(tag)] })
        }
        let mapped = context.setting(text(0x00080105, "DCMR", .CS)).setting(text(0x00080106, "20260908", .DT))
        XCTAssertEqual(validate(mapped)[.attributes], .passed)
        let extended = mapped.setting(text(0x0008010B, "Y", .CS))
        for tag in [0x00080107, 0x0008010D] {
            XCTAssertTrue(validate(extended).diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(tag)] })
        }
        let complete = extended.setting(text(0x00080107, "20260908", .DT)).setting(text(0x0008010D, "2.25.2321", .UI))
        XCTAssertEqual(validate(complete)[.attributes], .passed)
        XCTAssertEqual(validate(complete.setting(text(0x0008010B, "N", .CS)))[.attributes], .failed)
    }

    func test_equivalentCodeItems_useTheirOwnConditionsAndPreserveItemPaths() {
        let root = fixture().setting(text(0x00080100, "CODE", .SH))
        let first = root
        let second = root.setting(text(0x00080102, "99VERSIONED", .SH))
        let dataSet = root.setting(.init(tag: 0x00080121, vr: .SQ,
            value: .sequence([.init(dataSet: first), .init(dataSet: second)])))
        let report = validate(dataSet)
        XCTAssertEqual(report.diagnostics.count, 1)
        XCTAssertEqual(report.diagnostics[0].path, [.tag(0x00080121), .item(1), .tag(0x00080103)])
        let noCodes = root.setting(.init(tag: 0x00080121, vr: .SQ, value: .sequence([.init(dataSet: fixture())])))
        XCTAssertTrue(validate(noCodes).diagnostics.contains { $0.code == .exclusiveAttributeChoiceInvalid
            && $0.path == [.tag(0x00080121), .item(0)] && $0.requirement == nil })
    }

    func test_optionalSequences_requireItemsEvenWithoutExplicitCardinalityConstraint() {
        for value in [DicomDataValue.empty, .sequence([])] {
            let dataSet = DicomDataSet(elements: [.init(tag: 0x00080121, vr: .SQ, value: value)])
            let report = DicomAttributeValidator.validate(dataSet, rules: [.init(tag: 0x00080121, requirement: .type3)])
            XCTAssertEqual(report[.attributes], .failed)
            XCTAssertEqual(report.diagnostics.first?.requirement, .type3)
        }
    }

    private func fixture() -> DicomDataSet {
        .init(elements: [text(0x00080102, "99FIXED", .SH), text(0x00080104, "Synthetic code", .LO)])
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    private func validate(_ dataSet: DicomDataSet) -> DicomValidationReport {
        DicomCodeSequenceMacro.validate(dataSet, versionRequirements: policy)
    }
}
