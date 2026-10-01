import Foundation
import XCTest
@testable import DicomCore

final class DicomCompositeImageModulesTests: XCTestCase {
    private let human = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, pairedBodyPart: .unsatisfied)
    private let animal = DicomCompositeImageModules.Conditions(nonHumanPatient: .satisfied,
                                                               nonBipedalAnatomy: .satisfied, pairedBodyPart: .unsatisfied)

    func test_commonRequiredAttributes_areComposedIntoOriginalByteValidation() throws {
        let data = try part10(fixture().removing(0x00100020))
        let report = try DicomInstanceValidator.validate(data)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00100020)] && $0.requirement == .type2
        })
        XCTAssertEqual(report[.attributes], .failed)
        XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(data), report)
    }

    func test_anonymousSC_permitsEmptyType2AndAbsentModality() {
        XCTAssertEqual(validate(fixture())[.attributes], .passed)
        XCTAssertEqual(validate(fixture().setting(text(0x00080064, "PRIVATE", .CS)))[.attributes], .passed)
        XCTAssertEqual(validate(fixture().setting(text(0x00080060, "CT", .CS)))[.attributes], .passed)
        for tag in [0x00100010, 0x00100020, 0x00100030, 0x00100040, 0x00080020, 0x00080030,
                    0x00080090, 0x00200010, 0x00080050, 0x00200011, 0x0020000D, 0x0020000E, 0x00080064] {
            XCTAssertEqual(validate(fixture().removing(tag))[.attributes], .failed, String(tag))
        }
        XCTAssertEqual(validate(fixture().setting(text(0x0020000D, "", .UI)))[.attributes], .failed)
        XCTAssertEqual(validate(fixture().setting(text(0x00100040, "UNKNOWN", .CS)))[.attributes], .failed)
    }

    func test_CTAndMR_requireTheirEquipmentPositionAndFrameOfReference() {
        for kind in [DicomCompositeImageModules.Kind.ct, .mr] {
            var dataSet = fixture()
            for element in [text(0x00080060, kind == .ct ? "CT" : "MR", .CS), text(0x00080070, "", .LO),
                            text(0x00185100, "", .CS), text(0x00200052, "2.25.23213004", .UI), text(0x00201040, "", .LO)] {
                dataSet.set(element)
            }
            XCTAssertEqual(DicomCompositeImageModules.validate(dataSet, kind: kind, conditions: human)[.attributes], .passed)
            for tag in [0x00080060, 0x00080070, 0x00185100, 0x00200052, 0x00201040] {
                XCTAssertEqual(DicomCompositeImageModules.validate(dataSet.removing(tag), kind: kind,
                                                                    conditions: human)[.attributes], .failed)
            }
        }
    }

    func test_SCSpatialAttributes_requireFrameOfReferenceWithoutInferringImagePlane() {
        for tag in [0x00200032, 0x00200037, 0x00200052, 0x00201040] {
            let declared = fixture().setting(text(tag, "", tag == 0x00200052 ? .UI : tag == 0x00201040 ? .LO : .DS))
            XCTAssertEqual(validate(declared)[.attributes], .failed)
            let complete = declared.setting(text(0x00200052, "2.25.23213004", .UI)).setting(text(0x00201040, "", .LO))
            XCTAssertEqual(validate(complete)[.attributes], .passed)
        }
    }

    func test_externalConditions_remainUnknownOrRequireAnimalMetadata() {
        XCTAssertEqual(DicomCompositeImageModules.validate(fixture(), kind: .secondaryCapture)[.attributes], .incomplete)
        XCTAssertEqual(DicomCompositeImageModules.validate(fixture(), kind: .secondaryCapture, conditions: animal)[.attributes], .failed)
        let complete = animalFixture()
        XCTAssertEqual(DicomCompositeImageModules.validate(complete, kind: .secondaryCapture, conditions: animal)[.attributes], .passed)
        for tag in [0x00102201, 0x00102292, 0x00102293, 0x00102294, 0x00102297, 0x00102299, 0x00102210] {
            XCTAssertEqual(DicomCompositeImageModules.validate(complete.removing(tag), kind: .secondaryCapture,
                                                                conditions: animal)[.attributes], .failed)
        }
        let opaqueBreed = complete.setting(.init(tag: 0x00102293, vr: .UN, value: .bytes(Data([1, 2])))).removing(0x00102292)
        XCTAssertEqual(DicomCompositeImageModules.validate(opaqueBreed, kind: .secondaryCapture, conditions: animal)[.attributes], .incomplete)
    }

    func test_deidentificationCalendarAndResponsiblePerson_conditionsUseActualValues() {
        let dataSet = fixture().setting(text(0x00120062, "YES", .CS))
        XCTAssertEqual(validate(dataSet)[.attributes], .failed)
        XCTAssertEqual(validate(dataSet.setting(text(0x00120063, "SYNTHETIC", .LO)))[.attributes], .passed)
        XCTAssertEqual(validate(fixture().setting(text(0x00120063, "OPTIONAL", .LO)))[.attributes], .passed)
        let calendar = fixture().setting(text(0x00100033, "LOCAL DATE", .LO))
        XCTAssertEqual(validate(calendar)[.attributes], .failed)
        XCTAssertEqual(validate(calendar.setting(text(0x00100035, "LOCAL", .CS)))[.attributes], .passed)
        for value in ["", "^^^==", "^ ^"] {
            XCTAssertEqual(validate(fixture().setting(text(0x00102297, value, .PN)))[.attributes], .passed)
        }
        let named = fixture().setting(text(0x00102297, "SYNTHETIC^PERSON", .PN))
        XCTAssertEqual(validate(named)[.attributes], .failed)
        XCTAssertEqual(validate(named.setting(text(0x00102298, "LOCAL", .CS)))[.attributes], .passed)
    }

    func test_pairedBodyPart_andPatientOrientationAlternatives_areConditional() {
        let paired = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, pairedBodyPart: .satisfied)
        XCTAssertEqual(DicomCompositeImageModules.validate(fixture(), kind: .secondaryCapture, conditions: paired)[.attributes], .failed)
        XCTAssertEqual(DicomCompositeImageModules.validate(fixture().setting(text(0x00200060, "L", .CS)),
                                                            kind: .secondaryCapture, conditions: paired)[.attributes], .passed)
        let imageLaterality = fixture().setting(text(0x00200062, "L", .CS))
        XCTAssertEqual(DicomCompositeImageModules.validate(imageLaterality, kind: .secondaryCapture, conditions: paired)[.attributes], .passed)
        XCTAssertEqual(DicomCompositeImageModules.validate(imageLaterality.setting(text(0x00200060, "L", .CS)),
                                                            kind: .secondaryCapture, conditions: paired)[.attributes], .passed)
        XCTAssertEqual(DicomCompositeImageModules.validate(imageLaterality.setting(text(0x00200060, "R", .CS)),
                                                            kind: .secondaryCapture, conditions: paired)[.attributes], .failed)
        let oriented = fixture().setting(.init(tag: 0x00540410, vr: .SQ, value: .sequence([])))
        XCTAssertEqual(validate(oriented.setting(text(0x00185100, "HFS", .CS)))[.attributes], .failed)
    }

    func test_limits_preserveIncompleteOutcomeAndDoNotDiscloseValues() throws {
        for limits in [DicomAttributeValidator.Limits(maximumRuleEvaluations: 0), .init(maximumDiagnostics: 1)] {
            let report = DicomCompositeImageModules.validate(.init(elements: []), kind: .ct, limits: limits)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
            XCTAssertLessThanOrEqual(report.diagnostics.count, limits.maximumDiagnostics + 1)
        }
        let report = validate(fixture().setting(text(0x00100040, "PRIVATE_MARKER", .CS)))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("PRIVATE_MARKER"))
        // Included Issuer of Patient ID macro: all Type 3, but a universal ID needs its type.
        let qualifiers = fixture().setting(.init(tag: 0x00100024, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: []))])))
        XCTAssertEqual(validate(qualifiers)[.attributes], .passed)
        let universal = fixture().setting(.init(tag: 0x00100024, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
            text(0x00400032, "1.2.3", .UT)]))])))
        XCTAssertTrue(validate(universal).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00100024), .item(0), .tag(0x00400033)]
        })
    }

    func test_SCPart10Corpus_preservesCommonRequirementsAndExplicitConditions() throws {
        let baseline = fixture().setting(text(0x00080060, "OT", .CS))
        let calendar = baseline.setting(text(0x00100033, "LOCAL DATE", .LO))
        let deidentified = baseline.setting(text(0x00120062, "YES", .CS))
        let responsible = baseline.setting(text(0x00102297, "SYNTHETIC^PERSON", .PN))
        let paired = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, pairedBodyPart: .satisfied)
        let cases: [(String, DicomDataSet, DicomCompositeImageModules.Conditions, DicomValidationReport.Outcome)] = [
            ("baseline", baseline, human, .passed),
            ("missing-modality", baseline.removing(0x00080060), human, .passed),
            ("unknown-subject", baseline, .init(), .incomplete),
            ("defined-conversion", baseline.setting(text(0x00080064, "PRIVATE", .CS)), human, .passed),
            ("missing-conversion", baseline.removing(0x00080064), human, .failed),
            ("missing-patient-id", baseline.removing(0x00100020), human, .failed),
            ("missing-study-id", baseline.removing(0x00200010), human, .failed),
            ("empty-study-uid", baseline.setting(text(0x0020000D, "", .UI)), human, .failed),
            ("missing-series-uid", baseline.removing(0x0020000E), human, .failed),
            ("invalid-sex", baseline.setting(text(0x00100040, "UNKNOWN", .CS)), human, .failed),
            ("calendar-missing", calendar, human, .failed),
            ("calendar-custom", calendar.setting(text(0x00100035, "LOCAL", .CS)), human, .passed),
            ("deid-missing", deidentified, human, .failed),
            ("deid-method", deidentified.setting(text(0x00120063, "SYNTHETIC", .LO)), human, .passed),
            ("animal-missing", baseline, animal, .failed),
            ("animal-valid", animalFixture().setting(text(0x00080060, "OT", .CS)), animal, .passed),
            ("animal-breed-missing", animalFixture().setting(text(0x00080060, "OT", .CS)).removing(0x00102292), animal, .failed),
            ("responsible-missing-role", responsible, human, .failed),
            ("responsible-empty", baseline.setting(text(0x00102297, "", .PN)), human, .passed),
            ("reference-missing", baseline.setting(.init(tag: 0x00200037, vr: .DS,
                                                          value: .strings(["1", "0", "0", "0", "1", "0"]))), human, .failed),
            ("laterality-missing", baseline, paired, .failed),
            ("laterality-conflict", baseline.setting(text(0x00200060, "R", .CS)).setting(text(0x00200062, "L", .CS)), paired, .failed)
        ]
        for (name, metadata, conditions, expected) in cases {
            var dataSet = metadata
            dataSet.set(text(0x00200013, "", .IS))
            dataSet.set(text(0x00200020, "", .CS))
            dataSet.set(text(0x00280004, "MONOCHROME2", .CS))
            for (tag, value) in [(0x00280010, UInt(2)), (0x00280011, 2), (0x00280002, 1),
                                 (0x00280100, 8), (0x00280101, 8), (0x00280102, 7), (0x00280103, 0)] {
                dataSet.set(.init(tag: tag, vr: .US, value: .unsignedIntegers([value])))
            }
            dataSet.set(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([1, 2, 3, 4]))))
            let bytes = try part10(dataSet)
            let fileMeta = try DicomPart10FileMetaParser.parse(bytes)
            let parsed = try DicomEncodedDataSetValidator.validate(Data(bytes.dropFirst(fileMeta.dataSetOffset)))
            XCTAssertEqual(parsed.report[.structure], .passed, name)
            let own = DicomCompositeImageModules.validate(try XCTUnwrap(parsed.dataSet), kind: .secondaryCapture, conditions: conditions)
            XCTAssertEqual(own[.attributes], expected, name)
            let instance = try DicomInstanceValidator.validate(bytes, imageConditions: conditions)
            XCTAssertEqual(instance[.attributes], expected == .failed ? .failed : .incomplete, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, imageConditions: conditions), instance)
            XCTAssertEqual(instance[.pixelsAndGeometry], name == "reference-missing" ? .incomplete : .passed, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_COMMON_IMAGE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": expected.rawValue,
                    "instanceAttributes": instance[.attributes].rawValue,
                    "conditions": ["nonHumanPatient": String(describing: conditions.nonHumanPatient),
                                   "nonBipedalAnatomy": String(describing: conditions.nonBipedalAnatomy),
                                   "pairedBodyPart": String(describing: conditions.pairedBodyPart)]], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func validate(_ dataSet: DicomDataSet) -> DicomValidationReport {
        DicomCompositeImageModules.validate(dataSet, kind: .secondaryCapture, conditions: human)
    }

    private func fixture() -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.7", .UI), text(0x00080018, "2.25.23213001", .UI),
            text(0x0020000D, "2.25.23213002", .UI), text(0x0020000E, "2.25.23213003", .UI),
            text(0x00100010, "", .PN), text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080020, "", .DA), text(0x00080030, "", .TM), text(0x00080090, "", .PN),
            text(0x00200010, "", .SH), text(0x00080050, "", .SH), text(0x00200011, "", .IS), text(0x00080064, "WSD", .CS)])
    }

    private func animalFixture() -> DicomDataSet {
        var dataSet = fixture()
        for element in [text(0x00102201, "Synthetic species", .LO), text(0x00102292, "", .LO),
                        text(0x00102297, "", .PN), text(0x00102299, "", .LO), text(0x00102210, "QUADRUPED", .CS),
                        .init(tag: 0x00102293, vr: .SQ, value: .sequence([])), .init(tag: 0x00102294, vr: .SQ, value: .sequence([]))] {
            dataSet.set(element)
        }
        return dataSet
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    private func part10(_ dataSet: DicomDataSet) throws -> Data {
        try DicomDataSetWriter.part10Data(from: dataSet)
    }
}
