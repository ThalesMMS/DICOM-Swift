import Foundation
import XCTest
@testable import DicomCore

final class DicomPixelPaddingModuleTests: XCTestCase {
    func test_originalPadding_rejectsStoredRangeAndPolarityViolations() throws {
        for (name, dataSet, tag) in [
            ("overflow", fixture().setting(number(0x00280120, 256)), 0x00280120),
            ("reversed", fixture().setting(number(0x00280120, 10)).setting(number(0x00280121, 0)), 0x00280121),
            ("missing-value", fixture().setting(number(0x00280121, 10)), 0x00280120)
        ] {
            let report = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: dataSet))
            XCTAssertTrue(report.diagnostics.contains { $0.severity == .error && $0.path == [.tag(tag)] }, name)
        }
    }

    func test_SCOptionalEquipment_requiresItsType2ManufacturerWhenSupplied() {
        for tag in [0x00280120, 0x00280121, 0x00080080, 0x00181000] {
            let dataSet = fixture().setting(tag == 0x00280120 || tag == 0x00280121 ? number(tag, 0) : text(tag, "SYNTHETIC", .LO))
            let report = DicomCompositeImageModules.validate(dataSet, kind: .secondaryCapture)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x00080070)] })
            let supplied = DicomCompositeImageModules.validate(dataSet.setting(text(0x00080070, "", .LO)), kind: .secondaryCapture)
            XCTAssertFalse(supplied.diagnostics.contains { $0.severity == .error && $0.path == [.tag(0x00080070)] })
        }
    }

    func test_signedAndUnsignedDomains_useStoredValuesBeforeRescale() {
        for (bits, signed, allowed, rejected) in [(8, false, 255, 256), (8, true, -128, -129),
            (12, true, 2047, 2048), (16, true, -32768, -32769), (1, false, 1, 2)] {
            let base = fixture().setting(number(0x00280100, bits == 1 ? 1 : 16))
                .setting(number(0x00280101, UInt(bits))).setting(number(0x00280102, UInt(bits - 1)))
                .setting(number(0x00280103, signed ? 1 : 0)).setting(text(0x00281052, "1000", .DS))
            XCTAssertEqual(validate(base.setting(padding(allowed, signed: signed)))[.attributes], .passed)
            XCTAssertEqual(validate(base.setting(padding(rejected, signed: signed)))[.attributes], .failed)
        }
        let wide = fixture().setting(number(0x00280100, 64)).setting(number(0x00280101, 64)).setting(number(0x00280102, 63))
        XCTAssertEqual(validate(wide.setting(number(0x00280120, 65535)))[.attributes], .passed)
    }

    func test_polarity_allowsEqualEndpointsAndPaletteIndices() {
        for photo in ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR"] {
            let base = fixture().setting(text(0x00280004, photo))
            let first: UInt = photo == "MONOCHROME1" ? 10 : 0
            let last: UInt = photo == "MONOCHROME1" ? 0 : 10
            XCTAssertEqual(validate(base.setting(number(0x00280120, first)).setting(number(0x00280121, last)))[.attributes], .passed)
            XCTAssertEqual(validate(base.setting(number(0x00280120, last)).setting(number(0x00280121, first)))[.attributes], .failed)
            XCTAssertEqual(validate(base.setting(number(0x00280120, 0)).setting(number(0x00280121, 0)))[.attributes], .passed)
        }
    }

    func test_contextPresenceAndBudgets_preserveUnavailableEvidence() {
        let base = fixture().setting(number(0x00280120, 0))
        XCTAssertEqual(DicomPixelPaddingModule.validate(base)[.attributes], .incomplete)
        XCTAssertEqual(DicomPixelPaddingModule.validate(base, hasPixelData: .unsatisfied)[.attributes], .failed)
        let provider = base.removing(0x7FE00010).setting(text(0x00287FE0, "https://example.invalid/pixels", .UR))
        XCTAssertEqual(DicomPixelPaddingModule.validate(provider, hasPixelData: .unsatisfied)[.attributes], .passed)
        for tag in [0x00280100, 0x00280101, 0x00280102, 0x00280103, 0x00280002, 0x00280004] {
            XCTAssertEqual(validate(base.removing(tag))[.attributes], .incomplete)
        }
        XCTAssertEqual(validate(base.setting(text(0x00280004, "RGB")).setting(number(0x00280002, 3)))[.attributes], .failed)
        XCTAssertEqual(validate(base.setting(.init(tag: 0x00280120, vr: .UN, value: .bytes(Data([0])))))[.attributes], .incomplete)
        XCTAssertEqual(validate(base.setting(.init(tag: 0x00280120, vr: .US, value: .empty)))[.attributes], .passed)
        let emptyRequired = base.setting(.init(tag: 0x00280120, vr: .US, value: .empty)).setting(number(0x00280121, 0))
        XCTAssertEqual(validate(emptyRequired)[.attributes], .failed)
        for maximum in [0, 1, 3] {
            let report = DicomPixelPaddingModule.validate(base, hasPixelData: .satisfied,
                limits: .init(maximumRuleEvaluations: maximum, maximumDiagnostics: 1))
            XCTAssertEqual(report[.attributes], .incomplete)
            XCTAssertLessThanOrEqual(report.diagnostics.count, 2)
        }
    }

    func test_originalPixelHeader_doesNotUseAnIconAsRootEvidence() throws {
        let icon = DicomDataElement(tag: 0x00880200, vr: .SQ, value: .sequence([.init(dataSet: fixture())]))
        let dataSet = fixture().removing(0x7FE00010).setting(number(0x00280120, 0)).setting(icon)
        let report = try DicomInstanceValidator.validate(DicomDataSetWriter.part10Data(from: dataSet))
        XCTAssertTrue(report.diagnostics.contains { $0.severity == .error && $0.path == [.tag(0x00280120)] })
    }

    func test_originalPart10Corpus_composesPaddingWithoutChangingPixels() throws {
        var baseline = fixture()
        for (tag, vr, value) in [(0x0020000D, DicomVR.UI, "2.25.23213502"), (0x0020000E, .UI, "2.25.23213503"),
            (0x00100010, .PN, ""), (0x00100020, .LO, ""), (0x00100030, .DA, ""), (0x00100040, .CS, ""),
            (0x00080020, .DA, ""), (0x00080030, .TM, ""), (0x00080090, .PN, ""), (0x00200010, .SH, ""),
            (0x00080050, .SH, ""), (0x00200011, .IS, ""), (0x00200013, .IS, ""), (0x00200020, .CS, ""),
            (0x00080064, .CS, "WSD"), (0x00080060, .CS, "OT"), (0x00080070, .LO, "")] { baseline.set(text(tag, value, vr)) }
        let signed = baseline.setting(number(0x00280103, 1))
        let mono1 = baseline.setting(text(0x00280004, "MONOCHROME1"))
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("baseline", baseline, .passed),
            ("single", baseline.setting(number(0x00280120, 0)), .passed),
            ("range", baseline.setting(number(0x00280120, 0)).setting(number(0x00280121, 10)), .passed),
            ("overflow", baseline.setting(number(0x00280120, 256)), .failed),
            ("range-overflow", baseline.setting(number(0x00280120, 0)).setting(number(0x00280121, 256)), .failed),
            ("reversed", baseline.setting(number(0x00280120, 10)).setting(number(0x00280121, 0)), .failed),
            ("missing-value", baseline.setting(number(0x00280121, 10)), .failed),
            ("empty-value", baseline.setting(.init(tag: 0x00280120, vr: .US, value: .empty)).setting(number(0x00280121, 10)), .failed),
            ("mono1-range", mono1.setting(number(0x00280120, 255)).setting(number(0x00280121, 250)), .passed),
            ("mono1-reversed", mono1.setting(number(0x00280120, 250)).setting(number(0x00280121, 255)), .failed),
            ("signed", signed.setting(padding(-128, signed: true)), .passed),
            ("signed-underflow", signed.setting(padding(-129, signed: true)), .failed)
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
            if let folder = ProcessInfo.processInfo.environment["DICOM_PIXEL_PADDING_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["attributes": own[.attributes].rawValue,
                    "instanceAttributes": instance[.attributes].rawValue, "instanceGeometry": instance[.pixelsAndGeometry].rawValue], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    private func validate(_ dataSet: DicomDataSet) -> DicomValidationReport {
        DicomPixelPaddingModule.validate(dataSet, hasPixelData: .satisfied)
    }
    private func padding(_ value: Int, signed: Bool) -> DicomDataElement {
        signed ? .init(tag: 0x00280120, vr: .SS, value: .signedIntegers([value])) : number(0x00280120, UInt(value))
    }

    private func fixture() -> DicomDataSet {
        .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.7", .UI), text(0x00080018, "2.25.23213501", .UI),
            text(0x00280004, "MONOCHROME2"), number(0x00280010, 2), number(0x00280011, 2), number(0x00280002, 1),
            number(0x00280100, 8), number(0x00280101, 8), number(0x00280102, 7), number(0x00280103, 0),
            .init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data(repeating: 1, count: 4)))])
    }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR = .CS) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
}
