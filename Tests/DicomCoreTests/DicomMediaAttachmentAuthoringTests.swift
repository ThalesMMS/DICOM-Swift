import Foundation
import XCTest
@testable import DicomCore

final class DicomMediaAttachmentAuthoringTests: XCTestCase {
    func test_secondaryCaptureAuthoring_roundTripsIdentityMetadataAndExactPixels() throws {
        let pixels = Data([255, 0, 0, 255, 255, 255])
        let pixelData = try DicomSecondaryCapturePixelData.rgb8(
            columns: 2,
            rows: 1,
            data: pixels
        )
        let options = DicomSecondaryCaptureBuildOptions(
            sopInstanceUID: "2.25.2114003",
            studyInstanceUID: "2.25.2114001",
            seriesInstanceUID: "2.25.2114002",
            seriesNumber: 14,
            instanceNumber: 1,
            seriesDate: "20260829",
            seriesTime: "211400",
            seriesDescription: "External photograph",
            contentDate: "20260829",
            contentTime: "211401",
            instanceCreationDate: "20260829",
            instanceCreationTime: "211402",
            dateOfSecondaryCapture: "20260829",
            timeOfSecondaryCapture: "211403",
            derivationDescription: "External still image imported into the study",
            sourceImageReferences: [],
            secondaryCaptureDeviceID: "ISIS_VIEWER",
            secondaryCaptureDeviceManufacturer: "Isis Project",
            secondaryCaptureDeviceManufacturerModelName: "Isis DICOM Viewer"
        )

        let data = try DicomSecondaryCaptureBuilder.part10Data(
            pixelData: pixelData,
            options: options,
            requiredType2Attributes: Self.type2Attributes
        )
        let decoder = try DCMDecoder(data: data)
        let image = try XCTUnwrap(decoder.secondaryCaptureImage)

        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertEqual(decoder.info(for: 0x0002_0002), DicomSecondaryCaptureImage.storageSOPClassUID)
        XCTAssertEqual(decoder.info(for: 0x0002_0003), "2.25.2114003")
        XCTAssertEqual(image.sopInstanceUID, "2.25.2114003")
        XCTAssertEqual(image.studyInstanceUID, "2.25.2114001")
        XCTAssertEqual(image.seriesInstanceUID, "2.25.2114002")
        XCTAssertEqual(image.modality, "OT")
        XCTAssertEqual(image.imageType, ["DERIVED", "SECONDARY"])
        XCTAssertEqual(image.conversionType, "WSD")
        XCTAssertEqual(image.derivationDescription, "External still image imported into the study")
        XCTAssertEqual(image.dateOfSecondaryCapture, "20260829")
        XCTAssertEqual(image.timeOfSecondaryCapture, "211403")
        XCTAssertEqual(image.sourceImageReferences, [])
        XCTAssertEqual(image.secondaryCaptureDeviceID, "ISIS_VIEWER")
        XCTAssertEqual(image.secondaryCaptureDeviceManufacturer, "Isis Project")
        XCTAssertEqual(image.secondaryCaptureDeviceManufacturerModelName, "Isis DICOM Viewer")
        XCTAssertEqual(image.pixelDataDescriptor?.columns, 2)
        XCTAssertEqual(image.pixelDataDescriptor?.rows, 1)
        XCTAssertEqual(image.pixelDataDescriptor?.samplesPerPixel, 3)
        XCTAssertEqual(image.pixelDataDescriptor?.photometricInterpretation, "RGB")
        XCTAssertEqual(decoder.dataSet.int(for: .seriesNumber), 14)
        XCTAssertEqual(decoder.dataSet.int(for: .instanceNumber), 1)
        XCTAssertEqual(decoder.info(for: .seriesDescription), "External photograph")
        XCTAssertEqual(decoder.getPixels24(), Array(pixels))
        assertType2Attributes(in: decoder.dataSet)
    }

