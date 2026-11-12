//
//  DicomSecondaryCaptureTests.swift
//  DicomCoreTests
//
//  Checks source context in snapshot authoring and required clinical export metadata.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import CoreGraphics
import XCTest
@testable import DicomCore

final class DicomSecondaryCaptureTests: XCTestCase {
    func testRGBSecondaryCaptureRoundTripsClinicalContextPixelsAndSourceReference() throws {
        let rgb = Data([
            255, 0, 0,
            0, 255, 0,
            0, 0, 255,
            255, 255, 255
        ])
        let sourceReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9003",
            referencedFrameNumbers: [2]
        )
        let pixelData = try DicomSecondaryCapturePixelData.rgb8(columns: 2, rows: 2, data: rgb)
        let options = DicomSecondaryCaptureBuildOptions(
            sopInstanceUID: "2.25.9000",
            studyInstanceUID: "2.25.9001",
            seriesInstanceUID: "2.25.9002",
            patientName: "Doe^Jane",
            patientID: "P-SC-1",
            studyID: "STUDY-SC",
            studyDate: "20260528",
            studyTime: "120000",
            seriesNumber: 7,
            instanceNumber: 3,
            seriesDate: "20260528",
            seriesTime: "120100",
            contentDate: "20260528",
            contentTime: "120200",
            instanceCreationDate: "20260528",
            instanceCreationTime: "120201",
            dateOfSecondaryCapture: "20260528",
            timeOfSecondaryCapture: "120202",
            derivationDescription: "Viewport snapshot",
            sourceImageReferences: [sourceReference],
            secondaryCaptureDeviceID: "MTK-DEMO",
            secondaryCaptureDeviceManufacturerModelName: "SnapshotExporter",
            secondaryCaptureDeviceSoftwareVersions: "1"
        )

        let decoder = try open(dataSet: DicomSecondaryCaptureBuilder.dataSet(pixelData: pixelData, options: options))
        let secondaryCapture = try XCTUnwrap(decoder.secondaryCaptureImage)

