import Foundation
import XCTest
@testable import DicomData

final class DicomSRIconImageValidatorTests: XCTestCase {
    func test_nativeMonochromeAndPaletteIcons_validateMetadataAndEncodedLength() {
        for icon in [mono(), palette()] {
            let report = DicomSRIconImageValidator.validate(icon, pixelDataSource: .native)
            XCTAssertEqual(report.outcome(requiring: [.attributes, .pixelsAndGeometry]), .passed)
            XCTAssertEqual(report[.codestream], .notEvaluated)
            XCTAssertEqual(report[.references], .notEvaluated)
        }
    }

    func test_oneBitAndOddPixelCounts_requireOnlyFinalEvenValuePadding() {
        let bitIcon = mono().setting(number(0x00280010, 1)).setting(number(0x00280011, 9))
            .setting(number(0x00280100, 1)).setting(number(0x00280101, 1)).setting(number(0x00280102, 0))
            .setting(bytes(0x7FE00010, 2))
        let oddIcon = mono().setting(number(0x00280010, 1)).setting(number(0x00280011, 3))
        for icon in [bitIcon, oddIcon] {
            XCTAssertEqual(DicomSRIconImageValidator.validate(icon, pixelDataSource: .native)[.pixelsAndGeometry], .passed)
            let truncated = icon.setting(bytes(0x7FE00010, 1))
            XCTAssertTrue(DicomSRIconImageValidator.validate(truncated, pixelDataSource: .native).diagnostics.contains {
                $0.code == .pixelDataLengthMismatch && $0.path == [.tag(0x7FE00010)]
            })
        }
    }

    func test_iconDimensions_rejectZeroAndMoreThan128WithoutOverflow() {
        for tag in [0x00280010, 0x00280011] {
            for size: UInt in [0, 129, UInt.max] {
                let report = DicomSRIconImageValidator.validate(mono().setting(number(tag, size)), pixelDataSource: .native)
                XCTAssertNotEqual(report.outcome(requiring: [.attributes, .pixelsAndGeometry]), .passed)
            }
        }
        let boundary = mono().setting(number(0x00280010, 128)).setting(number(0x00280011, 128))
            .setting(bytes(0x7FE00010, 16384))
        XCTAssertEqual(DicomSRIconImageValidator.validate(boundary, pixelDataSource: .native)[.pixelsAndGeometry], .passed)
    }

    func test_iconSpecificRepresentation_forbidsColorPlanesSignedPixelsAndAspectRatio() {
        let invalid: [DicomDataElement] = [number(0x00280002, 3), text(0x00280004, "RGB"), number(0x00280100, 16),
            number(0x00280101, 4), number(0x00280102, 6), number(0x00280103, 1), number(0x00280006, 0),
            .init(tag: 0x00280034, vr: .IS, value: .strings(["1", "1"]))]
        for element in invalid {
            XCTAssertEqual(DicomSRIconImageValidator.validate(mono().setting(element), pixelDataSource: .native)[.attributes], .failed)
        }
        let tooManyStored = mono().setting(number(0x00280100, 1))
        XCTAssertTrue(DicomSRIconImageValidator.validate(tooManyStored, pixelDataSource: .native).diagnostics.contains {
            $0.code == .attributeValueContradiction && $0.path == [.tag(0x00280101)]
        })
    }

    func test_paletteDescriptorsAndData_validateChannelsAndZeroMeans65536Entries() {
        let baseline = palette()
        for channel in 1...3 {
            let short = baseline.setting(bytes(0x00281200 + channel, 4, vr: .OW))
            XCTAssertTrue(DicomSRIconImageValidator.validate(short, pixelDataSource: .native).diagnostics.contains {
                $0.code == .pixelDataLengthMismatch && $0.path == [.tag(0x00281200 + channel)]
            })
        }
        let inconsistent = baseline.setting(descriptor(0x00281102, [2, 1, 8]))
        XCTAssertTrue(DicomSRIconImageValidator.validate(inconsistent, pixelDataSource: .native).diagnostics.contains {
            $0.code == .pixelMetadataContradiction && $0.path == [.tag(0x00281102)]
        })
        let badDepth = baseline.setting(descriptor(0x00281101, [2, 0, 12]))
        XCTAssertEqual(DicomSRIconImageValidator.validate(badDepth, pixelDataSource: .native)[.pixelsAndGeometry], .failed)
        var large = baseline
        for channel in 1...3 {
            large = large.setting(descriptor(0x00281100 + channel, [0, 0, 16]))
                .setting(bytes(0x00281200 + channel, 131072, vr: .OW))
        }
        XCTAssertEqual(DicomSRIconImageValidator.validate(large, pixelDataSource: .native)[.pixelsAndGeometry], .passed)
        XCTAssertEqual(DicomSRIconImageValidator.validate(baseline.removing(0x00281202), pixelDataSource: .native)[.attributes], .failed)
    }

