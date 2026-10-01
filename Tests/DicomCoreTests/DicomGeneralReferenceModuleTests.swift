import Foundation
import XCTest
@testable import DicomCore

final class DicomGeneralReferenceModuleTests: XCTestCase {
    func test_originalReference_requiresPurposeAndSOPIdentity() throws {
        for (tag, item, missing) in [
            (0x0008114A, DicomDataSet(elements: [text(0x00081150, ["1.2.840.10008.5.1.4.1.1.88.33"], .UI),
                text(0x00081155, ["2.25.9001"], .UI)]), 0x0040A170),
            (0x00082112, DicomDataSet(), 0x00081155)
        ] {
            let source = fixture().setting(.init(tag: tag, vr: .SQ, value: .sequence([.init(dataSet: item)])))
            let report = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: source))
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path.last == .tag(missing) })
        }
    }

    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
    private func reference(_ sop: String = "1.2.840.10008.5.1.4.1.1.7") -> DicomDataSet {
        .init(elements: [text(0x00081150, [sop], .UI), text(0x00081155, ["2.25.9001"], .UI)])
    }
    private func purpose() -> DicomDataElement {
        sequence(0x0040A170, [.init(elements: [text(0x00080100, ["121322"], .SH),
            text(0x00080102, ["DCM"], .SH), text(0x00080104, ["Source image"], .LO)])])
    }

    func test_rolesAndTargets_useIdentityBeforeFrameBounds() {
        let sop = "1.2.840.10008.5.1.4.1.1.4.1"
        let item = reference(sop).setting(text(0x00081160, ["4"], .IS))
        let source = fixture().setting(sequence(0x00081140, [item]))
        let target = fixture().setting(text(0x00080016, [sop], .UI)).setting(text(0x00080018, ["2.25.9001"], .UI))
            .setting(text(0x00280008, ["3"], .IS))
        let report = DicomGeneralReferenceModule.validate(source, targets: ["2.25.9001": target])
        XCTAssertTrue(report.diagnostics.contains { $0.code == .referenceSelectionOutOfRange && $0.path.last == .frame(3) })
        let wrong = DicomGeneralReferenceModule.validate(source, targets: ["2.25.9001": target.setting(text(0x00080018, ["2.25.999"], .UI))])
        XCTAssertTrue(wrong.diagnostics.contains { $0.code == .referenceIdentityContradiction })
        XCTAssertFalse(wrong.diagnostics.contains { $0.code == .referenceSelectionOutOfRange })
        for (tag, sop) in [(0x00081140, "1.2.840.10008.5.1.4.1.1.88.33"), (0x0008114A, "1.2.840.10008.5.1.4.1.1.7")] {
            let source = fixture().setting(sequence(tag, [reference(sop).setting(purpose())]))
            XCTAssertTrue(DicomGeneralReferenceModule.validate(source).diagnostics.contains { $0.code == .referenceSOPClassNotAllowed })
        }
        for limit in [DicomAttributeValidator.Limits(maximumRuleEvaluations: 1), .init(maximumDepth: 0), .init(maximumDiagnostics: 1)] {
            XCTAssertTrue(DicomGeneralReferenceModule.validate(source, limits: limit).diagnostics.contains { $0.code == .evaluationLimitReached })
        }
    }

    func test_originalCorpus_composesPurposeSpatialConditionsAndSourceIdentity() throws {
        let image = reference()
        let composite = reference("1.2.840.10008.5.1.4.1.1.88.33")
        let cases: [(String, Int, DicomDataSet, Bool)] = [
            ("image", 0x00081140, image, false), ("source-image", 0x00082112, image, false),
            ("instance", 0x0008114A, composite.setting(purpose()), false), ("source-instance", 0x00420013, composite, false),
            ("missing-purpose", 0x0008114A, composite, true), ("missing-class", 0x00081140, image.removing(0x00081150), true),
            ("missing-instance", 0x00420013, composite.removing(0x00081155), true),
            ("wrong-image-role", 0x00081140, composite, true), ("wrong-instance-role", 0x0008114A, image.setting(purpose()), true),
            ("reoriented-missing-orientation", 0x00082112, image.setting(text(0x0028135A, ["REORIENTED_ONLY"], .CS)), true),
            ("reoriented", 0x00082112, image.setting(text(0x0028135A, ["REORIENTED_ONLY"], .CS))
                .setting(text(0x00200020, ["L", "P"], .CS)), false),
            ("invalid-preservation", 0x00082112, image.setting(text(0x0028135A, ["PRIVATE"], .CS)), true)
        ]
        for (name, tag, item, failed) in cases {
            let source = fixture().setting(sequence(tag, [item]))
            let bytes = try DicomDataSetWriter.part10Data(from: source)
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertEqual(report[.attributes] == .failed || report[.references] == .failed, failed, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), report)
            if let folder = ProcessInfo.processInfo.environment["DICOM_GENERAL_REFERENCE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": report[.attributes].rawValue,
                    "references": report[.references].rawValue, "exit": failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func fixture() -> DicomDataSet {
        var dataSet = DicomDataSet(elements: [text(0x00080016, ["1.2.840.10008.5.1.4.1.1.7"], .UI), text(0x00080018, ["2.25.23213701"], .UI),
            text(0x00280004, ["MONOCHROME2"], .CS), number(0x00280002, [1]), number(0x00280010, [2]), number(0x00280011, [2]),
            number(0x00280100, [8]), number(0x00280101, [8]), number(0x00280102, [7]), number(0x00280103, [0]),
            .init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 1, count: 4)))])
        for (tag, vr, value) in [(0x0020000D, DicomVR.UI, "2.25.23213702"), (0x0020000E, .UI, "2.25.23213703"),
            (0x00100010, .PN, ""), (0x00100020, .LO, ""), (0x00100030, .DA, ""), (0x00100040, .CS, ""),
            (0x00080020, .DA, ""), (0x00080030, .TM, ""), (0x00080090, .PN, ""), (0x00200010, .SH, ""),
            (0x00080050, .SH, ""), (0x00200011, .IS, ""), (0x00200013, .IS, ""), (0x00200020, .CS, ""),
            (0x00080064, .CS, "WSD"), (0x00080060, .CS, "OT")] { dataSet.set(text(tag, [value], vr)) }
        return dataSet
    }
    private func text(_ tag: Int, _ values: [String], _ vr: DicomVR) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings(values)) }
    private func number(_ tag: Int, _ values: [UInt]) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers(values)) }
}
