import Foundation
import XCTest
@testable import DicomCore

final class DicomSCImageModuleTests: XCTestCase {
    func test_instanceValidation_requiresSpacingWhenCalibrationIsKnown() throws {
        let dataSet = fixture().setting(text(0x00080016, ["1.2.840.10008.5.1.4.1.1.7"], .UI))
            .setting(text(0x00080018, ["2.25.23213201"], .UI))
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
        let report = try DicomInstanceValidator.validate(bytes, imageConditions: .init(calibratedImage: .satisfied))
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00280030)] && $0.requirement == .type1C
        })
    }

    func test_calibrationFacts_preserveRequiredEmptyAndUnknownStates() {
        XCTAssertEqual(validate(fixture())[.attributes], .passed)
        XCTAssertEqual(DicomSCImageModule.validate(fixture())[.attributes], .incomplete)
        XCTAssertEqual(DicomSCImageModule.validate(fixture(), calibratedImage: .satisfied)[.attributes], .failed)
        XCTAssertEqual(DicomSCImageModule.validate(fixture().setting(text(0x00280030, ["", ""])),
            calibratedImage: .satisfied)[.attributes], .failed)
        let calibrated = fixture().setting(text(0x00280A02, ["FIDUCIAL"], .CS))
            .setting(text(0x00280A04, ["Synthetic calibration"], .LO))
        XCTAssertEqual(DicomSCImageModule.validate(calibrated)[.attributes], .failed)
        let valid = calibrated.setting(text(0x00280030, ["0.5", "0.5"]))
        XCTAssertEqual(DicomSCImageModule.validate(valid)[.attributes], .passed)
        XCTAssertEqual(validate(valid)[.attributes], .failed)
        XCTAssertEqual(DicomSCImageModule.validate(valid.removing(0x00280A04))[.attributes], .failed)
        XCTAssertEqual(DicomSCImageModule.validate(valid.setting(text(0x00280A04, [""], .LO)))[.attributes], .failed)
        XCTAssertEqual(validate(fixture().setting(text(0x00280A04, ["Synthetic"], .LO)))[.attributes], .failed)
        XCTAssertEqual(validate(fixture().setting(text(0x00280A02, ["LOCAL"], .CS)))[.attributes], .failed)
        let emptyType = fixture().setting(text(0x00280A02, [""], .CS))
        XCTAssertEqual(validate(emptyType)[.attributes], .failed)
        XCTAssertEqual(validate(emptyType.setting(text(0x00280A04, ["Synthetic"], .LO)))[.attributes], .passed)
    }

    func test_spacingValues_checkOrderPositivityAndSingleDimensionZero() {
        for tag in [0x00280030, 0x00182010, 0x00181164] {
            for values in [["0.3", "0.25"], ["3E-1", "25E-2"], [""], ["", ""], []] {
                XCTAssertEqual(validate(fixture().setting(text(tag, values)))[.attributes], .passed)
            }
            for values in [["-1", "1"], ["0", "1"], ["1", "0"], ["1"], ["1", "2", "3"], ["NaN", "1"]] {
                XCTAssertEqual(validate(fixture().setting(text(tag, values)))[.attributes], .failed)
            }
            let zeroRow = fixture().setting(number(0x00280010, 1)).setting(text(tag, ["0", "1"]))
            XCTAssertEqual(validate(zeroRow)[.attributes], .passed)
            XCTAssertEqual(validate(zeroRow.removing(0x00280010))[.attributes], .incomplete)
            let zeroColumn = fixture().setting(number(0x00280011, 1)).setting(text(tag, ["1", "0"]))
            XCTAssertEqual(validate(zeroColumn)[.attributes], .passed)
            for value in ["1E-999", "1E999", "1.23456789E-128"] {
                XCTAssertEqual(validate(zeroRow.setting(text(tag, [value, "1"])))[.attributes], .incomplete)
            }
        }
    }

    func test_uncalibratedSpacing_matchesEachAcquisitionReferenceExactly() {
        let image = fixture().setting(text(0x00280030, ["0.30", "0.25"]))
        for tag in [0x00182010, 0x00181164] {
            XCTAssertEqual(validate(image.setting(text(tag, ["3E-1", "25E-2"])))[.attributes], .passed)
            let different = image.setting(text(tag, ["0.30000000000001", "0.25"]))
            XCTAssertEqual(validate(different)[.attributes], .failed)
            XCTAssertEqual(DicomSCImageModule.validate(different, calibratedImage: .satisfied)[.attributes], .passed)
            XCTAssertEqual(DicomSCImageModule.validate(different)[.attributes], .passed)
        }
        let conflicting = image.setting(text(0x00182010, [".30", ".25"]))
            .setting(text(0x00181164, [".30", ".26"]))
        XCTAssertEqual(validate(conflicting)[.attributes], .failed)
    }

    func test_nominalSpacing_agreesWithAspectWithoutFloatingPointTolerance() {
        let dataSet = fixture().setting(text(0x00182010, [".3", ".25"]))
        XCTAssertEqual(validate(dataSet.setting(text(0x00280034, ["6", "5"], .IS)))[.attributes], .passed)
        for ratio in [["5", "6"], ["0", "1"], ["-6", "-5"]] {
            XCTAssertEqual(validate(dataSet.setting(text(0x00280034, ratio, .IS)))[.attributes], .failed)
        }
        let precise = fixture().setting(text(0x00182010, ["1.00000000000001", "1"]))
            .setting(text(0x00280034, ["1", "1"], .IS))
        XCTAssertEqual(validate(precise)[.attributes], .failed)
        let large = fixture().setting(text(0x00182010, ["9E127", "9E127"]))
            .setting(text(0x00280034, ["999999999999", "999999999999"], .IS))
        XCTAssertEqual(validate(large)[.attributes], .passed)
        XCTAssertEqual(validate(large.setting(text(0x00182010, ["9E155", "9E155"])))[.attributes], .incomplete)
    }

    func test_documentCodesAndViews_retainNestedRequirementsAndLimits() {
        let code = DicomDataSet(elements: [text(0x00080120, ["urn:example:synthetic"], .UR), text(0x00080104, ["Synthetic"], .LO)])
        let document = fixture().setting(sequence([code]))
        XCTAssertEqual(validate(document)[.attributes], .passed)
        let invalid = validate(fixture().setting(sequence([code.removing(0x00080104)])))
        XCTAssertTrue(invalid.diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040E008), .item(0), .tag(0x00080104)]
        })
        XCTAssertEqual(validate(fixture().setting(sequence([])))[.attributes], .failed)
        XCTAssertEqual(validate(fixture().setting(sequence([code, code])))[.attributes], .passed)
        let view = fixture().setting(.init(tag: 0x00540220, vr: .SQ, value: .sequence([.init(dataSet: code)])))
        XCTAssertEqual(validate(view)[.attributes], .incomplete)
        let invalidModifier = code.setting(.init(tag: 0x00540222, vr: .SQ,
            value: .sequence([.init(dataSet: code.removing(0x00080104))])))
        let invalidView = fixture().setting(.init(tag: 0x00540220, vr: .SQ, value: .sequence([.init(dataSet: invalidModifier)])))
        XCTAssertTrue(validate(invalidView).diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00540220), .item(0), .tag(0x00540222), .item(0), .tag(0x00080104)]
        })
        XCTAssertEqual(validate(fixture().setting(text(0x00540500, ["APEX_TO_BASE"], .CS)))[.attributes], .incomplete)
        for empty in [DicomDataValue.empty, .strings([""])] {
            XCTAssertEqual(validate(fixture().setting(.init(tag: 0x00540500, vr: .CS, value: empty)))[.attributes], .passed)
        }
        for budget in [0, 1, 5] {
            XCTAssertEqual(DicomSCImageModule.validate(document, calibratedImage: .unsatisfied,
                limits: .init(maximumRuleEvaluations: budget, maximumDiagnostics: 1))[.attributes], .incomplete)
        }
        XCTAssertEqual(DicomSCImageModule.validate(document, calibratedImage: .unsatisfied,
            limits: .init(maximumDepth: 0))[.attributes], .incomplete)
    }

    func test_SCPart10Corpus_preservesCalibrationEvidenceAndExactComparisons() throws {
        var baseline = fixture()
        for (tag, vr, value) in [(0x00080016, DicomVR.UI, "1.2.840.10008.5.1.4.1.1.7"),
            (0x00080018, .UI, "2.25.23213201"), (0x0020000D, .UI, "2.25.23213202"),
            (0x0020000E, .UI, "2.25.23213203"), (0x00100010, .PN, ""), (0x00100020, .LO, ""),
            (0x00100030, .DA, ""), (0x00100040, .CS, ""), (0x00080020, .DA, ""), (0x00080030, .TM, ""),
            (0x00080090, .PN, ""), (0x00200010, .SH, ""), (0x00080050, .SH, ""), (0x00200011, .IS, ""),
            (0x00200013, .IS, ""), (0x00200020, .CS, ""), (0x00080064, .CS, "WSD"), (0x00080060, .CS, "OT"),
            (0x00280004, .CS, "MONOCHROME2")] {
            baseline.set(text(tag, [value], vr))
        }
        for (tag, value) in [(0x00280002, UInt(1)), (0x00280100, 8), (0x00280101, 8), (0x00280102, 7), (0x00280103, 0)] {
            baseline.set(number(tag, value))
        }
        let spaced = baseline.setting(text(0x00280030, [".3", ".25"]))
        let calibrated = spaced.setting(text(0x00280A02, ["FIDUCIAL"], .CS))
            .setting(text(0x00280A04, ["Synthetic calibration"], .LO))
        let nominal = baseline.setting(text(0x00182010, [".3", ".25"]))
        let different = spaced.setting(text(0x00182010, [".31", ".25"]))
        let code = DicomDataSet(elements: [text(0x00080120, ["urn:example:synthetic"], .UR), text(0x00080104, ["Synthetic"], .LO)])
        let cases: [(String, DicomDataSet, DicomAttributeRule.Truth, DicomValidationReport.Outcome)] = [
            ("baseline", baseline, .unsatisfied, .passed),
            ("delimiter-only-spacing", baseline.setting(text(0x00182010, ["", ""])), .unsatisfied, .passed),
            ("unknown-calibration", baseline, .undetermined, .incomplete),
            ("missing-spacing", baseline, .satisfied, .failed),
            ("calibrated", calibrated, .undetermined, .passed),
            ("missing-description", calibrated.removing(0x00280A04), .undetermined, .failed),
            ("empty-description", calibrated.setting(text(0x00280A04, [""], .LO)), .undetermined, .failed),
            ("invalid-type", calibrated.setting(text(0x00280A02, ["LOCAL"], .CS)), .satisfied, .failed),
            ("contradictory-fact", calibrated, .unsatisfied, .failed),
            ("matching-spacing", spaced.setting(text(0x00182010, ["3E-1", "25E-2"])), .unsatisfied, .passed),
            ("mismatching-spacing", different, .unsatisfied, .failed),
            ("inferred-calibration", different, .undetermined, .passed),
            ("matching-aspect", nominal.setting(text(0x00280034, ["6", "5"], .IS)), .unsatisfied, .passed),
            ("reversed-aspect", nominal.setting(text(0x00280034, ["5", "6"], .IS)), .unsatisfied, .failed),
            ("precise-aspect", baseline.setting(text(0x00182010, ["1.00000000000001", "1"]))
                .setting(text(0x00280034, ["1", "1"], .IS)), .unsatisfied, .failed),
            ("zero-invalid", baseline.setting(text(0x00182010, ["0", "1"])), .unsatisfied, .failed),
            ("zero-single-row", baseline.setting(number(0x00280010, 1)).setting(text(0x00182010, ["0", "1"])), .unsatisfied, .passed),
            ("decimal-underflow", baseline.setting(number(0x00280010, 1)).setting(text(0x00182010, ["1E-999", "1"])), .unsatisfied, .incomplete),
            ("document-code", baseline.setting(sequence([code])), .unsatisfied, .passed),
            ("document-empty", baseline.setting(sequence([])), .unsatisfied, .failed),
            ("document-missing-meaning", baseline.setting(sequence([code.removing(0x00080104)])), .unsatisfied, .failed)
        ]
        for (name, metadata, fact, expected) in cases {
            var dataSet = metadata
            let count = try XCTUnwrap(dataSet[0x00280010]?.intValue) * 2
            dataSet.set(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 1, count: count))))
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let meta = try DicomPart10FileMetaParser.parse(bytes)
            let parsed = try DicomEncodedDataSetValidator.validate(Data(bytes.dropFirst(meta.dataSetOffset)))
            XCTAssertEqual(parsed.report[.structure], .passed, name)
            let own = DicomSCImageModule.validate(try XCTUnwrap(parsed.dataSet), calibratedImage: fact)
            XCTAssertEqual(own[.attributes], expected, name)
            let conditions = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, pairedBodyPart: .unsatisfied,
                temporallyRelatedSeries: .unsatisfied, calibratedImage: fact)
            let instance = try DicomInstanceValidator.validate(bytes, imageConditions: conditions)
            XCTAssertEqual(instance[.attributes], expected, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, imageConditions: conditions), instance)
            if let folder = ProcessInfo.processInfo.environment["DICOM_SC_IMAGE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": own[.attributes].rawValue,
                    "instanceAttributes": instance[.attributes].rawValue, "calibratedImage": String(describing: fact)], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func validate(_ dataSet: DicomDataSet) -> DicomValidationReport {
        DicomSCImageModule.validate(dataSet, calibratedImage: .unsatisfied)
    }
    private func fixture() -> DicomDataSet { .init(elements: [number(0x00280010, 2), number(0x00280011, 2)]) }
    private func text(_ tag: Int, _ values: [String], _ vr: DicomVR = .DS) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings(values))
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func sequence(_ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: 0x0040E008, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
