import Foundation
import XCTest
@testable import DicomCore

final class DicomSOPCommonModuleTests: XCTestCase {
    func test_instanceValidation_checksCommonFlagsAcrossImageAndSRClasses() throws {
        for suffix in ["2", "4", "7", "88.22", "88.59"] {
            let dataSet = fixture().setting(text(0x00080016, ["1.2.840.10008.5.1.4.1.1." + suffix], .UI))
                .setting(text(0x01000410, ["LOCAL"]))
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .attributeValueNotAllowed && $0.path == [.tag(0x01000410)] })
        }
    }

    func test_originalTimezoneMultiplicity_isNotHiddenByWhitespacePreservation() throws {
        for values in [["", ""], ["+0000", "+0100"]] {
            let bytes = try DicomDataSetWriter.part10Data(from: fixture().setting(text(0x00080201, values, .SH)))
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertEqual(report.outcome(requiring: [.vrAndVM, .attributes]), .failed)
            XCTAssertTrue(report.diagnostics.contains { $0.severity == .error && $0.path == [.tag(0x00080201)] })
        }
    }

    func test_commonEnumerations_preserveOptionalEmptyValues() {
        XCTAssertEqual(validate(fixture())[.attributes], .passed)
        for tag in [0x00080016, 0x00080018] { XCTAssertEqual(validate(fixture().removing(tag))[.attributes], .failed) }
        for (tag, allowed) in [(0x0008001C, ["YES", "NO"]), (0x01000410, ["NS", "OR", "AO", "AC"]),
                               (0x00280303, ["UNMODIFIED", "MODIFIED", "REMOVED"]),
                               (0x00189004, ["PRODUCT", "RESEARCH", "SERVICE"]), (0x04000600, ["LOCAL", "IMPORTED"])] {
            for value in allowed + [""] {
                XCTAssertEqual(validate(fixture().setting(text(tag, [value])))[.attributes], .passed)
            }
            XCTAssertEqual(validate(fixture().setting(text(tag, ["UNKNOWN"])))[.attributes], .failed)
        }
        XCTAssertEqual(validate(fixture().setting(text(0x00080053, ["CLASSIC"])))[.attributes], .incomplete)
        XCTAssertEqual(validate(fixture().setting(text(0x00080053, ["LOCAL"])))[.attributes], .failed)
    }

    func test_timezone_usesDTSuffixGrammarWithoutAllowingLeadingPadding() {
        for value in ["+0000", "-0300", "+1400", "-1200", "+0545", "+0000 ", ""] {
            XCTAssertEqual(validate(fixture().setting(text(0x00080201, [value], .SH)))[.attributes], .passed)
        }
        for value in ["-0000", "0000", "+14:00", "+1401", "-1201", "+0160", " +0000", "+0A00", "+00000"] {
            XCTAssertEqual(validate(fixture().setting(text(0x00080201, [value], .SH)))[.attributes], .failed)
        }
        for values in [["", ""], ["+0000", "+0100"]] {
            XCTAssertEqual(validate(fixture().setting(text(0x00080201, values, .SH)))[.attributes], .failed)
        }
        XCTAssertEqual(validate(fixture().setting(.init(tag: 0x00080201, vr: .UN, value: .bytes(Data([0])))))[.attributes], .incomplete)
    }

    func test_identificationSequences_requireFieldsAndPreserveRegistryUncertainty() {
        let context = DicomDataSet(elements: [text(0x0008010F, ["49"]), text(0x00080105, ["DCMR"]), text(0x00080106, ["20260101"], .DT)])
        XCTAssertEqual(validate(fixture().setting(sequence(0x00080123, [context])))[.attributes], .incomplete)
        for tag in [0x0008010F, 0x00080105, 0x00080106] {
            XCTAssertEqual(validate(fixture().setting(sequence(0x00080123, [context.removing(tag)])))[.attributes], .failed)
        }
        XCTAssertEqual(validate(fixture().setting(sequence(0x00080124, [.init(elements: [])])))[.attributes], .failed)
        let resource = DicomDataSet(elements: [text(0x0008010A, ["PRIVATE"]), text(0x0008010E, ["https://example.invalid/schema"], .UR)])
        let scheme = DicomDataSet(elements: [text(0x00080102, ["99TEST"], .SH), sequence(0x00080109, [resource])])
        XCTAssertEqual(validate(fixture().setting(sequence(0x00080110, [scheme])))[.attributes], .incomplete)
        let incomplete = scheme.setting(sequence(0x00080109, [resource.removing(0x0008010E)]))
        XCTAssertTrue(validate(fixture().setting(sequence(0x00080110, [incomplete]))).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00080110), .item(0), .tag(0x00080109), .item(0), .tag(0x0008010E)]
        })
        let conflicting = scheme.setting(text(0x0008010C, ["2.25.23213402"], .UI)).setting(text(0x00080114, ["LOCAL"], .ST))
        XCTAssertEqual(validate(fixture().setting(sequence(0x00080110, [conflicting])))[.attributes], .failed)
    }

    func test_equipmentCodes_requireManufacturerAndNestedPurposeValues() {
        let equipment = DicomDataSet(elements: [text(0x00080070, ["SYNTHETIC"], .LO), sequence(0x0040A170, [code()])])
        XCTAssertEqual(validate(fixture().setting(sequence(0x0018A001, [equipment])))[.attributes], .incomplete)
        for tag in [0x00080070, 0x0040A170] {
            XCTAssertEqual(validate(fixture().setting(sequence(0x0018A001, [equipment.removing(tag)])))[.attributes], .failed)
        }
        let invalid = equipment.setting(sequence(0x0040A170, [code().removing(0x00080104)]))
        XCTAssertTrue(validate(fixture().setting(sequence(0x0018A001, [invalid]))).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0018A001), .item(0), .tag(0x0040A170), .item(0), .tag(0x00080104)]
        })
        for tag in [0x0018A001, 0x0008001D, 0x00080110, 0x00080123, 0x00080124] {
            XCTAssertEqual(validate(fixture().setting(sequence(tag, [])))[.attributes], .failed)
        }
    }

    func test_unqualifiedMacrosAndBudgets_neverImplyCompleteApproval() {
        // A declared Encrypted Attributes item must carry its transfer syntax and content.
        let encrypted = fixture().setting(sequence(0x04000500, [.init(elements: [])]))
        XCTAssertTrue(validate(encrypted).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x04000500), .item(0), .tag(0x04000510)]
        })
        XCTAssertTrue(validate(fixture().setting(sequence(0xFFFAFFFA, [.init(elements: [])]))).diagnostics.contains {
            $0.code == .semanticScopeUnavailable && $0.path == [.tag(0xFFFAFFFA)]
        })
        let dataSet = fixture().setting(sequence(0x0018A001, [.init(elements: [])]))
        for budget in [0, 1, 5] {
            let report = DicomSOPCommonModule.validate(dataSet, limits: .init(maximumRuleEvaluations: budget, maximumDiagnostics: 1))
            XCTAssertEqual(report[.attributes], .incomplete)
            XCTAssertLessThanOrEqual(report.diagnostics.count, 2)
        }
        XCTAssertEqual(DicomSOPCommonModule.validate(dataSet, limits: .init(maximumDepth: 0))[.attributes], .incomplete)
    }

    func test_originalPart10Corpus_preservesCommonAttributeEvidence() throws {
        var baseline = fixture()
        for (tag, vr, value) in [(0x0020000D, DicomVR.UI, "2.25.23213403"), (0x0020000E, .UI, "2.25.23213404"),
            (0x00100010, .PN, ""), (0x00100020, .LO, ""), (0x00100030, .DA, ""), (0x00100040, .CS, ""),
            (0x00080020, .DA, ""), (0x00080030, .TM, ""), (0x00080090, .PN, ""), (0x00200010, .SH, ""),
            (0x00080050, .SH, ""), (0x00200011, .IS, ""), (0x00200013, .IS, ""), (0x00200020, .CS, ""),
            (0x00080064, .CS, "WSD"), (0x00080060, .CS, "OT"), (0x00280004, .CS, "MONOCHROME2")] {
            baseline.set(text(tag, [value], vr))
        }
        for (tag, value) in [(0x00280010, UInt(2)), (0x00280011, 2), (0x00280002, 1),
            (0x00280100, 8), (0x00280101, 8), (0x00280102, 7), (0x00280103, 0)] {
            baseline.set(.init(tag: tag, vr: .US, value: .unsignedIntegers([value])))
        }
        baseline.set(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 1, count: 4))))
        let equipment = DicomDataSet(elements: [text(0x00080070, ["SYNTHETIC"], .LO), sequence(0x0040A170, [code()])])
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("baseline", baseline, .passed),
            ("status-valid", baseline.setting(text(0x01000410, ["OR"])), .passed),
            ("status-invalid", baseline.setting(text(0x01000410, ["LOCAL"])), .failed),
            ("synthetic-invalid", baseline.setting(text(0x0008001C, ["MAYBE"])), .failed),
            ("origin-invalid", baseline.setting(text(0x04000600, ["REMOTE"])), .failed),
            ("qualification-invalid", baseline.setting(text(0x00189004, ["CLINICAL"])), .failed),
            ("temporal-invalid", baseline.setting(text(0x00280303, ["YES"])), .failed),
            ("timezone-valid", baseline.setting(text(0x00080201, ["+0545"], .SH)), .passed),
            ("timezone-negative-zero", baseline.setting(text(0x00080201, ["-0000"], .SH)), .failed),
            ("timezone-leading-space", baseline.setting(text(0x00080201, [" +0000"], .SH)), .failed),
            ("timezone-range", baseline.setting(text(0x00080201, ["+1401"], .SH)), .failed),
            ("equipment-valid", baseline.setting(sequence(0x0018A001, [equipment])), .incomplete),
            ("equipment-manufacturer-missing", baseline.setting(sequence(0x0018A001, [equipment.removing(0x00080070)])), .failed),
            ("equipment-purpose-missing", baseline.setting(sequence(0x0018A001, [equipment.removing(0x0040A170)])), .failed),
            ("mapping-resource-missing", baseline.setting(sequence(0x00080124, [.init(elements: [])])), .failed),
            ("scheme-designator-missing", baseline.setting(sequence(0x00080110, [.init(elements: [])])), .failed)
        ]
        for (name, dataSet, expected) in cases {
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let meta = try DicomPart10FileMetaParser.parse(bytes)
            let parsed = try DicomEncodedDataSetValidator.validate(Data(bytes.dropFirst(meta.dataSetOffset)))
            let own = validate(try XCTUnwrap(parsed.dataSet))
            XCTAssertEqual(own[.attributes], expected, name)
            let instance = try DicomInstanceValidator.validate(bytes)
            XCTAssertEqual(instance[.attributes], expected == .failed ? .failed : .incomplete, name)
            XCTAssertEqual(instance[.pixelsAndGeometry], .passed, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), instance)
            if let folder = ProcessInfo.processInfo.environment["DICOM_SOP_COMMON_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": own[.attributes].rawValue,
                    "instanceAttributes": instance[.attributes].rawValue,
                    "instanceGeometry": instance[.pixelsAndGeometry].rawValue], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func validate(_ dataSet: DicomDataSet) -> DicomValidationReport { DicomSOPCommonModule.validate(dataSet) }
    private func fixture() -> DicomDataSet {
        .init(elements: [text(0x00080016, ["1.2.840.10008.5.1.4.1.1.7"], .UI), text(0x00080018, ["2.25.23213401"], .UI)])
    }
    private func code() -> DicomDataSet {
        .init(elements: [text(0x00080120, ["urn:example:synthetic"], .UR), text(0x00080104, ["Synthetic"], .LO)])
    }
    private func text(_ tag: Int, _ values: [String], _ vr: DicomVR = .CS) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings(values)) }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
