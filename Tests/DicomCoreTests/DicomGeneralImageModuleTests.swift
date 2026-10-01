import Foundation
import XCTest
@testable import DicomCore

final class DicomGeneralImageModuleTests: XCTestCase {
    func test_conditionScans_respectCallerBudgetBeforeLateValues() {
        for (tag, values, vr) in [(0x00080008, Array(repeating: "", count: 1000) + ["PRIVATE"], DicomVR.CS),
            (0x00282112, Array(repeating: "", count: 1000) + ["1"], .DS),
            (0x00282114, Array(repeating: "", count: 1000) + ["METHOD"], .CS)] {
            let source = fixture().setting(text(0x00282112, ["1"], .DS))
                .setting(text(0x00282114, ["METHOD"], .CS)).setting(text(tag, values, vr))
            let report = DicomGeneralImageModule.validate(source, kind: .secondaryCapture,
                temporallyRelatedSeries: .unsatisfied, limits: .init(maximumRuleEvaluations: 100))
            XCTAssertEqual(report[.attributes], .incomplete)
            XCTAssertEqual(report.diagnostics.map(\.code), [.evaluationLimitReached])
            XCTAssertEqual(report.diagnostics.first?.path, [.tag(tag)])
        }
    }

    func test_conditionBudgets_areCumulativeAndPublicRulesRemainBounded() {
        let paired = fixture().setting(text(0x00282112, Array(repeating: "1", count: 51), .DS))
            .setting(text(0x00282114, Array(repeating: "METHOD", count: 51)))
        let limited = DicomGeneralImageModule.validate(paired, kind: .secondaryCapture,
            temporallyRelatedSeries: .unsatisfied, limits: .init(maximumRuleEvaluations: 100))
        XCTAssertEqual(limited.diagnostics.map(\.code), [.evaluationLimitReached])
        XCTAssertEqual(limited.diagnostics.first?.path, [.tag(0x00282114)])
        XCTAssertEqual(validate(paired)[.attributes], .passed)

        let large = fixture().setting(text(0x00080008, Array(repeating: "", count: 100_000) + ["PRIVATE"]))
        let rules = DicomGeneralImageModule.rules(for: large, kind: .secondaryCapture, temporallyRelatedSeries: .unsatisfied)
        let projected = DicomAttributeValidator.validate(large, rules: rules, limits: .init(maximumRuleEvaluations: 1_000_000))
        XCTAssertEqual(projected[.attributes], .incomplete)
        let evaluated = DicomGeneralImageModule.validate(large, kind: .secondaryCapture,
            temporallyRelatedSeries: .unsatisfied, limits: .init(maximumRuleEvaluations: 1_000_000))
        XCTAssertEqual(evaluated[.attributes], .failed)
    }

