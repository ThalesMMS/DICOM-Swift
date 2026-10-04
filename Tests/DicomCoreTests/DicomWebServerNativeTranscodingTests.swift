//
//  DicomWebServerNativeTranscodingTests.swift
//  DicomCoreTests
//
//  The server's native transcoding: Explicit VR Little Endian is offered for
//  every native or decodable stored syntax, never another destination, and
//  an Implicit VR Little Endian instance comes out with its values intact.
//

import XCTest
@testable import DicomCore

final class DicomWebServerNativeTranscodingTests: XCTestCase {
    func test_routes_offerExplicitLittleEndianOnly() {
        let transcoding = DicomWebServerNativeTranscoding()
        let explicit = DicomTransferSyntax.explicitVRLittleEndian.rawValue
        XCTAssertEqual(transcoding.transferSyntaxUIDs, [explicit])
        for source in [DicomTransferSyntax.implicitVRLittleEndian, .explicitVRBigEndian, .rleLossless,
                       .jpegLSLossless, .jpeg2000Lossless] {
            XCTAssertTrue(transcoding.canTranscode(from: source.rawValue, to: explicit), "\(source)")
        }
        XCTAssertFalse(transcoding.canTranscode(from: explicit, to: DicomTransferSyntax.jpegLSLossless.rawValue))
        XCTAssertFalse(transcoding.canTranscode(from: DicomTransferSyntax.implicitVRLittleEndian.rawValue,
                                                to: DicomTransferSyntax.explicitVRBigEndian.rawValue))
    }

    func test_implicitInstance_isServedAsExplicitLittleEndian() async throws {
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.1143001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.1143002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.1143003"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["Doe^Jane"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([15])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Data([0x03, 0x00, 0x00, 0x01])))
        ])
        let part10 = try DicomDataSetWriter.part10Data(from: dataSet,
            options: DicomPart10WriterOptions(transferSyntax: .implicitVRLittleEndian))
        let instance = DicomWebStoredInstance(dataSet: dataSet, part10Data: part10, studyInstanceUID: "2.25.1143002",
            seriesInstanceUID: "2.25.1143003", sopInstanceUID: "2.25.1143001",
            sopClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
            transferSyntax: .implicitVRLittleEndian)
        let output = try await DicomWebServerNativeTranscoding().transcode(instance,
            to: DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        let decoder = try DCMDecoder(data: output)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertEqual(decoder.info(for: .patientName), "Doe^Jane")
        XCTAssertEqual(decoder.getPixels16(), [3, 256])
    }
}