    func test_videoPhotographicAuthoring_roundTripsIdentityTimingMetadataAndExactStream() throws {
        let stream = Data([
            0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x0A,
            0, 0, 0, 1, 0x68, 0xCE, 0x0F, 0xC8,
            0, 0, 0, 1, 0x65, 0x88, 0x84, 0x00
        ])
        let pixelData = try DicomVideoPixelData(
            streamData: stream,
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            columns: 16,
            rows: 16,
            numberOfFrames: 2,
            frameTimeMilliseconds: 500
        )
        let options = DicomVideoBuildOptions(
            kind: .photographic,
            sopInstanceUID: "2.25.2114013",
            studyInstanceUID: "2.25.2114011",
            seriesInstanceUID: "2.25.2114012",
            seriesNumber: 15,
            instanceNumber: 1,
            seriesDate: "20260829",
            seriesTime: "211410",
            seriesDescription: "External movie",
            contentDate: "20260829",
            contentTime: "211411",
            modality: "XC",
            imageType: ["DERIVED", "SECONDARY", "VIDEO"],
            sourceImageReferences: []
        )

        let data = try DicomVideoBuilder.part10Data(
            video: pixelData,
            options: options,
            requiredType2Attributes: Self.type2Attributes
        )
        let decoder = try DCMDecoder(data: data)
        let video = try XCTUnwrap(decoder.video)

        XCTAssertEqual(
            decoder.info(for: .transferSyntaxUID),
            DicomTransferSyntax.mpeg4AVCH264HighProfileLevel41.rawValue
        )
        XCTAssertEqual(decoder.info(for: 0x0002_0002), DicomVideo.videoPhotographicImageStorageSOPClassUID)
        XCTAssertEqual(decoder.info(for: 0x0002_0003), "2.25.2114013")
        XCTAssertEqual(video.kind, .photographic)
        XCTAssertEqual(video.sopClassUID, DicomVideo.videoPhotographicImageStorageSOPClassUID)
        XCTAssertEqual(video.sopInstanceUID, "2.25.2114013")
        XCTAssertEqual(video.studyInstanceUID, "2.25.2114011")
        XCTAssertEqual(video.seriesInstanceUID, "2.25.2114012")
        XCTAssertEqual(video.modality, "XC")
        XCTAssertEqual(video.imageType, ["DERIVED", "SECONDARY", "VIDEO"])
        XCTAssertEqual(video.codec, .h264)
        XCTAssertEqual(video.columns, 16)
        XCTAssertEqual(video.rows, 16)
        XCTAssertEqual(video.numberOfFrames, 2)
        XCTAssertEqual(video.frameTimeMilliseconds, 500)
        XCTAssertNil(video.cineRate)
        XCTAssertNil(video.recommendedDisplayFrameRate)
        XCTAssertEqual(video.lossyImageCompression, "01")
        XCTAssertEqual(video.lossyImageCompressionMethod, "ISO_14496_10")
        XCTAssertEqual(video.sourceImageReferences, [])
        XCTAssertEqual(video.streamData, stream)
        XCTAssertEqual(decoder.dataSet.int(for: .seriesNumber), 15)
        XCTAssertEqual(decoder.dataSet.int(for: .instanceNumber), 1)
        XCTAssertEqual(decoder.info(for: .seriesDescription), "External movie")
        assertType2Attributes(in: decoder.dataSet)
    }

    func test_requiredType2Attributes_remainPresentWhenEveryValueIsEmpty() throws {
        let pixelData = try DicomSecondaryCapturePixelData.monochrome8(
            columns: 1,
            rows: 1,
            data: Data([42])
        )
        let data = try DicomSecondaryCaptureBuilder.part10Data(
            pixelData: pixelData,
            options: DicomSecondaryCaptureBuildOptions(
                sopInstanceUID: "2.25.2114023",
                studyInstanceUID: "2.25.2114021",
                seriesInstanceUID: "2.25.2114022",
                contentDate: "20260829",
                contentTime: "211420"
            ),
            requiredType2Attributes: DicomMediaAttachmentType2Attributes()
        )
        let dataSet = try DCMDecoder(data: data).dataSet

        for tag in Self.type2Tags {
            XCTAssertTrue(dataSet.contains(tag), String(format: "Missing Type 2 tag %08X", tag))
            XCTAssertEqual(dataSet[tag]?.value, .empty)
        }
    }

    private func assertType2Attributes(
        in dataSet: DicomDataSet,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected: [(Int, String)] = [
            (DicomTag.patientName.rawValue, "Media^External"),
            (DicomTag.patientID.rawValue, "MEDIA-2114"),
            (0x0010_0030, "19800102"),
            (DicomTag.patientSex.rawValue, "F"),
            (DicomTag.studyDate.rawValue, "20260801"),
            (DicomTag.studyTime.rawValue, "120000"),
            (DicomTag.referringPhysicianName.rawValue, "Physician^Ref"),
            (DicomTag.studyID.rawValue, "STUDY-2114"),
            (DicomTag.accessionNumber.rawValue, "ACC-2114"),
            (0x0008_0070, "Isis Project")
        ]
        for (tag, value) in expected {
            XCTAssertTrue(dataSet.contains(tag), String(format: "Missing Type 2 tag %08X", tag), file: file, line: line)
            XCTAssertEqual(dataSet[tag]?.stringValue, value, file: file, line: line)
        }
    }

    private static let type2Attributes = DicomMediaAttachmentType2Attributes(
        patientName: "Media^External",
        patientID: "MEDIA-2114",
        patientBirthDate: "19800102",
        patientSex: "F",
        studyDate: "20260801",
        studyTime: "120000",
        referringPhysicianName: "Physician^Ref",
        studyID: "STUDY-2114",
        accessionNumber: "ACC-2114",
        manufacturer: "Isis Project"
    )

    private static let type2Tags = [
        DicomTag.patientName.rawValue,
        DicomTag.patientID.rawValue,
        0x0010_0030,
        DicomTag.patientSex.rawValue,
        DicomTag.studyDate.rawValue,
        DicomTag.studyTime.rawValue,
        DicomTag.referringPhysicianName.rawValue,
        DicomTag.studyID.rawValue,
        DicomTag.accessionNumber.rawValue,
        0x0008_0070
    ]
}
