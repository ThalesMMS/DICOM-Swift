import Foundation
import XCTest
@testable import DicomCore

final class DicomPersonIdentificationMacroTests: XCTestCase {
    func test_originalInstance_rejectsMissingPersonCodeInAllCommonLocations() throws {
        for tag in [0x00080096, 0x0008009D, 0x00081049, 0x00081062, 0x00081052, 0x00081072] {
            let dataSet = fixture().setting(sequence(tag, [.init(elements: [])]))
            let report = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: dataSet))
            XCTAssertTrue(report.diagnostics.contains {
                $0.code == .requiredAttributeMissing && $0.path == [.tag(tag), .item(0), .tag(0x00401101)]
            })
        }
    }

    func test_personMacro_requiresCodesAndInstitutionAlternatives() {
        let base = person()
        XCTAssertEqual(validatePerson(base)[.attributes], .incomplete)
        for tag in [0x00401101, 0x00080080] {
            XCTAssertEqual(validatePerson(base.removing(tag))[.attributes], .failed)
        }
        let institution = sequence(0x00080082, [code()])
        XCTAssertEqual(validatePerson(base.removing(0x00080080).setting(institution))[.attributes], .incomplete)
        XCTAssertEqual(validatePerson(base.setting(institution))[.attributes], .incomplete)
        XCTAssertEqual(validatePerson(base.setting(sequence(0x00080082, [code(), code()])))[.attributes], .failed)
        XCTAssertEqual(validatePerson(base.setting(sequence(0x00081041, [])))[.attributes], .failed)
        let missingMeaning = base.setting(sequence(0x00401101, [code().removing(0x00080104)]))
        XCTAssertTrue(validatePerson(missingMeaning).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00401101), .item(0), .tag(0x00080104)]
        })
    }

    func test_nameCorrespondence_preservesEmptyAndOpaqueEvidenceAndChargesBudget() {
        let items = sequence(0x00081072, [person(), person()])
        let rule = DicomAttributeRule(tag: 0x00081072, requirement: .type3,
            constraints: [.personIdentificationNames(0x00081070, whenMultipleItems: false)])
        for names in [text(0x00081070, "^^", .PN), .init(tag: 0x00081070, vr: .UN, value: .bytes(Data([0])))] {
            XCTAssertEqual(DicomAttributeValidator.validate(.init(elements: [items, names]), rules: [rule])[.attributes], .incomplete)
        }
        let dataSet = DicomDataSet(elements: [items, names(0x00081070, 3)])
        let limited = DicomAttributeValidator.validate(dataSet, rules: [rule],
            limits: .init(maximumRuleEvaluations: 4, maximumDiagnostics: 1))
        XCTAssertEqual(limited[.attributes], .incomplete)
        XCTAssertEqual(limited.diagnostics.last?.code, .evaluationLimitReached)
        XCTAssertEqual(DicomAttributeValidator.validate(dataSet, rules: [rule],
            limits: .init(maximumRuleEvaluations: 5))[.attributes], .failed)
        let depth = DicomAttributeValidator.validate(.init(elements: [items]), rules: [
            .init(tag: 0x00081072, requirement: .type3, itemRules: DicomPersonIdentificationMacro.rules())
        ], limits: .init(maximumDepth: 0))
        XCTAssertEqual(depth[.attributes], .incomplete)
    }

    func test_originalPart10Corpus_preservesNestedRulesAndContextSpecificCounts() throws {
        let base = fixture()
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("baseline", base, .incomplete),
            ("referring-valid", base.setting(sequence(0x00080096, [person()])), .incomplete),
            ("referring-missing-code", base.setting(sequence(0x00080096, [person().removing(0x00401101)])), .failed),
            ("referring-missing-institution", base.setting(sequence(0x00080096, [person().removing(0x00080080)])), .failed),
            ("referring-multiple", base.setting(sequence(0x00080096, [person(), person()])), .failed),
            ("institution-code-only", base.setting(sequence(0x00080096, [person().removing(0x00080080).setting(sequence(0x00080082, [code()]))])), .incomplete),
            ("missing-meaning", base.setting(sequence(0x00080096, [person().setting(sequence(0x00401101, [code().removing(0x00080104)]))])), .failed),
            ("consulting-empty", base.setting(sequence(0x0008009D, [])), .failed),
            ("consulting-two", base.setting(sequence(0x0008009D, [person(), person()])).setting(names(0x0008009C, 2)), .incomplete),
            ("consulting-count-mismatch", base.setting(sequence(0x0008009D, [person(), person()])).setting(names(0x0008009C, 1)), .failed),
            ("consulting-single-exception", base.setting(sequence(0x0008009D, [person()])).setting(names(0x0008009C, 2)), .incomplete),
            ("equipment-two", base.setting(equipment(items: 2, nameCount: 2)), .incomplete),
            ("equipment-single-mismatch", base.setting(equipment(items: 1, nameCount: 2)), .failed)
        ]
        for (name, dataSet, expected) in cases {
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertEqual(report[.attributes], expected, name)
            XCTAssertEqual(report[.pixelsAndGeometry], .passed, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), report)
            if let folder = ProcessInfo.processInfo.environment["DICOM_PERSON_IDENTIFICATION_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": report[.attributes].rawValue,
                    "geometry": report[.pixelsAndGeometry].rawValue], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func validatePerson(_ dataSet: DicomDataSet) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: DicomPersonIdentificationMacro.rules())
    }
    private func person() -> DicomDataSet {
        .init(elements: [sequence(0x00401101, [code()]), text(0x00080080, "SYNTHETIC")])
    }
    private func code() -> DicomDataSet {
        .init(elements: [text(0x00080120, "urn:example:synthetic", .UR), text(0x00080104, "Synthetic^Person")])
    }
    private func names(_ tag: Int, _ count: Int) -> DicomDataElement {
        .init(tag: tag, vr: .PN, value: .strings((0..<count).map { "Synthetic^Person" + String($0) }))
    }
    private func equipment(items: Int, nameCount: Int) -> DicomDataElement {
        sequence(0x0018A001, [.init(elements: [text(0x00080070, "SYNTHETIC"), sequence(0x0040A170, [code()]),
            sequence(0x00081072, Array(repeating: person(), count: items)), names(0x00081070, nameCount)])])
    }

    private func fixture() -> DicomDataSet {
        var dataSet = DicomDataSet(elements: [])
        for (tag, vr, value) in [(0x00080016, DicomVR.UI, "1.2.840.10008.5.1.4.1.1.7"), (0x00080018, .UI, "2.25.23213601"),
            (0x0020000D, .UI, "2.25.23213602"), (0x0020000E, .UI, "2.25.23213603"),
            (0x00100010, .PN, ""), (0x00100020, .LO, ""), (0x00100030, .DA, ""), (0x00100040, .CS, ""),
            (0x00080020, .DA, ""), (0x00080030, .TM, ""), (0x00080090, .PN, ""), (0x00200010, .SH, ""),
            (0x00080050, .SH, ""), (0x00200011, .IS, ""), (0x00200013, .IS, ""), (0x00200020, .CS, ""),
            (0x00080064, .CS, "WSD"), (0x00080060, .CS, "OT"), (0x00280004, .CS, "MONOCHROME2")] {
            dataSet.set(text(tag, value, vr))
        }
        for (tag, value) in [(0x00280010, UInt(2)), (0x00280011, 2), (0x00280002, 1),
            (0x00280100, 8), (0x00280101, 8), (0x00280102, 7), (0x00280103, 0)] {
            dataSet.set(.init(tag: tag, vr: .US, value: .unsignedIntegers([value])))
        }
        dataSet.set(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 1, count: 4))))
        return dataSet
    }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR = .LO) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
