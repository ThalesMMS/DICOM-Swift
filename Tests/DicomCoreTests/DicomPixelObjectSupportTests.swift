//
//  DicomPixelObjectSupportTests.swift
//  DicomCoreTests
//
//  Non-classic pixel object policy (issue #1238): the declared support matrix, typed payload
//  extraction for RT Dose (dose grid metadata preserved), classification of classic images, and
//  stable rejections naming SOP Class, pixel data element type, transfer syntax, and the missing
//  metadata for unsupported shapes.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomPixelObjectSupportTests: XCTestCase {
    // MARK: - Support matrix

    func testSupportMatrixCoversEveryFamilyWithRolesAndDiagnostics() {
        let rows = Dictionary(uniqueKeysWithValues: DicomPixelObjectSupportMatrix.standard.map { ($0.family, $0) })
        XCTAssertEqual(Set(rows.keys), Set(DicomPixelObjectFamily.allCases))

        XCTAssertEqual(rows[.classicImage]?.role, .imageDisplayInput)
        XCTAssertEqual(rows[.classicImage]?.status, .classicPipelines)
        XCTAssertEqual(rows[.segmentation]?.role, .overlayOrSegmentation)
        XCTAssertEqual(rows[.segmentation]?.status, .typedPayload)
        XCTAssertEqual(rows[.rtDose]?.role, .doseGrid)
        XCTAssertEqual(rows[.rtDose]?.status, .typedPayload)
        XCTAssertEqual(rows[.parametricMap]?.role, .volumeInput)
        XCTAssertEqual(rows[.parametricMap]?.status, .typedPayload)
        XCTAssertEqual(rows[.floatImage]?.status, .unsupported)
        XCTAssertEqual(rows[.doubleFloatImage]?.status, .unsupported)
        for row in DicomPixelObjectSupportMatrix.standard {
            XCTAssertFalse(row.diagnostic.isEmpty, "\(row.family) needs a stable diagnostic")
        }
    }

    // MARK: - Supported typed payload: RT Dose

    func testRTDoseTypedPayloadPreservesDoseGridMetadata() throws {
        let decoder = try Self.openRTDoseFixture()

        let classification = DicomPixelObjectClassifier.classify(decoder)
        XCTAssertEqual(classification.family, .rtDose)
        XCTAssertEqual(classification.sopClassUID, DicomRTDoseVolume.storageSOPClassUID)
        XCTAssertEqual(classification.pixelElement, .integer)

        guard case .rtDose(let dose) = try DicomPixelObjectClassifier.typedPayload(from: decoder) else {
            return XCTFail("expected an RT Dose payload")
        }
        XCTAssertEqual(dose.doseUnits, "GY")
        XCTAssertEqual(dose.doseGridScaling, 0.01, accuracy: 1e-12)
        XCTAssertEqual(dose.gridFrameOffsetVector, [0, 2.5])
        XCTAssertEqual(dose.frames, 2)
        XCTAssertEqual(dose.storedValues, [10, 20, 30, 40, 50, 60, 70, 80].map(UInt32.init))
        XCTAssertEqual(dose.doseValues.first ?? 0, 0.1, accuracy: 1e-12,
                       "stored values must scale by Dose Grid Scaling")
        XCTAssertEqual(dose.frameOfReferenceUID, "2.25.12380000")
    }

    // MARK: - Classic images route to the frame reader

    func testClassicImageClassifiesAndRoutesToTheFrameReader() throws {
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .rleLossless,
            fragments: [Self.rleSegment(samples: [1, 2, 3, 4])],
            declaredFrames: 1
        )
        let decoder = try Self.open(file)

        let classification = DicomPixelObjectClassifier.classify(decoder)
        XCTAssertEqual(classification.family, .classicImage)
        XCTAssertEqual(classification.transferSyntaxUID, DicomTransferSyntax.rleLossless.rawValue)

        guard case .classicImage(let reader) = try DicomPixelObjectClassifier.typedPayload(from: decoder) else {
            return XCTFail("expected a classic image payload")
        }
        XCTAssertEqual(reader.frameCount, 1)
    }

    // MARK: - Unsupported cases stay typed with full identity

    func testBareFloatPixelDataObjectIsRejectedWithFullContext() throws {
        var body = Data()
        // Minimal image module plus Float Pixel Data (7FE0,0008) under a
        // non-Parametric-Map SOP class.
        Self.appendShortString(&body, group: 0x0008, element: 0x0016, vr: "UI",
                               value: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID)
        Self.appendUS(&body, group: 0x0028, element: 0x0002, value: 1)
        Self.appendShortString(&body, group: 0x0028, element: 0x0004, vr: "CS", value: "MONOCHROME2")
        Self.appendUS(&body, group: 0x0028, element: 0x0010, value: 1)
        Self.appendUS(&body, group: 0x0028, element: 0x0011, value: 2)
        Self.appendUS(&body, group: 0x0028, element: 0x0100, value: 32)
        Self.appendUS(&body, group: 0x0028, element: 0x0101, value: 32)
        Self.appendUS(&body, group: 0x0028, element: 0x0102, value: 31)
        Self.appendUS(&body, group: 0x0028, element: 0x0103, value: 0)
        // (7FE0,0008) OF with two float samples.
        body.append(contentsOf: [0xE0, 0x7F, 0x08, 0x00, 0x4F, 0x46, 0x00, 0x00])
        withUnsafeBytes(of: UInt32(8).littleEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: Float32(1.5).bitPattern.littleEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: Float32(2.5).bitPattern.littleEndian) { body.append(contentsOf: $0) }

        var fileData = Data(count: 128)
        fileData.append(contentsOf: "DICM".utf8)
        fileData.append(body)
        let decoder = try Self.openRaw(fileData)

        let classification = DicomPixelObjectClassifier.classify(decoder)
        XCTAssertEqual(classification.family, .floatImage)
        XCTAssertEqual(classification.pixelElement, .float)

        XCTAssertThrowsError(try DicomPixelObjectClassifier.typedPayload(from: decoder)) { error in
            guard let rejection = error as? DicomPixelObjectError else {
                return XCTFail("expected DicomPixelObjectError, got \(error)")
            }
            XCTAssertEqual(rejection.sopClassUID, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID)
            XCTAssertEqual(rejection.pixelElement, .float)
            XCTAssertEqual(rejection.transferSyntaxUID, DicomTransferSyntax.explicitVRLittleEndian.rawValue)
            XCTAssertTrue(rejection.errorDescription?.contains("Float Pixel Data") == true)
        }
    }

    func testRTDoseMissingRequiredMetadataIsRejectedNamingTheGap() throws {
        // RT Dose SOP class without Dose Grid Scaling or grid geometry.
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .explicitVRLittleEndian,
            fragments: [],
            declaredFrames: 1,
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15
        )
        dataSet.set(DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                                     value: .strings([DicomRTDoseVolume.storageSOPClassUID])))
        dataSet.set(DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["RTDOSE"])))
        dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW,
                                     value: .bytes(Data([1, 0, 2, 0, 3, 0, 4, 0]))))
        let file = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomRTDoseVolume.storageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12380002"
            )
        )
        let decoder = try Self.open(file)

        XCTAssertThrowsError(try DicomPixelObjectClassifier.typedPayload(from: decoder)) { error in
            guard let rejection = error as? DicomPixelObjectError else {
                return XCTFail("expected DicomPixelObjectError, got \(error)")
            }
            XCTAssertEqual(rejection.sopClassUID, DicomRTDoseVolume.storageSOPClassUID)
            XCTAssertTrue(rejection.reason.contains("Dose Grid Scaling"), rejection.reason)
        }
    }

    // MARK: - Builders

    private static func openRTDoseFixture() throws -> DCMDecoder {
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .explicitVRLittleEndian,
            fragments: [],
            declaredFrames: 2,
            rows: 2,
            columns: 2,
            bitsAllocated: 16,
            bitsStored: 16,
            highBit: 15
        )
        dataSet.set(DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                                     value: .strings([DicomRTDoseVolume.storageSOPClassUID])))
        dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12380001"])))
        dataSet.set(DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["RTDOSE"])))
        dataSet.set(DicomDataElement(tag: DicomTag.doseUnits.rawValue, vr: .CS, value: .strings(["GY"])))
        dataSet.set(DicomDataElement(tag: DicomTag.doseType.rawValue, vr: .CS, value: .strings(["PHYSICAL"])))
        dataSet.set(DicomDataElement(tag: DicomTag.doseSummationType.rawValue, vr: .CS, value: .strings(["PLAN"])))
        dataSet.set(DicomDataElement(tag: DicomTag.frameOfReferenceUID.rawValue, vr: .UI,
                                     value: .strings(["2.25.12380000"])))
        dataSet.set(DicomDataElement(tag: DicomTag.doseGridScaling.rawValue, vr: .DS, value: .strings(["0.01"])))
        dataSet.set(DicomDataElement(tag: DicomTag.gridFrameOffsetVector.rawValue, vr: .DS,
                                     value: .strings(["0", "2.5"])))
        dataSet.set(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["2"])))
        dataSet.set(DicomDataElement(tag: DicomTag.pixelSpacing.rawValue, vr: .DS, value: .strings(["1.25", "1.5"])))
        dataSet.set(DicomDataElement(tag: DicomTag.imagePositionPatient.rawValue, vr: .DS,
                                     value: .strings(["10", "20", "30"])))
        dataSet.set(DicomDataElement(tag: DicomTag.imageOrientationPatient.rawValue, vr: .DS,
                                     value: .strings(["1", "0", "0", "0", "1", "0"])))
        var pixelData = Data()
        for value in [UInt16(10), 20, 30, 40, 50, 60, 70, 80] {
            pixelData.append(UInt8(value & 0xFF))
            pixelData.append(UInt8(value >> 8))
        }
        dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixelData)))

        let file = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomRTDoseVolume.storageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12380001"
            )
        )
        return try open(file)
    }

    private static func rleSegment(samples: [UInt8]) -> Data {
        var rle = Data()
        var header = [UInt32](repeating: 0, count: 16)
        header[0] = 1
        header[1] = 64
        for value in header {
            withUnsafeBytes(of: value.littleEndian) { rle.append(contentsOf: $0) }
        }
        rle.append(UInt8(samples.count - 1))
        rle.append(contentsOf: samples)
        if rle.count % 2 != 0 {
            rle.append(0x00)
        }
        return rle
    }

    private static func open(_ data: Data) throws -> DCMDecoder {
        try openRaw(data)
    }

    private static func openRaw(_ data: Data) throws -> DCMDecoder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pixel_object_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private static func appendShortString(_ data: inout Data, group: UInt16, element: UInt16, vr: String, value: String) {
        var bytes = Array(value.utf8)
        if bytes.count % 2 != 0 {
            bytes.append(vr == "UI" ? 0x00 : 0x20)
        }
        data.append(UInt8(group & 0xFF)); data.append(UInt8(group >> 8))
        data.append(UInt8(element & 0xFF)); data.append(UInt8(element >> 8))
        data.append(contentsOf: Array(vr.utf8))
        data.append(UInt8(bytes.count & 0xFF)); data.append(UInt8(bytes.count >> 8))
        data.append(contentsOf: bytes)
    }

    private static func appendUS(_ data: inout Data, group: UInt16, element: UInt16, value: UInt16) {
        data.append(UInt8(group & 0xFF)); data.append(UInt8(group >> 8))
        data.append(UInt8(element & 0xFF)); data.append(UInt8(element >> 8))
        data.append(contentsOf: [0x55, 0x53, 0x02, 0x00])
        data.append(UInt8(value & 0xFF)); data.append(UInt8(value >> 8))
    }
}
