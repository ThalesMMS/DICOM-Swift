import Foundation
import XCTest
@testable import DicomCore

final class DicomOverlayPlaneModuleTests: XCTestCase {

    func test_diagnosticBudget_isBoundedAcrossGroupsAndAttributeEvaluation() {
        var source = overlayDataSet().removing(0x60000010)
        for element in overlayDataSet().elements {
            source.set(.init(tag: 0x60020000 | (element.tag & 0xFFFF), vr: element.vr, value: element.value))
        }
        source = source.removing(0x60020011)
        for maximum in 1...2 {
            for evaluations in [12, 100] {
                let report = DicomOverlayPlaneModule.validate(source, limits: .init(
                    maximumRuleEvaluations: evaluations, maximumDiagnostics: maximum))
                XCTAssertLessThanOrEqual(report.diagnostics.count, maximum, "\(report.diagnostics)")
                XCTAssertFalse(report.diagnostics.isEmpty)
            }
        }
    }

    func test_originalCorpus_checksCurrentOverlayRequirementsAndOriginalLength() throws {
        let overlay = overlayDataSet()
        let cases: [(String, DicomDataSet, DicomValidationReport.Code?)] = [
            ("valid", overlay, nil),
            ("missing-origin", overlay.removing(0x60000050), .requiredAttributeMissing),
            ("zero-rows", overlay.setting(number(0x60000010, 0)), .attributeValueNotAllowed),
            ("invalid-type", overlay.setting(.init(tag: 0x60000040, vr: .CS, value: .strings(["X"]))), .attributeValueNotAllowed),
            ("retired-allocation", overlay.setting(number(0x60000100, 16)), .attributeValueNotAllowed),
            ("retired-bit-position", overlay.setting(number(0x60000102, 15)), .attributeValueNotAllowed),
            ("missing-data", overlay.removing(0x60003000), .requiredAttributeMissing),
            ("empty-data", overlay.setting(payload(Data())), .requiredValueEmpty),
            ("short-data", overlay.setting(number(0x60000010, 5)).setting(number(0x60000011, 5)), .pixelDataLengthMismatch),
            ("excess-data", overlay.setting(payload(Data([0x55, 1, 0, 0]))), .pixelDataLengthMismatch)
        ]
        for (name, attributes, expected) in cases {
            var source = try fixture()
            for element in attributes.elements { source.set(element) }
            let bytes = try DicomDataSetWriter.part10Data(from: source)
            let report = try DicomInstanceValidator.validate(bytes)
            if let expected {
                XCTAssertTrue(report.diagnostics.contains { $0.code == expected }, "\(name): \(report.diagnostics)")
            } else {
                XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, name)
                let plane = try XCTUnwrap(DCMDecoder(data: bytes).overlayPlanes().first)
                XCTAssertEqual(Array(plane.mask), [1, 0, 1, 0, 1, 0, 1, 0, 1])
                XCTAssertEqual(plane.originRow, -1)
                XCTAssertEqual(plane.originColumn, -2)
            }
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes), report, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_SC_OVERLAY_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONEncoder().encode(report).write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_multipleGroups_shareBudgetsAndDoNotAssumeMissingPayloadOrFrameContext() {
        var source = overlayDataSet()
        for element in overlayDataSet().elements {
            source.set(.init(tag: 0x601E0000 | (element.tag & 0xFFFF), vr: element.vr, value: element.value))
        }
        source.set(.init(tag: 0x601E3000, vr: .OW, value: .bytes(Data([0, 0, 0, 0]))))
        let report = DicomOverlayPlaneModule.validate(source)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .pixelDataLengthMismatch && $0.path == [.tag(0x601E3000)]
        })
        for limits in [DicomAttributeValidator.Limits(maximumRuleEvaluations: 1), .init(maximumDiagnostics: 1)] {
            let invalid = source.removing(0x60000010).removing(0x60000011)
            let limited = DicomOverlayPlaneModule.validate(invalid, limits: limits)
            XCTAssertTrue(limited.diagnostics.contains { $0.code == .evaluationLimitReached })
        }
        let frames = overlayDataSet().setting(.init(tag: 0x60000015, vr: .IS, value: .strings(["2"])))
        XCTAssertEqual(DicomOverlayPlaneModule.validate(frames)[.pixelsAndGeometry], .incomplete)
        let statistics = overlayDataSet().setting(.init(tag: 0x60001302, vr: .DS, value: .strings(["1"])))
        XCTAssertEqual(DicomOverlayPlaneModule.validate(statistics)[.pixelsAndGeometry], .incomplete)
        XCTAssertEqual(DicomOverlayPlaneModule.validate(.init()).diagnostics, [])
    }

    func test_bigEndianOW_preservesBitOrderWithoutChangingOverlayLength() throws {
        var source = try fixture()
        for element in overlayDataSet().elements { source.set(element) }
        source.set(payload(Data([1, 0x55])))
        let bytes = try DicomDataSetWriter.part10Data(from: source, options: .init(
            transferSyntax: .explicitVRBigEndian,
            mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.7", mediaStorageSOPInstanceUID: "2.25.23219911"
        ))
        let report = try DicomInstanceValidator.validate(bytes)
        XCTAssertFalse(report.diagnostics.contains { $0.severity == .error })
        XCTAssertEqual(Array(try XCTUnwrap(DCMDecoder(data: bytes).overlayPlanes().first).mask),
                       [1, 0, 1, 0, 1, 0, 1, 0, 1])
    }

    private func fixture() throws -> DicomDataSet {
        DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 1, count: 12)),
            options: .init(sopInstanceUID: "2.25.23219911", studyInstanceUID: "2.25.23219912",
                           seriesInstanceUID: "2.25.23219913", seriesNumber: 1, instanceNumber: 1),
            requiredType2Attributes: .init()
        )
    }
    private func overlayDataSet() -> DicomDataSet {
        .init(elements: [number(0x60000010, 3), number(0x60000011, 3),
            .init(tag: 0x60000040, vr: .CS, value: .strings(["G"])),
            .init(tag: 0x60000050, vr: .SS, value: .signedIntegers([0, -1])),
            number(0x60000100, 1), number(0x60000102, 0), payload(Data([0x55, 1]))])
    }
    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement {
        .init(tag: tag, vr: .US, value: .unsignedIntegers([value]))
    }
    private func payload(_ data: Data) -> DicomDataElement {
        .init(tag: 0x60003000, vr: .OW, value: .bytes(data))
    }
}
