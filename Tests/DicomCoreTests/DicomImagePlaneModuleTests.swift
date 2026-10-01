import Foundation
import XCTest
@testable import DicomCore

final class DicomImagePlaneModuleTests: XCTestCase {
    func test_instanceValidation_requiresPlaneForClassicCTAndMR() throws {
        for sop in ["1.2.840.10008.5.1.4.1.1.2", "1.2.840.10008.5.1.4.1.1.4"] {
            let dataSet = DicomDataSet(elements: [text(0x00080016, [sop], .UI), text(0x00080018, ["2.25.23213301"], .UI)])
            let report = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: dataSet))
            XCTAssertTrue(report.diagnostics.contains {
                $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00200037)] && $0.requirement == .type1
            })
        }
    }

    func test_moduleSelection_preservesSCSpacingCalibrationWithoutInventingPlane() {
        let empty = DicomDataSet(elements: [])
        for kind in [DicomCompositeImageModules.Kind.ct, .mr] {
            XCTAssertTrue(DicomImagePlaneModule.applies(to: empty, kind: kind))
        }
        XCTAssertFalse(DicomImagePlaneModule.applies(to: empty, kind: .secondaryCapture))
        XCTAssertFalse(DicomImagePlaneModule.applies(to: empty.setting(text(0x00280030, [".5", ".5"])), kind: .secondaryCapture))
        for tag in [0x00200032, 0x00200037] {
            XCTAssertTrue(DicomImagePlaneModule.applies(to: empty.setting(text(tag, [""])), kind: .secondaryCapture))
        }
    }

    func test_requiredAttributes_keepThicknessEmptyButRequirePositionOrientationAndSpacing() {
        XCTAssertEqual(validate(fixture()).outcome(requiring: [.attributes, .pixelsAndGeometry]), .passed)
        for tag in [0x00280030, 0x00200032, 0x00200037, 0x00180050] {
            XCTAssertEqual(validate(fixture().removing(tag))[.attributes], .failed)
            if tag != 0x00180050 { XCTAssertEqual(validate(fixture().setting(text(tag, ["", ""])))[.attributes], .failed) }
        }
        XCTAssertEqual(validate(fixture().setting(text(0x00180050, ["", ""])))[.attributes], .passed)
        let unknown = fixture().setting(.init(tag: 0x00200032, vr: .UN, value: .bytes(Data([0, 1]))))
        XCTAssertEqual(validate(unknown)[.pixelsAndGeometry], .incomplete)
    }

    func test_decimalValues_checkMultiplicitySpacingAndSingleDimensionZero() {
        for (tag, values) in [(0x00280030, ["1"]), (0x00200032, ["0", "0"]), (0x00200037, ["1", "0", "0"]),
                              (0x00180088, ["-1"]), (0x00280030, ["-1", "1"]), (0x00280030, ["0", "1"]),
                              (0x00201041, ["NaN"])] {
            XCTAssertEqual(validate(fixture().setting(text(tag, values)))[.pixelsAndGeometry], .failed)
        }
        XCTAssertEqual(validate(fixture().setting(text(0x00200032, ["-100", "-200.5", "3E1"])))[.pixelsAndGeometry], .passed)
        for tag in [0x00180050, 0x00180088, 0x00201041] {
            XCTAssertEqual(validate(fixture().setting(text(tag, ["", ""])))[.pixelsAndGeometry], .passed)
        }
        let zero = fixture().setting(number(0x00280010, 1)).setting(text(0x00280030, ["0", "1"]))
        XCTAssertEqual(validate(zero)[.pixelsAndGeometry], .passed)
        XCTAssertEqual(validate(zero.removing(0x00280010))[.pixelsAndGeometry], .incomplete)
        for value in ["1E-999", "1E999"] {
            XCTAssertEqual(validate(fixture().setting(text(0x00200032, [value, "0", "0"])))[.pixelsAndGeometry], .incomplete)
        }
    }

    func test_exactBases_rejectInvalidOrDegenerateVectorsAndRetainRoundingLimitations() {
        // Rounded cosines pass when unit length and orthogonality hold within their encoded precision.
        for values in [["1", "0", "0", "0", "1", "0"], [".6", ".8", "0", "-.8", ".6", "0"],
                       ["0", "0", "-1", "0", "1", "0"], [".70710678", ".70710678", "0", "-.70710678", ".70710678", "0"]] {
            XCTAssertEqual(validate(fixture().setting(text(0x00200037, values)))[.pixelsAndGeometry], .passed)
        }
        for values in [["2", "0", "0", "0", "1", "0"], ["0", "0", "0", "0", "1", "0"],
                       ["1", "0", "0", "1", "0", "0"], [".6", ".8", "0", ".3", ".4", "0"],
                       ["1", "0", "0", ".6", ".8", "0"], [".5", "0", "0", "0", ".5", "0"], [".72", ".72", "0", "-.72", ".72", "0"]] {
            XCTAssertEqual(validate(fixture().setting(text(0x00200037, values)))[.pixelsAndGeometry], .failed)
        }
        for values in [["1", "1E-999", "0", "0", "1", "0"]] {
            XCTAssertEqual(validate(fixture().setting(text(0x00200037, values)))[.pixelsAndGeometry], .incomplete)
        }
        // Issue #2487: cosines truncated by a scanner (a Siemens MR of the pydicom test data) miss unit length by
        // 4e-5, beyond their own rounding bound; within 1e-3 that is a warning, not a failed geometry layer.
        let truncated = ["6.53996e-01", "7.56504e-01", "3.77102e-03", "-1.33901e-03", "6.14239e-03", "-1.00000e+00"]
        let report = validate(fixture().setting(text(0x00200037, truncated)))
        XCTAssertEqual(report[.pixelsAndGeometry], .passed)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .spatialGeometryInvalid && $0.severity == .warning })
        XCTAssertEqual(validate(fixture().setting(text(0x00200037, ["1", "0.002", "0", "0", "1", "0"])))[.pixelsAndGeometry], .failed, "beyond 1e-3 stays an error")
    }

    func test_workAndDiagnosticBudgets_neverApproveUnvisitedGeometry() {
        for maximum in [0, 1, 10, 30] {
            let report = DicomImagePlaneModule.validate(fixture(), limits: .init(maximumRuleEvaluations: maximum, maximumDiagnostics: 1))
            XCTAssertEqual(report[.pixelsAndGeometry], .incomplete)
            XCTAssertLessThanOrEqual(report.diagnostics.count, 3)
        }
        let invalid = fixture().setting(text(0x00280030, ["-1", "-1"]))
        let report = DicomImagePlaneModule.validate(invalid, limits: .init(maximumDiagnostics: 1))
        XCTAssertEqual(report[.pixelsAndGeometry], .failed)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
    }

    func test_SCPart10Corpus_composesPlaneRequirementsAndGeometryWithoutRepair() throws {
        var baseline = fixture()
        for (tag, vr, value) in [(0x00080016, DicomVR.UI, "1.2.840.10008.5.1.4.1.1.7"),
            (0x00080018, .UI, "2.25.23213301"), (0x0020000D, .UI, "2.25.23213302"),
            (0x0020000E, .UI, "2.25.23213303"), (0x00200052, .UI, "2.25.23213304"), (0x00201040, .LO, ""),
            (0x00100010, .PN, ""), (0x00100020, .LO, ""), (0x00100030, .DA, ""), (0x00100040, .CS, ""),
            (0x00080020, .DA, ""), (0x00080030, .TM, ""), (0x00080090, .PN, ""), (0x00200010, .SH, ""),
            (0x00080050, .SH, ""), (0x00200011, .IS, ""), (0x00200013, .IS, ""), (0x00200020, .CS, ""),
            (0x00080064, .CS, "WSD"), (0x00080060, .CS, "OT"), (0x00280004, .CS, "MONOCHROME2")] {
            baseline.set(text(tag, [value], vr))
        }
        for (tag, value) in [(0x00280002, UInt(1)), (0x00280100, 8), (0x00280101, 8), (0x00280102, 7), (0x00280103, 0)] {
            baseline.set(number(tag, value))
        }
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome, DicomValidationReport.Outcome)] = [
            ("baseline", baseline, .passed, .passed),
            ("rational-oblique", baseline.setting(text(0x00200037, [".6", ".8", "0", "-.8", ".6", "0"])), .passed, .passed),
            ("negative-position", baseline.setting(text(0x00200032, ["-100", "-20.5", "3E1"])), .passed, .passed),
            ("missing-position", baseline.removing(0x00200032), .failed, .incomplete),
            ("missing-orientation", baseline.removing(0x00200037), .failed, .incomplete),
            ("missing-spacing", baseline.removing(0x00280030), .failed, .incomplete),
            ("missing-thickness", baseline.removing(0x00180050), .failed, .passed),
            ("negative-slice-spacing", baseline.setting(text(0x00180088, ["-1"])), .passed, .failed),
            ("negative-pixel-spacing", baseline.setting(text(0x00280030, ["-1", "1"])), .passed, .failed),
            ("zero-spacing-invalid", baseline.setting(text(0x00280030, ["0", "1"])), .passed, .failed),
            ("zero-spacing-single-row", baseline.setting(number(0x00280010, 1)).setting(text(0x00280030, ["0", "1"])), .passed, .passed),
            ("orientation-range", baseline.setting(text(0x00200037, ["2", "0", "0", "0", "1", "0"])), .passed, .failed),
            ("zero-vector", baseline.setting(text(0x00200037, ["0", "0", "0", "0", "1", "0"])), .passed, .failed),
            ("parallel-vectors", baseline.setting(text(0x00200037, [".6", ".8", "0", ".3", ".4", "0"])), .passed, .failed),
            ("nonorthogonal-unit-vectors", baseline.setting(text(0x00200037, ["1", "0", "0", ".6", ".8", "0"])), .passed, .failed),
            ("rounded-oblique", baseline.setting(text(0x00200037, [".70710678", ".70710678", "0", "-.70710678", ".70710678", "0"])), .passed, .passed),
            ("nonunit-vectors", baseline.setting(text(0x00200037, [".5", "0", "0", "0", ".5", "0"])), .passed, .failed),
            ("position-underflow", baseline.setting(text(0x00200032, ["1E-999", "0", "0"])), .passed, .incomplete),
            ("position-multiplicity", baseline.setting(text(0x00200032, ["0", "0"])), .incomplete, .incomplete)
        ]
        for (name, metadata, attributes, geometry) in cases {
            var dataSet = metadata
            let count = try XCTUnwrap(dataSet[0x00280010]?.intValue) * 2
            dataSet.set(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 1, count: count))))
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let meta = try DicomPart10FileMetaParser.parse(bytes)
            let parsed = try DicomEncodedDataSetValidator.validate(Data(bytes.dropFirst(meta.dataSetOffset)))
            XCTAssertEqual(parsed.report[.structure], .passed, name)
            let own = validate(try XCTUnwrap(parsed.dataSet))
            XCTAssertEqual(own[.attributes], attributes, name)
            XCTAssertEqual(own[.pixelsAndGeometry], geometry, name)
            let conditions = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, pairedBodyPart: .unsatisfied,
                temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)
            let instance = try DicomInstanceValidator.validate(bytes, imageConditions: conditions)
            let scFailure = ["negative-pixel-spacing", "zero-spacing-invalid"].contains(name)
            XCTAssertEqual(instance[.attributes], attributes == .failed || scFailure ? .failed : attributes, name)
            XCTAssertEqual(instance[.pixelsAndGeometry], geometry, name)
            if name == "position-multiplicity" {
                XCTAssertEqual(instance[.vrAndVM], .failed)
                XCTAssertTrue(instance.diagnostics.contains {
                    $0.code == .invalidMultiplicity && $0.layer == .vrAndVM && $0.path == [.tag(0x00200032)]
                })
            }
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, imageConditions: conditions), instance)
            if let folder = ProcessInfo.processInfo.environment["DICOM_IMAGE_PLANE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": own[.attributes].rawValue,
                    "geometry": own[.pixelsAndGeometry].rawValue, "instanceAttributes": instance[.attributes].rawValue,
                    "instanceGeometry": instance[.pixelsAndGeometry].rawValue, "instanceVRVM": instance[.vrAndVM].rawValue], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func validate(_ dataSet: DicomDataSet) -> DicomValidationReport { DicomImagePlaneModule.validate(dataSet) }
    private func fixture() -> DicomDataSet {
        .init(elements: [text(0x00280030, [".5", ".5"]), text(0x00200032, ["0", "0", "0"]),
            text(0x00200037, ["1", "0", "0", "0", "1", "0"]), text(0x00180050, [""]),
            number(0x00280010, 2), number(0x00280011, 2)])
    }
    private func text(_ tag: Int, _ values: [String], _ vr: DicomVR = .DS) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings(values))
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
}
