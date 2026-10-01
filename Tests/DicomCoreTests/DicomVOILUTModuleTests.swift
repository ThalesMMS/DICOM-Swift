import Foundation
import XCTest
@testable import DicomCore

final class DicomVOILUTModuleTests: XCTestCase {
    func test_originalInstance_rejectsInvalidWindowAndMissingLUTDescriptor() throws {
        for (dataSet, tag) in [
            (fixture().setting(text(0x00281050, ["0"], .DS)).setting(text(0x00281051, ["0"], .DS)), 0x00281051),
            (fixture().setting(text(0x00281050, ["0"], .DS)).setting(text(0x00281051, [".5"], .DS)), 0x00281051),
            (fixture().setting(text(0x00281050, ["0"], .DS)), 0x00281051),
            (fixture().setting(.init(tag: 0x00283010, vr: .SQ, value: .sequence([.init(dataSet: .init())]))), 0x00283002)
        ] {
            let report = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: dataSet))
            XCTAssertTrue(report.diagnostics.contains { $0.severity == .error && $0.path.last == .tag(tag)
                && $0.requirement == (tag == 0x00283002 ? .type1 : .type1C) })
        }
    }

    func test_moduleSelectionAndWindowFunctions_preserveDefinedTermsAndPrecision() {
        XCTAssertFalse(DicomVOILUTModule.applies(to: fixture()))
        for (function, width, expected) in [("LINEAR", ".5", DicomValidationReport.Outcome.failed),
            ("LINEAR", "1", .passed), ("LINEAR_EXACT", ".5", .passed), ("SIGMOID", ".5", .passed),
            ("SIGMOID", "0", .failed), ("CUSTOM", "-1", .incomplete), ("", "1", .incomplete),
            ("SIGMOID", "1E-999", .incomplete)] {
            let dataSet = window(width).setting(text(0x00281056, [function], .CS))
            XCTAssertTrue(DicomVOILUTModule.applies(to: dataSet))
            XCTAssertEqual(DicomVOILUTModule.validate(dataSet)[.attributes], expected)
        }
        XCTAssertEqual(DicomVOILUTModule.validate(window("1").setting(text(0x00280004, ["RGB"], .CS)))[.attributes], .failed)
        XCTAssertEqual(DicomVOILUTModule.validate(window("1").setting(text(0x00281050, ["NaN"], .DS)))[.attributes], .failed)
    }

    func test_tableConstraints_doNotAdoptLegacyTruncationOrPresentationStatePrecision() {
        for (bits, values, expected) in [(16, [UInt(0), 65535], DicomValidationReport.Outcome.passed),
            (16, [0, 1, 2], .failed), (16, [0], .failed), (12, [0, 4095], .failed), (8, [0, 255], .incomplete)] {
            let dataSet = fixture().setting(table(bits: UInt(bits), data: number(0x00283006, values)))
            XCTAssertEqual(DicomVOILUTModule.validate(dataSet)[.attributes], expected)
        }
        let signed = DicomDataElement(tag: 0x00283002, vr: .SS, value: .signedIntegers([2, -10, 16]))
        let sequence = DicomDataElement(tag: 0x00283010, vr: .SQ,
            value: .sequence([.init(dataSet: .init(elements: [signed, number(0x00283006, [0, 65535])]))]))
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(sequence))[.attributes], .failed)
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(sequence).setting(number(0x00280103, [1])))[.attributes], .passed)
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(sequence).removing(0x00280103))[.attributes], .incomplete)
    }

    func test_rescaleContext_doesNotInferDescriptorMismatchFromMalformedDS() {
        for intercept in ["\t-1", String(repeating: " ", count: 16) + "-1", "1E-999"] {
            let dataSet = fixture().setting(table(bits: 16, data: number(0x00283006, [0, 65535])))
                .setting(text(0x00281052, [intercept], .DS)).setting(text(0x00281053, ["1"], .DS))
            let report = DicomVOILUTModule.validate(dataSet)
            XCTAssertEqual(report[.attributes], .incomplete)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .valueUnavailable && $0.path.last == .tag(0x00283002) })
            XCTAssertFalse(report.diagnostics.contains { $0.code == .incompatibleVR })
        }
    }

    func test_OWTables_checkOriginalLengthAndEndianWithoutChangingLegacyReader() {
        let packed = table(bits: 8, data: .init(tag: 0x00283006, vr: .OW, value: .bytes(Data([0, 255]))))
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(packed))[.attributes], .passed)
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(packed), littleEndian: false)[.attributes], .incomplete)
        let legacy = table(bits: 8, data: .init(tag: 0x00283006, vr: .OW, value: .bytes(Data([0, 0, 255, 0]))))
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(legacy))[.attributes], .incomplete)
        let big = table(bits: 16, data: .init(tag: 0x00283006, vr: .OW, value: .bytes(Data([0, 0, 255, 255]))))
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(big), littleEndian: false)[.attributes], .passed)
        let overlong = DicomSequenceItem(dataSet: .init(elements: [number(0x00283002, [2, 0, 16]), number(0x00283006, [0, 1, 2])]))
        XCTAssertTrue(DicomVOILUTValidator.validate(items: [overlong], littleEndian: true).rejected.isEmpty)
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(.init(tag: 0x00283010, vr: .SQ, value: .sequence([overlong]))))[.attributes], .failed)
    }

    func test_limits_stopBeforeLateWindowValuesAndFullSizeLUTAllocation() {
        let widths = Array(repeating: "1", count: 1000) + ["NaN"]
        let limited = DicomVOILUTModule.validate(window("1").setting(text(0x00281051, widths, .DS)), limits: .init(maximumRuleEvaluations: 100))
        XCTAssertEqual(limited[.attributes], .incomplete)
        XCTAssertEqual(limited.diagnostics.last?.code, .evaluationLimitReached)
        let full = DicomDataElement(tag: 0x00283010, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
            number(0x00283002, [0, 0, 16]), number(0x00283006, Array(repeating: 0, count: 65536))]))]))
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(full), limits: .init(maximumRuleEvaluations: 1000))[.attributes], .incomplete)
        XCTAssertEqual(DicomVOILUTModule.validate(fixture().setting(full))[.attributes], .passed)
        let zero = DicomVOILUTModule.validate(window("0"), limits: .init(maximumRuleEvaluations: 0, maximumDiagnostics: 1))
        XCTAssertEqual(zero[.attributes], .incomplete)
        XCTAssertLessThanOrEqual(zero.diagnostics.count, 2)
    }

    func test_originalPart10Corpus_preservesAlternativeWindowsAndTables() throws {
        let table16 = table(bits: 16, data: number(0x00283006, [0, 65535]))
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("linear-threshold", window("1"), .passed), ("linear-fractional", window(".5"), .failed),
            ("zero-width", window("0"), .failed), ("negative-width", window("-1"), .failed),
            ("exact-fractional", window(".5").setting(text(0x00281056, ["LINEAR_EXACT"], .CS)), .passed),
            ("sigmoid-fractional", window(".5").setting(text(0x00281056, ["SIGMOID"], .CS)), .passed),
            ("private-function", window("-1").setting(text(0x00281056, ["CUSTOM"], .CS)), .incomplete),
            ("empty-function", window("1").setting(text(0x00281056, [""], .CS)), .incomplete),
            ("width-underflow", window("1E-999").setting(text(0x00281056, ["SIGMOID"], .CS)), .incomplete),
            ("count-mismatch", window("1").setting(text(0x00281050, ["0", "10"], .DS)), .failed),
            ("missing-width", window("1").removing(0x00281051), .failed),
            ("lut16", fixture().setting(table16), .passed),
            ("lut16-extra", fixture().setting(table(bits: 16, data: number(0x00283006, [0, 1, 2]))), .failed),
            ("lut16-short", fixture().setting(table(bits: 16, data: number(0x00283006, [0]))), .failed),
            ("lut12", fixture().setting(table(bits: 12, data: number(0x00283006, [0, 4095]))), .failed),
            ("lut8-packed", fixture().setting(table(bits: 8, data: .init(tag: 0x00283006, vr: .OW, value: .bytes(Data([0, 255]))))), .passed),
            ("lut8-legacy", fixture().setting(table(bits: 8, data: .init(tag: 0x00283006, vr: .OW, value: .bytes(Data([0, 0, 255, 0]))))), .incomplete),
            ("alternatives", window("1").setting(table16), .passed)
        ]
        for (name, dataSet, expected) in cases {
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let meta = try DicomPart10FileMetaParser.parse(bytes)
            let parsed = try DicomEncodedDataSetValidator.validate(Data(bytes.dropFirst(meta.dataSetOffset)))
            let own = DicomVOILUTModule.validate(try XCTUnwrap(parsed.dataSet))
            XCTAssertEqual(own[.attributes], expected, name)
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertEqual(report[.attributes], expected == .failed ? .failed : .incomplete, name)
            XCTAssertEqual(report[.pixelsAndGeometry], .passed, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), report)
            if let folder = ProcessInfo.processInfo.environment["DICOM_VOI_LUT_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": own[.attributes].rawValue,
                    "instanceAttributes": report[.attributes].rawValue, "geometry": report[.pixelsAndGeometry].rawValue], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func window(_ width: String) -> DicomDataSet {
        fixture().setting(text(0x00281050, ["-.5"], .DS)).setting(text(0x00281051, [width], .DS))
    }
    private func table(bits: UInt, data: DicomDataElement) -> DicomDataElement {
        .init(tag: 0x00283010, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [number(0x00283002, [2, 0, bits]), data]))]))
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
