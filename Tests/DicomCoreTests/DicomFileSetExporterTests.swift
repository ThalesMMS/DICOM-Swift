import XCTest
import ZIPFoundation
@testable import DicomCore

final class DicomFileSetExporterTests: XCTestCase {
    func testExportCreatesReopenableFileSetWithCollisionFreeReferences() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("image.dcm")
        let second = secondDirectory.appendingPathComponent("image.dcm")
        try makePart10Data(sopInstanceUID: "2.25.1", instanceNumber: 1).write(to: first)
        try makePart10Data(sopInstanceUID: "2.25.2", instanceNumber: 2).write(to: second)
        let destination = root.appendingPathComponent("DICOM.ZIP")

        let result = try await DicomFileSetExporter().export(files: [second, first], to: destination)

        XCTAssertEqual(result.applicationProfile, "STD-GEN-ZIP-MAIL")
        XCTAssertEqual(result.instanceCount, 2)
        let archive = try Archive(url: destination, accessMode: .read)
        XCTAssertEqual(Array(archive).map(\.path), ["DICOMDIR", "IMAGES/I0000001", "IMAGES/I0000002"])

        let directoryEntry = try XCTUnwrap(archive["DICOMDIR"])
        var directoryData = Data()
        _ = try archive.extract(directoryEntry) { directoryData.append($0) }
        let directory = try DicomDirectoryReader.read(data: directoryData)
        let images = try XCTUnwrap(directory.patients.first?.studies.first?.series.first?.images)
        XCTAssertEqual(images.map(\.referencedFileID), [["IMAGES", "I0000001"], ["IMAGES", "I0000002"]])
        XCTAssertEqual(Set(images.compactMap(\.referencedSOPInstanceUID)), ["2.25.1", "2.25.2"])
        XCTAssertEqual(directory.patients.first?.studies.first?.studyDescription, "HEAD")
    }

    func testExportRejectsUnsupportedSOPClassWithoutLeavingArtifact() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.dcm")
        // Verification is not a storage SOP Class and has no PS3.3 F.4 directory record.
        try makePart10Data(sopClassUID: "1.2.840.10008.1.1").write(to: source)
        let destination = root.appendingPathComponent("DICOM.ZIP")

        await XCTAssertThrowsErrorAsync(
            try await DicomFileSetExporter().export(files: [source], to: destination)
        ) { error in
            guard case DicomFileSetExporter.ExportError.unsupportedSOPClass = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_unsupportedFileMetaSOPClass_preservesExportErrorAndFileName() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("mismatched.dcm")
        let unsupported = "1.2.840.10008.1.1"
        try makePart10Data(fileMetaSOPClassUID: unsupported).write(to: source)
        let destination = root.appendingPathComponent("DICOM.ZIP")
        await XCTAssertThrowsErrorAsync(try await DicomFileSetExporter().export(files: [source], to: destination)) { error in
            guard case DicomFileSetExporter.ExportError.unsupportedSOPClass(let file, let uid) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(file, "mismatched.dcm")
            XCTAssertEqual(uid, unsupported)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportPreflightsCapacityWithoutLeavingArtifact() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.dcm")
        try makePart10Data().write(to: source)
        let destination = root.appendingPathComponent("DICOM.ZIP")
        let exporter = DicomFileSetExporter(availableCapacity: { _ in 1 })

        await XCTAssertThrowsErrorAsync(try await exporter.export(files: [source], to: destination)) { error in
            guard case DicomFileSetExporter.ExportError.insufficientSpace = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_missingRecordKey_preservesTheExportErrorAndIssueDetail() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("missing-key.dcm")
        var dataSet = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: makePart10Data()))
        dataSet.remove(.instanceNumber)
        try DicomDataSetWriter.part10Data(from: dataSet).write(to: source)
        let destination = root.appendingPathComponent("DICOM.ZIP")
        await XCTAssertThrowsErrorAsync(try await DicomFileSetExporter().export(files: [source], to: destination)) { error in
            guard case DicomFileSetExporter.ExportError.inconsistentHierarchy(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("missingRecordKey"))
            XCTAssertTrue(reason.contains("00200013"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportRejectsConflictingSeriesMetadataWithoutLeavingArtifact() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.dcm")
        let second = root.appendingPathComponent("second.dcm")
        try makePart10Data(sopInstanceUID: "2.25.1", modality: "CT").write(to: first)
        try makePart10Data(sopInstanceUID: "2.25.2", modality: "MR").write(to: second)
        let destination = root.appendingPathComponent("DICOM.ZIP")

        await XCTAssertThrowsErrorAsync(
            try await DicomFileSetExporter().export(files: [first, second], to: destination)
        ) { error in
            guard case DicomFileSetExporter.ExportError.inconsistentHierarchy = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportHonorsCancellationWithoutLeavingArtifact() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("image.dcm")
        try makePart10Data().write(to: source)
        let destination = root.appendingPathComponent("DICOM.ZIP")
        let task = Task {
            try await DicomFileSetExporter().export(files: [source], to: destination)
        }
        task.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testExportExternalFixtureWhenConfigured() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["DICOM_FILESET_FIXTURE"] else {
            throw XCTSkip("Set DICOM_FILESET_FIXTURE to validate a real Part 10 instance.")
        }
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("DICOM.ZIP")

        let result = try await DicomFileSetExporter().export(
            files: [URL(fileURLWithPath: sourcePath)],
            to: destination
        )

        XCTAssertEqual(result.instanceCount, 1)
        XCTAssertNotNil(try Archive(url: destination, accessMode: .read)["DICOMDIR"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicom-fileset-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePart10Data(
        sopClassUID: String = "1.2.840.10008.5.1.4.1.1.2",
        sopInstanceUID: String = "2.25.1",
        instanceNumber: Int = 1,
        modality: String = "CT",
        fileMetaSOPClassUID: String? = nil
    ) throws -> Data {
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, .UI, sopClassUID),
            string(.sopInstanceUID, .UI, sopInstanceUID),
            string(.patientID, .LO, "PATIENT1"),
            string(.patientName, .PN, "Doe^Jane"),
            string(.studyInstanceUID, .UI, "2.25.10"),
            string(.studyID, .SH, "STUDY1"),
            string(.studyDate, .DA, "20260824"),
            string(.studyTime, .TM, "120000"),
            string(.studyDescription, .LO, "HEAD"),
            string(.accessionNumber, .SH, "ACC1"),
            string(.seriesInstanceUID, .UI, "2.25.11"),
            string(.modality, .CS, modality),
            DicomDataElement(tag: DicomTag.seriesNumber.rawValue, vr: .IS, value: .signedIntegers([1])),
            DicomDataElement(tag: DicomTag.instanceNumber.rawValue, vr: .IS, value: .signedIntegers([instanceNumber])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            string(.photometricInterpretation, .CS, "MONOCHROME2"),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([15])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Data([0x2A, 0x00])))
        ])
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: fileMetaSOPClassUID ?? sopClassUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )
    }

    private func string(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