    func test_instanceValidation_checksGeneralImageOnOriginalBytes() throws {
        let metadata = fixture().setting(text(0x00080016, ["1.2.840.10008.5.1.4.1.1.7"], .UI))
            .setting(text(0x00080018, ["2.25.23213101"], .UI)).removing(0x00200013)
        let bytes = try DicomDataSetWriter.part10Data(from: metadata)
        let report = try DicomInstanceValidator.validate(bytes)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00200013)] && $0.requirement == .type2
        })
    }

    func test_requiredAndConditionalAttributes_preserveEmptyType2AndUnknownSeries() {
        XCTAssertEqual(validate(fixture())[.attributes], .passed)
        XCTAssertEqual(validate(fixture().removing(0x00200013))[.attributes], .failed)
        XCTAssertEqual(validate(fixture().removing(0x00200020))[.attributes], .failed)
        XCTAssertEqual(validate(fixture().setting(text(0x00280008, ["1"], .IS)))[.attributes], .passed)
        XCTAssertEqual(validate(fixture().setting(text(0x00280008, ["2"], .IS)))[.attributes], .failed)
        for kind in [DicomCompositeImageModules.Kind.ct, .mr] {
            XCTAssertEqual(DicomGeneralImageModule.validate(fixture().removing(0x00200020), kind: kind,
                                                            temporallyRelatedSeries: .unsatisfied)[.attributes], .passed)
        }
        XCTAssertEqual(DicomGeneralImageModule.validate(fixture(), kind: .secondaryCapture)[.attributes], .incomplete)
        let dated = fixture().setting(text(0x00080023, [""], .DA)).setting(text(0x00080033, [""], .TM))
        XCTAssertEqual(DicomGeneralImageModule.validate(dated, kind: .secondaryCapture,
                                                        temporallyRelatedSeries: .satisfied)[.attributes], .passed)
        for tag in [0x00080023, 0x00080033] {
            XCTAssertEqual(DicomGeneralImageModule.validate(dated.removing(tag), kind: .secondaryCapture,
                                                            temporallyRelatedSeries: .satisfied)[.attributes], .failed)
        }
    }

    func test_imageType_usesPositionalEnumsAndPreservesOptionalTrailingValues() {
        for values in [[""], ["ORIGINAL", "PRIMARY"], ["DERIVED", "SECONDARY", "", "PRIVATE"]] {
            XCTAssertEqual(validate(fixture().setting(text(0x00080008, values)))[.attributes], .passed)
        }
        for values in [["ORIGINAL"], ["PRIMARY", "ORIGINAL"], ["LOCAL", "PRIMARY"], ["ORIGINAL", ""], ["", "", "PRIVATE"]] {
            XCTAssertEqual(validate(fixture().setting(text(0x00080008, values)))[.attributes], .failed)
        }
    }

    func test_orientation_parsesBipedAndQuadrupedTermsWithoutMixingThem() {
        for values in [["L", "P"], ["A", "FR"], ["LPH", "AF"]] {
            XCTAssertEqual(validate(fixture().setting(text(0x00200020, values)))[.attributes], .passed)
        }
        for values in [["L"], ["L", ""], ["LEV", "CD"], ["LEFT", "POSTERIOR"], ["LAPH", "F"]] {
            XCTAssertEqual(validate(fixture().setting(text(0x00200020, values)))[.attributes], .failed)
        }
        let quadruped = fixture().setting(text(0x00102210, ["QUADRUPED"]))
        for values in [["LEV", "CD"], ["RT", "D"], ["M", "PL"]] {
            XCTAssertEqual(validate(quadruped.setting(text(0x00200020, values)))[.attributes], .passed)
        }
        XCTAssertEqual(validate(quadruped.setting(text(0x00200020, ["A", "P"])))[.attributes], .failed)
        let unknown = fixture().setting(text(0x00102210, ["UNKNOWN"])).setting(text(0x00200020, ["L", "P"]))
        XCTAssertEqual(validate(unknown)[.attributes], .incomplete)
    }

    func test_qualityFlagsAndPresentationShape_enforceTheirOwnEnumerations() {
        for (tag, values) in [(0x00280300, ["YES", "NO", "BOTH"]), (0x00280301, ["YES", "NO"]),
                              (0x00280302, ["YES", "NO"]), (0x00282110, ["00", "01"])] {
            for value in values { XCTAssertEqual(validate(fixture().setting(text(tag, [value])))[.attributes], .passed) }
            XCTAssertEqual(validate(fixture().setting(text(tag, ["LOCAL"])))[.attributes], .failed)
        }
        for photo in ["MONOCHROME1", "MONOCHROME2", "RGB", "PALETTE COLOR", "YBR_FULL"] {
            let dataSet = fixture().setting(text(0x00280004, [photo]))
            let shape = photo == "MONOCHROME1" ? "INVERSE" : "IDENTITY"
            XCTAssertEqual(validate(dataSet.setting(text(0x20500020, [shape])))[.attributes], .passed)
            XCTAssertEqual(validate(dataSet.setting(text(0x20500020, [shape == "INVERSE" ? "IDENTITY" : "INVERSE"])))[.attributes], .failed)
        }
        XCTAssertEqual(validate(fixture().setting(text(0x20500020, [""])))[.attributes], .passed)
        XCTAssertEqual(validate(fixture().removing(0x00280004).setting(text(0x20500020, ["IDENTITY"])))[.attributes], .incomplete)
    }

    func test_lossyMethodRatioCounts_mustAgreeWithoutClosingDefinedTerms() {
        let dataSet = fixture().setting(text(0x00282112, ["3", "5"], .DS))
        XCTAssertEqual(validate(dataSet)[.attributes], .passed)
        XCTAssertEqual(validate(dataSet.setting(text(0x00282114, ["PRIVATE", "ISO_10918_1"])))[.attributes], .passed)
        XCTAssertEqual(validate(dataSet.setting(text(0x00282114, ["ISO_10918_1"])))[.attributes], .failed)
    }

    func test_optionalEmptyValues_doNotDeclareFrameOrCompressionCounts() {
        for empty in [DicomDataValue.empty, .strings([]), .strings([""]), .strings([" "])] {
            XCTAssertEqual(validate(fixture().setting(.init(tag: 0x00280008, vr: .IS, value: empty)))[.attributes], .passed)
            let ratios = fixture().setting(text(0x00282112, ["3", "5"], .DS))
                .setting(.init(tag: 0x00282114, vr: .CS, value: empty))
            XCTAssertEqual(validate(ratios)[.attributes], .passed)
            let methods = fixture().setting(text(0x00282114, ["ISO_10918_1", "PRIVATE"]))
                .setting(.init(tag: 0x00282112, vr: .DS, value: empty))
            XCTAssertEqual(validate(methods)[.attributes], .passed)
        }
        XCTAssertEqual(validate(fixture().setting(text(0x00280008, ["1", "1"], .IS)))[.attributes], .failed)
    }

    func test_delimiterOnlyValues_preserveEmptyOptionalAndType2Semantics() {
        XCTAssertEqual(validate(fixture().setting(text(0x00080008, ["", "", ""])))[.attributes], .passed)
        XCTAssertEqual(validate(fixture().setting(text(0x00200020, ["", ""])))[.attributes], .passed)
        let ratios = fixture().setting(text(0x00282112, ["", ""], .DS)).setting(text(0x00282114, ["ISO_10918_1"]))
        XCTAssertEqual(validate(ratios)[.attributes], .passed)
        let methods = fixture().setting(text(0x00282112, ["3"], .DS)).setting(text(0x00282114, ["", ""]))
        XCTAssertEqual(validate(methods)[.attributes], .passed)
    }

    func test_generalIcon_canExceedSRSizeButKeepsNativeLengthAndNestedPaths() {
        let image = icon()
        XCTAssertEqual(DicomSRIconImageValidator.validate(image, pixelDataSource: .native)[.attributes], .failed)
        XCTAssertEqual(DicomSRIconImageValidator.validate(image, pixelDataSource: .native, kind: .generalImage)
            .outcome(requiring: [.attributes, .pixelsAndGeometry]), .passed)
        let dataSet = fixture().setting(sequence(0x00880200, [image]))
        XCTAssertEqual(validate(dataSet, source: .native).outcome(requiring: [.attributes, .pixelsAndGeometry]), .passed)
        XCTAssertEqual(validate(dataSet)[.pixelsAndGeometry], .incomplete)
        let short = fixture().setting(sequence(0x00880200, [image.setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([1]))))]))
        XCTAssertTrue(validate(short, source: .native).diagnostics.contains {
            $0.code == .pixelDataLengthMismatch && $0.path == [.tag(0x00880200), .item(0), .tag(0x7FE00010)]
        })
        for icons in [[], [image, image]] {
            XCTAssertEqual(validate(fixture().setting(sequence(0x00880200, icons)), source: .native)[.attributes], .failed)
        }
    }

    func test_budgetAndUnqualifiedMacros_neverProduceFalseApproval() {
        let dataSet = fixture().setting(sequence(0x00880200, [icon()]))
        for maximum in [0, 1, 10, 20] {
            let report = DicomGeneralImageModule.validate(dataSet, kind: .secondaryCapture,
                temporallyRelatedSeries: .unsatisfied, iconPixelDataSource: .native,
                limits: .init(maximumRuleEvaluations: maximum, maximumDiagnostics: 2))
            XCTAssertNotEqual(report.outcome(requiring: [.attributes, .pixelsAndGeometry]), .passed)
            XCTAssertLessThanOrEqual(report.diagnostics.count, 4)
        }
        // An empty Real World Value Mapping item lacks its Type 1 label, units and mapping attributes.
        XCTAssertEqual(validate(fixture().setting(sequence(0x00409096, [.init(elements: [])])))[.attributes], .failed)
        let shallow = DicomGeneralImageModule.validate(dataSet, kind: .secondaryCapture,
            temporallyRelatedSeries: .unsatisfied, iconPixelDataSource: .native, limits: .init(maximumDepth: 0))
        XCTAssertEqual(shallow[.attributes], .incomplete)
        XCTAssertEqual(shallow[.pixelsAndGeometry], .incomplete)
    }

    func test_SCPart10Corpus_checksGeneralImageWithoutClaimingWholeIOD() throws {
        var baseline = fixture()
        for (tag, vr, value) in [(0x00080016, DicomVR.UI, "1.2.840.10008.5.1.4.1.1.7"),
            (0x00080018, .UI, "2.25.23213101"), (0x0020000D, .UI, "2.25.23213102"),
            (0x0020000E, .UI, "2.25.23213103"), (0x00100010, .PN, ""), (0x00100020, .LO, ""),
            (0x00100030, .DA, ""), (0x00100040, .CS, ""), (0x00080020, .DA, ""), (0x00080030, .TM, ""),
            (0x00080090, .PN, ""), (0x00200010, .SH, ""), (0x00080050, .SH, ""), (0x00200011, .IS, ""),
            (0x00080064, .CS, "WSD"), (0x00080060, .CS, "OT")] {
            baseline.set(text(tag, [value], vr))
        }
        for (tag, value) in [(0x00280010, UInt(2)), (0x00280011, 2), (0x00280002, 1),
                             (0x00280100, 8), (0x00280101, 8), (0x00280102, 7), (0x00280103, 0)] {
            baseline.set(number(tag, value))
        }
        baseline.set(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([1, 2, 3, 4]))))
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("baseline", baseline, .passed),
            ("missing-instance-number", baseline.removing(0x00200013), .failed),
            ("missing-orientation", baseline.removing(0x00200020), .failed),
            ("image-type-valid", baseline.setting(text(0x00080008, ["DERIVED", "SECONDARY", "", "PRIVATE"])), .passed),
            ("image-type-reversed", baseline.setting(text(0x00080008, ["PRIMARY", "ORIGINAL"])), .failed),
            ("orientation-invalid", baseline.setting(text(0x00200020, ["LEFT", "POSTERIOR"])), .failed),
            ("qc-both", baseline.setting(text(0x00280300, ["BOTH"])), .passed),
            ("qc-invalid", baseline.setting(text(0x00280300, ["LOCAL"])), .failed),
            ("burned-invalid", baseline.setting(text(0x00280301, ["BOTH"])), .failed),
            ("lossy-invalid", baseline.setting(text(0x00282110, ["YES"])), .failed),
            ("lut-identity", baseline.setting(text(0x20500020, ["IDENTITY"])), .passed),
            ("lut-contradiction", baseline.setting(text(0x20500020, ["INVERSE"])), .failed),
            ("ratio-count", baseline.setting(text(0x00282112, ["3", "5"], .DS))
                .setting(text(0x00282114, ["ISO_10918_1"])), .failed),
            ("icon-129", baseline.setting(sequence(0x00880200, [icon()])), .passed),
            ("icon-empty", baseline.setting(sequence(0x00880200, [])), .failed),
            ("icon-two", baseline.setting(sequence(0x00880200, [icon(), icon()])), .failed)
        ]
        for (name, dataSet, expected) in cases {
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let meta = try DicomPart10FileMetaParser.parse(bytes)
            let parsed = try DicomEncodedDataSetValidator.validate(Data(bytes.dropFirst(meta.dataSetOffset)))
            XCTAssertEqual(parsed.report[.structure], .passed, name)
            let own = validate(try XCTUnwrap(parsed.dataSet))
            XCTAssertEqual(own[.attributes], expected, name)
            let instance = try DicomInstanceValidator.validate(bytes, imageConditions: .init(
                nonHumanPatient: .unsatisfied, pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied))
            XCTAssertEqual(instance[.attributes], expected == .failed ? .failed : .incomplete, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_GENERAL_IMAGE_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": own[.attributes].rawValue,
                    "instanceAttributes": instance[.attributes].rawValue,
                    "temporallyRelatedSeries": "unsatisfied"], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func validate(_ dataSet: DicomDataSet, source: DicomSRIconImageValidator.PixelDataSource = .omitted) -> DicomValidationReport {
        DicomGeneralImageModule.validate(dataSet, kind: .secondaryCapture, temporallyRelatedSeries: .unsatisfied, iconPixelDataSource: source)
    }

    private func fixture() -> DicomDataSet {
        .init(elements: [text(0x00200013, [""], .IS), text(0x00200020, [""]), text(0x00280004, ["MONOCHROME2"])])
    }

    private func icon() -> DicomDataSet {
        .init(elements: [number(0x00280010, 129), number(0x00280011, 129), number(0x00280002, 1),
            number(0x00280100, 8), number(0x00280101, 8), number(0x00280102, 7), number(0x00280103, 0),
            text(0x00280004, ["MONOCHROME2"]), .init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 1, count: 16642)))])
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ values: [String], _ vr: DicomVR = .CS) -> DicomDataElement { .init(tag: tag, vr: vr, value: .strings(values)) }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement { .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) })) }
}
