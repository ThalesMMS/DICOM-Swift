//
//  DicomMediaCatalogTests.swift
//  DicomCoreTests
//
//  Checks ZIP media cataloging, temporary-directory ownership, and classification of non-renderable
//  objects.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
import ZIPFoundation
@testable import DicomCore

final class DicomMediaCatalogTests: XCTestCase {
    func testCatalogsDirectoryMediaAsRenderableSeries() throws {
        let root = try makeTemporaryDirectory(prefix: "catalog-directory")
        defer { try? FileManager.default.removeItem(at: root) }

        let imageURL = root.appendingPathComponent("image-1.dcm")
        try makePart10Image(patientName: "DOE^JANE",
                            patientID: "P-1",
                            studyInstanceUID: "2.25.1",
                            seriesInstanceUID: "2.25.2",
                            sopInstanceUID: "2.25.3")
            .write(to: imageURL)

        let catalog = try DicomMediaCatalogBuilder().catalogSynchronously(from: root)
        let instance = try XCTUnwrap(catalog.instances.first)

        XCTAssertEqual(catalog.sourceKind, .directory)
        XCTAssertEqual(catalog.instances.count, 1)
        XCTAssertEqual(instance.fileURL?.standardizedFileURL, imageURL.standardizedFileURL)
        XCTAssertEqual(instance.patientName, "DOE^JANE")
        XCTAssertEqual(instance.patientID, "P-1")
        XCTAssertEqual(instance.modality, "CT")
        XCTAssertTrue(instance.hasRenderablePixels)
        XCTAssertFalse(instance.isSpecialObject)
    }

    func testCatalogsDICOMDIRThroughReferencedFiles() throws {
        let root = try makeTemporaryDirectory(prefix: "catalog-dicomdir")
        let imageDirectory = root.appendingPathComponent("IMAGES", isDirectory: true)
        let imageURL = imageDirectory.appendingPathComponent("IMG0001")
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try makePart10Image(patientName: "DOE^JANE",
                            patientID: "P-1",
                            studyInstanceUID: "2.25.10",
                            seriesInstanceUID: "2.25.11",
                            sopInstanceUID: "2.25.12")
            .write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = DicomDirectory(fileSetID: "MEDIA",
                                       patients: [
                                        DicomDirectoryPatient(
                                            patientID: "P-1",
                                            patientName: "DOE^JANE",
                                            studies: [
                                                DicomDirectoryStudy(
                                                    studyInstanceUID: "2.25.10",
                                                    studyID: "STUDY1",
                                                    studyDate: "20260529",
                                                    series: [
                                                        DicomDirectorySeries(
                                                            seriesInstanceUID: "2.25.11",
                                                            modality: "CT",
                                                            seriesNumber: 1,
                                                            images: [
                                                                DicomDirectoryImage(
                                                                    referencedFileID: ["IMAGES", "IMG0001"],
                                                                    referencedSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                                                                    referencedSOPInstanceUID: "2.25.12",
                                                                    referencedTransferSyntaxUID: DicomTransferSyntax.explicitVRLittleEndian.rawValue,
                                                                    instanceNumber: 1
                                                                )
                                                            ]
                                                        )
                                                    ]
                                                )
                                            ]
                                        )
                                       ])
        try DicomDirectoryWriter.write(directory, to: root.appendingPathComponent("DICOMDIR"))

        let catalog = try DicomMediaCatalogBuilder().catalogSynchronously(from: root)
        let instance = try XCTUnwrap(catalog.instances.first)

        XCTAssertEqual(catalog.sourceKind, .dicomDirectory)
        XCTAssertEqual(catalog.instances.count, 1)
        XCTAssertEqual(instance.fileURL, imageURL.standardizedFileURL)
        XCTAssertEqual(instance.studyInstanceUID, "2.25.10")
        XCTAssertEqual(instance.seriesInstanceUID, "2.25.11")
        XCTAssertEqual(instance.instanceNumber, 1)
        XCTAssertTrue(instance.hasRenderablePixels)
    }

    func testCatalogsZipMediaAndReturnsCleanupRoot() throws {
        let root = try makeTemporaryDirectory(prefix: "catalog-zip")
        defer { try? FileManager.default.removeItem(at: root) }

        let zipURL = root.appendingPathComponent("media.zip")
        let imageData = try makePart10Image(patientName: "DOE^JANE",
                                            patientID: "P-1",
                                            studyInstanceUID: "2.25.20",
                                            seriesInstanceUID: "2.25.21",
                                            sopInstanceUID: "2.25.22")
        try makeZip(at: zipURL, entries: ["MEDIA/IMAGES/IMG0001": imageData])

        let catalog = try DicomMediaCatalogBuilder().catalogSynchronously(from: zipURL)
        defer {
            if let temporaryDirectoryURL = catalog.temporaryDirectoryURL {
                try? FileManager.default.removeItem(at: temporaryDirectoryURL)
            }
        }

        XCTAssertEqual(catalog.sourceKind, .zip)
        XCTAssertEqual(catalog.instances.count, 1)
        XCTAssertNotNil(catalog.temporaryDirectoryURL)
        XCTAssertTrue(try XCTUnwrap(catalog.instances.first).hasRenderablePixels)
    }

    func testSpecialObjectsAreClassifiedAsNonRenderable() {
        let instance = DicomMediaCatalogInstance(
            fileURL: nil,
            patientName: "Unknown",
            patientID: "",
            studyInstanceUID: "2.25.30",
            studyDate: "",
            studyDescription: "",
            seriesInstanceUID: "2.25.31",
            seriesDescription: "",
            modality: "",
            sopClassUID: DicomSRDocument.keyObjectSelectionDocumentStorageSOPClassUID,
            sopInstanceUID: "2.25.32",
            instanceNumber: nil,
            fileSize: 0,
            hasRenderablePixels: false
        )

        XCTAssertTrue(instance.isSpecialObject)
        XCTAssertEqual(instance.objectKindLabel, "KOS")
        XCTAssertEqual(instance.displayModality, "KOS")
        XCTAssertFalse(instance.hasRenderablePixels)
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePart10Image(patientName: String,
                                 patientID: String,
                                 studyInstanceUID: String,
                                 seriesInstanceUID: String,
                                 sopInstanceUID: String) throws -> Data {
        let dataSet = DicomDataSet(elements: [
            string(DicomTag.sopClassUID.rawValue,
                   .UI,
                   DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(DicomTag.sopInstanceUID.rawValue, .UI, sopInstanceUID),
            string(DicomTag.patientName.rawValue, .PN, patientName),
            string(DicomTag.patientID.rawValue, .LO, patientID),
            string(DicomTag.studyDate.rawValue, .DA, "20260529"),
            string(DicomTag.studyDescription.rawValue, .LO, "CT CHEST"),
            string(DicomTag.studyInstanceUID.rawValue, .UI, studyInstanceUID),
            string(DicomTag.seriesInstanceUID.rawValue, .UI, seriesInstanceUID),
            string(DicomTag.seriesDescription.rawValue, .LO, "AXIAL"),
            string(DicomTag.modality.rawValue, .CS, "CT"),
            string(DicomTag.conversionType.rawValue, .CS, "WSD"),
            DicomDataElement(tag: DicomTag.instanceNumber.rawValue, vr: .IS, value: .strings(["1"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            string(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data([0x7F])))
        ])

        return try DicomDataSetWriter.part10Data(from: dataSet)
    }

    private func makeZip(at url: URL, entries: [String: Data]) throws {
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    private func string(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }
}
