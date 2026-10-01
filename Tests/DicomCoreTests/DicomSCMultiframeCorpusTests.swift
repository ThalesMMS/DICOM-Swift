import Foundation
import XCTest
@testable import DicomCore

/// Profile-level corpus for the four multi-frame Secondary Capture IODs (A.8.2–A.8.5) on native
/// syntaxes: pixel description constraints, frame pointers and vectors, cine, dimensions, frame
/// extraction, forbidden modules and the unused-high-bit rule of grayscale word images.
final class DicomSCMultiframeCorpusTests: XCTestCase {

    func test_diagnosticBudgetAlreadyFull_doesNotAppendALimitation() throws {
        let dataSet = fixture(.grayscaleWord).setting(.init(tag: 0x00280006, vr: .US, value: .unsignedIntegers([0])))
            .setting(.init(tag: 0x60003000, vr: .OW, value: .bytes(Data([0, 0]))))
        let report = DicomSCMultiframeModules.validate(dataSet, variant: .grayscaleWord,
            encoding: nil, limits: .init(maximumDiagnostics: 1))
        XCTAssertEqual(report.diagnostics.count, 1)
        XCTAssertEqual(report.diagnostics.first?.path, [.tag(0x00280006)])
        XCTAssertEqual(report.diagnostics.first?.code, .conditionalAttributeForbidden)
    }

    private typealias Variant = DicomSCMultiframeModules.Variant

    private enum Expectation {
        case passed
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
        case incomplete(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })

