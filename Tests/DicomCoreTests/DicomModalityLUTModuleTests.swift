import Foundation
import XCTest
@testable import DicomCore

final class DicomModalityLUTModuleTests: XCTestCase {
    func test_originalSC_rejectsMissingRescaleFieldsAndConflictingTransforms() throws {
        let rescale = fixture().setting(text(0x00281052, ["0"], .DS))
        for (source, tag) in [(rescale, 0x00281053),
            (rescale.setting(text(0x00281053, ["1"], .DS)), 0x00281054),
            (rescale.setting(.init(tag: 0x00283000, vr: .SQ, value: .sequence([.init(dataSet: .init())]))), 0x00283000)] {
            let report = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: source))
            XCTAssertTrue(report.diagnostics.contains { $0.severity == .error && $0.path.last == .tag(tag) })
        }
    }

    func test_corpus_composesOriginalSCAndPreservesTransformAlternatives() throws {
        let rescale = fixture().setting(text(0x00281052, ["-1"], .DS))
            .setting(text(0x00281053, [".5"], .DS)).setting(text(0x00281054, ["US"], .LO))
        let item = DicomDataSet(elements: [number(0x00283002, [2, 0, 16]), number(0x00283006, [0, 65535]),
            text(0x00283004, ["US"], .LO)])
        func table(_ item: DicomDataSet) -> DicomDataSet {
            fixture().setting(.init(tag: 0x00283000, vr: .SQ, value: .sequence([.init(dataSet: item)])))
        }
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("rescale", rescale, .passed), ("zero-slope", rescale.setting(text(0x00281053, ["0"], .DS)), .passed),
            ("private-units", rescale.setting(text(0x00281054, ["CUSTOM"], .LO)), .passed),
            ("missing-slope", rescale.removing(0x00281053), .failed), ("missing-type", rescale.removing(0x00281054), .failed),
            ("missing-intercept", rescale.removing(0x00281052), .failed),
            ("underflow", rescale.setting(text(0x00281053, ["1E-999"], .DS)), .incomplete),
            ("lut16", table(item), .passed), ("missing-lut-type", table(item.removing(0x00283004)), .failed),
            ("short-data", table(item.setting(number(0x00283006, [0]))), .failed),
            ("extra-data", table(item.setting(number(0x00283006, [0, 1, 2]))), .failed),
            ("lut12", table(item.setting(number(0x00283002, [2, 0, 12]))), .failed),
            ("both", rescale.setting(try XCTUnwrap(table(item)[0x00283000])), .failed),
            ("two-items", fixture().setting(.init(tag: 0x00283000, vr: .SQ,
                value: .sequence([.init(dataSet: item), .init(dataSet: item)]))), .failed)
        ]
        for (name, source, expected) in cases {
            let bytes = try DicomDataSetWriter.part10Data(from: source)
            let meta = try DicomPart10FileMetaParser.parse(bytes)
            let parsed = try DicomEncodedDataSetValidator.validate(Data(bytes.dropFirst(meta.dataSetOffset)))
            let own = DicomModalityLUTModule.validate(try XCTUnwrap(parsed.dataSet))
            XCTAssertEqual(own[.attributes], expected, name)
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertEqual(report[.attributes], expected == .failed ? .failed : .incomplete, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), report)
            if let folder = ProcessInfo.processInfo.environment["DICOM_MODALITY_LUT_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": expected.rawValue,
                    "instanceAttributes": report[.attributes].rawValue], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_tableContextAndLimits_preserveUnknownAndBoundWork() {
        XCTAssertFalse(DicomModalityLUTModule.applies(to: fixture()))
        let item = DicomDataSet(elements: [.init(tag: 0x00283002, vr: .SS, value: .signedIntegers([2, -1, 16])),
            number(0x00283006, [0, 65535]), text(0x00283004, ["US"], .LO)])
        let source = fixture().setting(.init(tag: 0x00283000, vr: .SQ, value: .sequence([.init(dataSet: item)])))
        XCTAssertEqual(DicomModalityLUTModule.validate(source)[.attributes], .failed)
        XCTAssertEqual(DicomModalityLUTModule.validate(source.setting(number(0x00280103, [1])))[.attributes], .passed)
        XCTAssertEqual(DicomModalityLUTModule.validate(source.removing(0x00280103))[.attributes], .incomplete)
        for limits in [DicomAttributeValidator.Limits(maximumRuleEvaluations: 0), .init(maximumDepth: 0),
                       .init(maximumRuleEvaluations: 6)] {
            let report = DicomModalityLUTModule.validate(source, limits: limits)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
        }
    }

    func test_zeroRescaleAndVOI_composeConstantSignedAndUnsignedOutput() throws {
        for (intercept, signed) in [("-1", true), ("0", false), ("1", false)] {
            let descriptor = DicomDataElement(tag: 0x00283002, vr: signed ? .SS : .US,
                value: signed ? .signedIntegers([2, -1, 16]) : .unsignedIntegers([2, 0, 16]))
            let source = fixture().setting(text(0x00281052, [intercept], .DS))
                .setting(text(0x00281053, ["0"], .DS)).setting(text(0x00281054, ["US"], .LO))
                .setting(.init(tag: 0x00283010, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
                    descriptor, number(0x00283006, [0, 65535])]))])))
            XCTAssertEqual(DicomModalityLUTModule.validate(source)[.attributes], .passed)
            XCTAssertEqual(DicomVOILUTModule.validate(source)[.attributes], .passed)
            for syntax in [DicomTransferSyntax.implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian] {
                let bytes = try DicomDataSetWriter.part10Data(from: source, options: .init(transferSyntax: syntax))
                let report = try DicomInstanceValidator.validate(bytes)
                XCTAssertEqual(report[.attributes], .incomplete)
                XCTAssertFalse(report.diagnostics.contains { $0.path.contains(.tag(0x00283002)) })
                XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), report)
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