        XCTAssertEqual(secondaryCapture.sopInstanceUID, "2.25.9000")
        XCTAssertEqual(secondaryCapture.studyInstanceUID, "2.25.9001")
        XCTAssertEqual(secondaryCapture.seriesInstanceUID, "2.25.9002")
        XCTAssertEqual(secondaryCapture.modality, "OT")
        XCTAssertEqual(secondaryCapture.patientName?.familyName, "Doe")
        XCTAssertEqual(secondaryCapture.patientName?.givenName, "Jane")
        XCTAssertEqual(secondaryCapture.patientID, "P-SC-1")
        XCTAssertEqual(secondaryCapture.imageType, ["DERIVED", "SECONDARY"])
        XCTAssertEqual(secondaryCapture.conversionType, "WSD")
        XCTAssertEqual(secondaryCapture.derivationDescription, "Viewport snapshot")
        XCTAssertEqual(secondaryCapture.dateOfSecondaryCapture, "20260528")
        XCTAssertEqual(secondaryCapture.timeOfSecondaryCapture, "120202")
        XCTAssertEqual(secondaryCapture.secondaryCaptureDeviceID, "MTK-DEMO")
        XCTAssertEqual(secondaryCapture.secondaryCaptureDeviceManufacturer, "DICOM-Swift")
        XCTAssertEqual(secondaryCapture.secondaryCaptureDeviceManufacturerModelName, "SnapshotExporter")
        XCTAssertEqual(secondaryCapture.secondaryCaptureDeviceSoftwareVersions, "1")
        XCTAssertEqual(secondaryCapture.sourceImageReferences, [sourceReference])
        XCTAssertEqual(secondaryCapture.pixelDataDescriptor?.rows, 2)
        XCTAssertEqual(secondaryCapture.pixelDataDescriptor?.columns, 2)
        XCTAssertEqual(secondaryCapture.pixelDataDescriptor?.samplesPerPixel, 3)
        XCTAssertEqual(secondaryCapture.pixelDataDescriptor?.photometricInterpretation, "RGB")
        XCTAssertEqual(decoder.getPixels24(), Array(rgb))
    }

    func testCGImageSnapshotBuilderPreservesSourceDecoderContext() throws {
        let sourceDecoder = try open(dataSet: sourceImageDataSet())
        let options = DicomSecondaryCaptureBuildOptions.preservingClinicalContext(
            from: sourceDecoder,
            referencedFrameNumbers: [1],
            sopInstanceUID: "2.25.9100",
            seriesDescription: "Snapshot Series"
        )

        let image = try makeRGBImage(
            width: 2,
            height: 1,
            rgba: Data([
                255, 0, 0, 255,
                0, 255, 0, 255
            ])
        )
        let decoder = try open(dataSet: DicomSecondaryCaptureBuilder.dataSet(from: image, options: options))
        let secondaryCapture = try XCTUnwrap(decoder.secondaryCaptureImage)

        XCTAssertEqual(secondaryCapture.sopInstanceUID, "2.25.9100")
        XCTAssertEqual(secondaryCapture.studyInstanceUID, "2.25.9101")
        XCTAssertEqual(secondaryCapture.seriesInstanceUID, "2.25.9102")
        XCTAssertEqual(secondaryCapture.patientName?.familyName, "Source")
        XCTAssertEqual(secondaryCapture.patientID, "SRC-1")
        XCTAssertEqual(secondaryCapture.sourceImageReferences, [
            DicomSourceImageReference(
                referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                referencedSOPInstanceUID: "2.25.9103",
                referencedFrameNumbers: [1]
            )
        ])
        XCTAssertEqual(decoder.getPixels24(), [255, 0, 0, 0, 255, 0])
    }

    func testClinicalExportValidationRequiresPatientStudySeriesAndInstanceMetadata() throws {
        let pixelData = try DicomSecondaryCapturePixelData.monochrome8(
            columns: 1,
            rows: 1,
            data: Data([7])
        )

        XCTAssertThrowsError(
            try DicomSecondaryCaptureBuilder.validatedDataSet(
                pixelData: pixelData,
                options: DicomSecondaryCaptureBuildOptions(patientName: "Only^Name"),
                validationScope: .clinicalExport
            )
        ) { error in
            XCTAssertEqual(
                error as? DicomSecondaryCaptureError,
                .missingRequiredMetadata([
                    "SOP Instance UID",
                    "Study Instance UID",
                    "Series Instance UID",
                    "Patient ID",
                    "Study ID",
                    "Study Date",
                    "Series Number",
                    "Instance Number"
                ])
            )
        }
    }

    func testClinicalExportValidationAcceptsCompleteSecondaryCaptureContext() throws {
        let pixelData = try DicomSecondaryCapturePixelData.monochrome8(
            columns: 1,
            rows: 1,
            data: Data([42])
        )
        let options = DicomSecondaryCaptureBuildOptions(
            sopInstanceUID: "2.25.9200",
            studyInstanceUID: "2.25.9201",
            seriesInstanceUID: "2.25.9202",
            patientName: "Complete^Context",
            patientID: "SC-COMPLETE",
            studyID: "SC-STUDY",
            studyDate: "20260603",
            seriesNumber: 1,
            instanceNumber: 1,
            contentDate: "20260603",
            contentTime: "101010"
        )

        let data = try DicomSecondaryCaptureBuilder.part10Data(
            pixelData: pixelData,
            options: options,
            validationScope: .clinicalExport
        )
        let decoder = try open(data: data)
        let secondaryCapture = try XCTUnwrap(decoder.secondaryCaptureImage)

        XCTAssertEqual(secondaryCapture.sopInstanceUID, "2.25.9200")
        XCTAssertEqual(secondaryCapture.studyInstanceUID, "2.25.9201")
        XCTAssertEqual(secondaryCapture.seriesInstanceUID, "2.25.9202")
        XCTAssertEqual(secondaryCapture.patientName?.familyName, "Complete")
        XCTAssertEqual(secondaryCapture.patientID, "SC-COMPLETE")
        XCTAssertEqual(secondaryCapture.pixelDataDescriptor?.samplesPerPixel, 1)
    }

    private func open(dataSet: DicomDataSet) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID),
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("secondary_capture_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func open(data: Data) throws -> DCMDecoder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("secondary_capture_data_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func sourceImageDataSet() -> DicomDataSet {
        DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, "1.2.840.10008.5.1.4.1.1.2"),
            string(.sopInstanceUID, vr: .UI, "2.25.9103"),
            string(.studyInstanceUID, vr: .UI, "2.25.9101"),
            string(.seriesInstanceUID, vr: .UI, "2.25.9102"),
            string(.patientName, vr: .PN, "Source^Patient"),
            string(.patientID, vr: .LO, "SRC-1"),
            string(.studyID, vr: .SH, "SOURCE-STUDY"),
            string(.studyDate, vr: .DA, "20260528"),
            string(.studyTime, vr: .TM, "130000"),
            string(.seriesDate, vr: .DA, "20260528"),
            string(.seriesTime, vr: .TM, "130100"),
            string(.modality, vr: .CS, "CT"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            us(.rows, 1),
            us(.columns, 1),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Data([0x2A, 0x00])))
        ])
    }

    private func makeRGBImage(width: Int, height: Int, rgba: Data) throws -> CGImage {
        let bytesPerRow = width * 4
        let provider = try XCTUnwrap(CGDataProvider(data: rgba as CFData))
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(clamping: value)]))
    }
}