    func test_originalCorpus_qualifiesTheFourVariantsAndRejectsContentConstraintViolations() throws {
        let vectors = DicomDataSet(elements: [pointer([0x00181065, 0x00182005]),
            .init(tag: 0x00181065, vr: .DS, value: .strings(["0", "33", "33"])),
            .init(tag: 0x00182005, vr: .DS, value: .strings(["1", "2", "3"]))])
        let frameGroups = DicomDataSet(elements: [text(0x00080023, "20260101", .DA), text(0x00080033, "120000", .TM),
            text(0x00200013, "1", .IS),
            sequence(0x52009229, [.init(elements: [])]), sequence(0x52009230, [.init(elements: []), .init(elements: []), .init(elements: [])])])
        let dimensions = DicomDataSet(elements: [
            sequence(0x00209221, [.init(elements: [text(0x00209164, "2.25.23219981", .UI)])]),
            sequence(0x00209222, [.init(elements: [text(0x00209164, "2.25.23219981", .UI), pointer([0x00182005], tag: 0x00209165)])])])
        let extraction = DicomDataSet(elements: [sequence(0x00081164, [.init(elements: [text(0x00081167, "2.25.23219982", .UI),
            .init(tag: 0x00081161, vr: .UL, value: .unsignedIntegers([1, 2]))])])])
        let cases: [(String, Variant, DicomDataSet, Expectation)] = [
            ("single-bit", .singleBit, .init(), .passed),
            ("grayscale-byte", .grayscaleByte, .init(), .passed),
            ("grayscale-word", .grayscaleWord, .init(), .passed),
            ("true-color", .trueColor, .init(), .passed),
            ("word-vectors", .grayscaleWord, vectors.removing(0x00181063), .passed),
            ("byte-frame-pointers", .grayscaleByte, .init(elements: [number(0x00286010, 2), number(0x00286020, [1, 3]),
                .init(tag: 0x00286022, vr: .LO, value: .strings(["systole", "diastole"]))]), .passed),
            ("byte-dimension", .grayscaleByte, .init(elements: vectors.removing(0x00181063).elements + dimensions.elements), .passed),
            ("byte-frame-extraction", .grayscaleByte, extraction, .passed),
            ("word-voi-window", .grayscaleWord, .init(elements: [.init(tag: 0x00281050, vr: .DS, value: .strings(["2048"])),
                .init(tag: 0x00281051, vr: .DS, value: .strings(["4096"]))]), .passed),
            ("byte-functional-groups", .grayscaleByte, frameGroups, .incomplete(.moduleRuleUnavailable, [.tag(0x52009229)])),
            ("missing-frame-increment", .grayscaleByte, .init(), .failed(.requiredAttributeMissing, [.tag(0x00280009)])),
            ("pointer-target-missing", .grayscaleByte, .init(elements: [pointer([0x00181065])]),
             .failed(.requiredAttributeMissing, [.tag(0x00181065)])),
            ("vector-length-mismatch", .grayscaleWord, vectors.setting(.init(tag: 0x00182005, vr: .DS, value: .strings(["1", "2"]))),
             .failed(.invalidMultiplicity, [.tag(0x00182005)])),
            ("playback-invalid", .grayscaleByte, .init(elements: [number(0x00181244, 2)]), .failed(.attributeValueNotAllowed, [.tag(0x00181244)])),
            ("single-bit-wrong-allocation", .singleBit, .init(elements: [number(0x00280100, 8)]),
             .failed(.attributeValueNotAllowed, [.tag(0x00280100)])),
            ("byte-rescale-slope", .grayscaleByte, .init(elements: [.init(tag: 0x00281053, vr: .DS, value: .strings(["2"]))]),
             .failed(.attributeValueContradiction, [.tag(0x00281053)])),
            ("word-high-bit", .grayscaleWord, .init(elements: [number(0x00280102, 10)]),
             .failed(.attributeValueContradiction, [.tag(0x00280102)])),
            ("word-unused-high-bits", .grayscaleWord, .init(), .failed(.pixelMetadataContradiction, [.tag(0x7FE00010)])),
            ("true-color-planar", .trueColor, .init(elements: [number(0x00280006, 1)]), .failed(.attributeValueNotAllowed, [.tag(0x00280006)])),
            ("true-color-ybr-native", .trueColor, .init(elements: [text(0x00280004, "YBR_FULL", .CS)]),
             .failed(.attributeValueNotAllowed, [.tag(0x00280004)])),
            ("single-bit-voi-forbidden", .singleBit, .init(elements: [.init(tag: 0x00281050, vr: .DS, value: .strings(["1"])),
                .init(tag: 0x00281051, vr: .DS, value: .strings(["2"]))]), .failed(.conditionalAttributeForbidden, [.tag(0x00281050)])),
            ("byte-overlay-forbidden", .grayscaleByte, .init(elements: [number(0x60000010, 2), number(0x60000011, 2),
                text(0x60000040, "G", .CS), .init(tag: 0x60000050, vr: .SS, value: .signedIntegers([1, 1])), number(0x60000100, 1),
                number(0x60000102, 0), .init(tag: 0x60003000, vr: .OW, value: .bytes(Data([0x0F, 0])))]),
             .failed(.conditionalAttributeForbidden, [.tag(0x60000010)])),
            ("representative-frame-out-of-range", .grayscaleByte, .init(elements: [number(0x00286010, 5)]),
             .failed(.attributeValueNotAllowed, [.tag(0x00286010)])),
            ("foi-description-count", .grayscaleByte, .init(elements: [number(0x00286020, [1, 2]),
                .init(tag: 0x00286022, vr: .LO, value: .strings(["systole"]))]), .failed(.attributeValueContradiction, [.tag(0x00286022)])),
            ("dimension-index-missing", .grayscaleByte, .init(elements: [dimensions.elements[0]]),
             .failed(.requiredAttributeMissing, [.tag(0x00209222)])),
            ("frame-extraction-two-lists", .grayscaleByte, .init(elements: [sequence(0x00081164, [.init(elements: [
                text(0x00081167, "2.25.23219982", .UI), .init(tag: 0x00081161, vr: .UL, value: .unsignedIntegers([1])),
                .init(tag: 0x00081162, vr: .UL, value: .unsignedIntegers([1, 1, 1]))])])]),
             .failed(.exclusiveAttributeChoiceInvalid, [.tag(0x00081164), .item(0)]))
        ]
        for (name, variant, attributes, expectation) in cases {
            var instance = fixture(variant, highBitsSet: name == "word-unused-high-bits")
            if name == "missing-frame-increment" { instance = instance.removing(0x00280009).removing(0x00181063) }
            for element in attributes.elements { instance.set(element) }
            let bytes = try DicomDataSetWriter.part10Data(from: instance, options: .init(
                mediaStorageSOPClassUID: variant.sopClassUID, mediaStorageSOPInstanceUID: "2.25.23219990"))
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            let outcome = report.outcome(requiring: requiredLayers)
            switch expectation {
            case .passed:
                XCTAssertEqual(outcome, .passed, "\(name): \(report.diagnostics)")
            case .failed(let code, let path):
                XCTAssertEqual(outcome, .failed, name)
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path && $0.severity == .error }, "\(name): \(report.diagnostics)")
            case .incomplete(let code, let path):
                XCTAssertEqual(outcome, .incomplete, "\(name): \(report.diagnostics)")
                XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, name)
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path }, "\(name): \(report.diagnostics)")
            }
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable && $0.path == [.tag(0x00080016)] }, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, imageConditions: facts), report, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_SC_MULTIFRAME_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue, "variant": variant.sopClassUID,
                    "exit": outcome == .passed ? 0 : outcome == .failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_unusedHighBits_andPointerResolution_areEvaluatedAgainstOriginalValues() {
        XCTAssertEqual(DicomSCMultiframeModules.unusedHighBitsAreZero(Data([0xFF, 0x0F, 0x00, 0x00]), bitsStored: 12, littleEndian: true), true)
        XCTAssertEqual(DicomSCMultiframeModules.unusedHighBitsAreZero(Data([0xFF, 0x1F]), bitsStored: 12, littleEndian: true), false)
        XCTAssertEqual(DicomSCMultiframeModules.unusedHighBitsAreZero(Data([0x1F, 0xFF]), bitsStored: 12, littleEndian: false), false)
        XCTAssertEqual(DicomSCMultiframeModules.unusedHighBitsAreZero(Data([0xFF, 0xFF]), bitsStored: 16, littleEndian: true), true)
        XCTAssertNil(DicomSCMultiframeModules.unusedHighBitsAreZero(Data([0xFF]), bitsStored: 12, littleEndian: true))
        XCTAssertNil(DicomSCMultiframeModules.unusedHighBitsAreZero(Data([0xFF]), bitsStored: 16, littleEndian: true))
        let word = fixture(.grayscaleWord)
        XCTAssertEqual(DicomSCMultiframeModules.validate(word, variant: .grayscaleWord, encoding: nil)[.attributes], .passed)
        let opaque = word.setting(.init(tag: 0x00280009, vr: .UN, value: .bytes(Data([1, 2, 3, 4]))))
        XCTAssertEqual(DicomSCMultiframeModules.validate(opaque, variant: .grayscaleWord, encoding: nil)[.attributes], .incomplete)
        // Without the syntax family, the True Color photometric constraint cannot be settled.
        XCTAssertEqual(DicomSCMultiframeModules.validate(fixture(.trueColor), variant: .trueColor, encoding: nil)[.attributes], .incomplete)
        let limited = DicomSCMultiframeModules.validate(word, variant: .grayscaleWord, encoding: nil, limits: .init(maximumRuleEvaluations: 1))
        XCTAssertTrue(limited.diagnostics.contains { $0.code == .evaluationLimitReached })
    }

    private func fixture(_ variant: Variant, highBitsSet: Bool = false) -> DicomDataSet {
        let (rows, columns, samples, allocated, stored, photometric): (UInt, UInt, UInt, UInt, UInt, String) = switch variant {
        case .singleBit: (4, 4, 1, 1, 1, "MONOCHROME2")
        case .grayscaleByte: (2, 2, 1, 8, 8, "MONOCHROME2")
        case .grayscaleWord: (2, 2, 1, 16, 12, "MONOCHROME2")
        case .trueColor: (2, 2, 3, 8, 8, "RGB")
        }
        let frames: UInt = 3
        let frameBytes = Int(rows * columns * samples * allocated / 8)
        var pixels = Data(repeating: allocated == 1 ? 0xA5 : 1, count: frameBytes * Int(frames))
        if variant == .grayscaleWord {
            pixels = Data((0..<(frameBytes * Int(frames) / 2)).flatMap { _ in highBitsSet ? [0x00, 0xF0] : [0xFF, 0x0F] })
        }
        var elements: [DicomDataElement] = [
            text(0x00080016, variant.sopClassUID, .UI), text(0x00080018, "2.25.23219990", .UI),
            text(0x00100010, "", .PN), text(0x00100020, "", .LO), text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x00080020, "", .DA), text(0x00080030, "", .TM), text(0x00080090, "", .PN), text(0x00080050, "", .SH),
            text(0x00200010, "", .SH), text(0x00200011, "", .IS), text(0x00200013, "", .IS), text(0x00200020, "", .CS),
            text(0x0020000D, "2.25.23219991", .UI), text(0x0020000E, "2.25.23219992", .UI), text(0x00080064, "WSD", .CS),
            text(0x00080060, "OT", .CS),
            text(0x00080008, "DERIVED\\SECONDARY", .CS), text(0x00280301, "NO", .CS),
            .init(tag: 0x00280008, vr: .IS, value: .strings([String(frames)])), pointer([0x00181063]),
            .init(tag: 0x00181063, vr: .DS, value: .strings(["33.3"])),
            number(0x00280002, samples), text(0x00280004, photometric, .CS), number(0x00280010, rows), number(0x00280011, columns),
            number(0x00280100, allocated), number(0x00280101, stored), number(0x00280102, stored - 1), number(0x00280103, 0),
            .init(tag: 0x7FE00010, vr: allocated == 16 ? .OW : .OB, value: .bytes(pixels))
        ]
        if variant == .trueColor { elements.append(number(0x00280006, 0)) }
        if variant == .grayscaleByte || variant == .grayscaleWord {
            elements += [text(0x20500020, "IDENTITY", .CS), .init(tag: 0x00281052, vr: .DS, value: .strings(["0"])),
                .init(tag: 0x00281053, vr: .DS, value: .strings(["1"])), text(0x00281054, "US", .LO)]
        }
        return .init(elements: elements)
    }

    private func pointer(_ tags: [UInt], tag: Int = 0x00280009) -> DicomDataElement {
        .init(tag: tag, vr: .AT, value: .unsignedIntegers(tags))
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func number(_ tag: Int, _ values: [UInt]) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers(values)) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings(value.components(separatedBy: "\\")))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