    func test_absentOmittedOpaqueAndEncapsulatedPixels_haveDistinctEvidence() {
        let missing = mono().removing(0x7FE00010)
        let absent = DicomSRIconImageValidator.validate(missing, pixelDataSource: .native)
        XCTAssertTrue(absent.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(0x7FE00010)] })
        let omitted = DicomSRIconImageValidator.validate(missing, pixelDataSource: .omitted)
        XCTAssertEqual(omitted[.attributes], .passed)
        XCTAssertEqual(omitted[.pixelsAndGeometry], .incomplete)
        XCTAssertFalse(omitted.diagnostics.contains { $0.code == .requiredAttributeMissing })
        let opaque = DicomSRIconImageValidator.validate(mono().setting(bytes(0x7FE00010, 4, vr: .UN)), pixelDataSource: .native)
        XCTAssertEqual(opaque.outcome(requiring: [.attributes, .pixelsAndGeometry]), .incomplete)
        let compressed = DicomSRIconImageValidator.validate(mono(), pixelDataSource: .encapsulated)
        XCTAssertEqual(compressed[.pixelsAndGeometry], .incomplete)
        XCTAssertFalse(compressed.diagnostics.contains { $0.code == .pixelDataLengthMismatch })
    }

    func test_omittedParsedPixels_doNotBecomeFalselyMissingAfterWireValidation() throws {
        let wire = try DicomDataSetWriter.dataSetData(from: mono(), purpose: .instance)
        let parsed = try DicomEncodedDataSetValidator.validate(wire)
        XCTAssertEqual(parsed.report[.structure], .passed)
        XCTAssertTrue(parsed.report.diagnostics.contains { $0.code == .valueUnavailable && $0.path == [.tag(0x7FE00010)] })
        let report = DicomSRIconImageValidator.validate(try XCTUnwrap(parsed.dataSet), pixelDataSource: .omitted)
        XCTAssertEqual(report.outcome(requiring: [.attributes, .pixelsAndGeometry]), .incomplete)
        XCTAssertFalse(report.diagnostics.contains { $0.code == .requiredAttributeMissing })
    }

    func test_budgetAndUnsupportedColorSemantics_cannotProduceCompleteSuccess() {
        for maximum in [0, 1, 10, 42] {
            let report = DicomSRIconImageValidator.validate(palette(), pixelDataSource: .native,
                limits: .init(maximumRuleEvaluations: maximum, maximumDiagnostics: 2))
            XCTAssertNotEqual(report.outcome(requiring: [.attributes, .pixelsAndGeometry]), .passed)
            XCTAssertLessThanOrEqual(report.diagnostics.count, 4)
        }
        let colorProfile = palette().setting(bytes(0x00282000, 4))
        XCTAssertEqual(DicomSRIconImageValidator.validate(colorProfile, pixelDataSource: .native)[.pixelsAndGeometry], .incomplete)
    }

    private func mono() -> DicomDataSet {
        .init(elements: [number(0x00280002, 1), text(0x00280004, "MONOCHROME2"), number(0x00280010, 2),
            number(0x00280011, 2), number(0x00280100, 8), number(0x00280101, 8), number(0x00280102, 7),
            number(0x00280103, 0), bytes(0x7FE00010, 4)])
    }

    private func palette() -> DicomDataSet {
        var result = mono().setting(text(0x00280004, "PALETTE COLOR"))
        for channel in 1...3 {
            result = result.setting(descriptor(0x00281100 + channel, [2, 0, 8]))
                .setting(bytes(0x00281200 + channel, 2, vr: .OW))
        }
        return result
    }

    private func descriptor(_ tag: Int, _ values: [UInt]) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers(values)) }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { descriptor(tag, [value]) }
    private func text(_ tag: Int, _ value: String) -> DicomDataElement { .init(tag: tag, vr: .CS, value: .strings([value])) }
    private func bytes(_ tag: Int, _ count: Int, vr: DicomVR = .OB) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .bytes(Data(repeating: 0, count: count)))
    }
}
