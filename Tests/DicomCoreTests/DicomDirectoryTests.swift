import XCTest
@testable import DicomCore

final class DicomDirectoryTests: XCTestCase {
    func testReaderDecodesRecordSpecificCharacterSet() throws {
        let characterSet = DicomSpecificCharacterSet("ISO_IR 144")
        let patientName = "Иванов^Иван"
        let record = explicitStringElement(tag: 0x0004_1430, vr: "CS", value: Data("PATIENT".utf8))
            + explicitStringElement(
                tag: DicomTag.specificCharacterSet.rawValue,
                vr: "CS",
                value: Data("ISO_IR 144".utf8)
            )
            + explicitStringElement(
                tag: DicomTag.patientName.rawValue,
                vr: "PN",
                value: characterSet.encode(patientName)
            )
        let item = tagData(0xFFFE_E000) + uint32Data(UInt32(record.count)) + record
        let sequence = explicitLongElement(tag: 0x0004_1220, vr: "SQ", value: item)
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)
        data.append(sequence)

        let parsed = try DicomDirectoryReader.read(data: data)

        XCTAssertEqual(parsed.patients.first?.patientName, patientName)
    }

    func testWriterAndReaderRoundTripHierarchy() throws {
        let directory = makeTwoPatientDirectory()

        let data = try DicomDirectoryWriter.part10Data(from: directory)
        XCTAssertEqual(data, try DicomDirectoryWriter.part10Data(from: directory))
        let parsed = try DicomDirectoryReader.read(data: data)

        XCTAssertEqual(parsed, directory)
        XCTAssertEqual(parsed.patients.first?.studies.first?.series.first?.images.first?.referencedFileID, ["IMAGES", "IMG0001"])
    }

    func testWriterPatchesRootAndRecordOffsets() throws {
        let data = try DicomDirectoryWriter.part10Data(from: makeTwoPatientDirectory())
        let items = directoryRecordItems(in: data)

        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(readUL(tag: Tags.offsetOfFirstRootRecord, in: data), UInt32(items[0].itemStart))
        XCTAssertEqual(readUL(tag: Tags.offsetOfLastRootRecord, in: data), UInt32(items[4].itemStart))
        XCTAssertEqual(readUL(tag: Tags.offsetOfNextDirectoryRecord, in: data, range: items[0].range), UInt32(items[4].itemStart))
        XCTAssertEqual(readUL(tag: Tags.offsetOfLowerLevelDirectoryEntity, in: data, range: items[0].range), UInt32(items[1].itemStart))
        XCTAssertEqual(readUL(tag: Tags.offsetOfLowerLevelDirectoryEntity, in: data, range: items[1].range), UInt32(items[2].itemStart))
        XCTAssertEqual(readUL(tag: Tags.offsetOfLowerLevelDirectoryEntity, in: data, range: items[2].range), UInt32(items[3].itemStart))
        XCTAssertEqual(readUL(tag: Tags.offsetOfNextDirectoryRecord, in: data, range: items[3].range), 0)
    }

    func testReferencedFileIDResolutionRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicomdir_media_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = try DicomDirectoryPathResolver.resolve(["IMAGES", "IMG0001"], relativeTo: root)
        XCTAssertEqual(resolved, root.appendingPathComponent("IMAGES").appendingPathComponent("IMG0001").standardizedFileURL)

        XCTAssertThrowsError(try DicomDirectoryPathResolver.resolve(["..", "IMG0001"], relativeTo: root)) { error in
            XCTAssertEqual(error as? DicomDirectoryError, .unsafeReferencedFileID(["..", "IMG0001"]))
        }
        XCTAssertThrowsError(try DicomDirectoryPathResolver.resolve(["IMAGES/IMG0001"], relativeTo: root))
        XCTAssertThrowsError(try DicomDirectoryPathResolver.resolve([], relativeTo: root))
    }

    func testStudyDataServiceLoadsDICOMDirectoryFromMediaRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicomdir_service_\(UUID().uuidString)", isDirectory: true)
        let imageDirectory = root.appendingPathComponent("IMAGES", isDirectory: true)
        let imageURL = imageDirectory.appendingPathComponent("IMG0001", isDirectory: false)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = makeSinglePatientDirectory()
        try DicomDirectoryWriter.write(directory, to: root.appendingPathComponent("DICOMDIR"))

        let service = StudyDataService(decoderFactory: { _ in
            throw DICOMError.invalidDICOMFormat(reason: "DICOMDIR loading should not scan image files")
        })
        let loaded = try service.loadDICOMDirectory(in: root.path)
        let loadedImage = try XCTUnwrap(loaded.patients.first?.studies.first?.series.first?.images.first)

        XCTAssertEqual(loaded, directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try loadedImage.resolvedFileURL(relativeTo: root).path))
    }

    private func makeTwoPatientDirectory() -> DicomDirectory {
        DicomDirectory(fileSetID: "MEDIA1", patients: [
            DicomDirectoryPatient(
                patientID: "P001",
                patientName: "Doe^Jane",
                studies: [
                    DicomDirectoryStudy(
                        studyInstanceUID: "1.2.840.10008.1",
                        studyID: "STUDY1",
                        studyDate: "20260528",
                        series: [
                            DicomDirectorySeries(
                                seriesInstanceUID: "1.2.840.10008.1.1",
                                modality: "CT",
                                seriesNumber: 7,
                                images: [
                                    DicomDirectoryImage(
                                        referencedFileID: ["IMAGES", "IMG0001"],
                                        referencedSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                                        referencedSOPInstanceUID: "1.2.840.10008.1.1.1",
                                        referencedTransferSyntaxUID: DicomTransferSyntax.explicitVRLittleEndian.rawValue,
                                        instanceNumber: 1
                                    )
                                ]
                            )
                        ]
                    )
                ]
            ),
            DicomDirectoryPatient(
                patientID: "P002",
                patientName: "Roe^Richard",
                studies: [
                    DicomDirectoryStudy(
                        studyInstanceUID: "1.2.840.10008.2",
                        studyID: "STUDY2",
                        studyDate: "20260529",
                        series: [
                            DicomDirectorySeries(
                                seriesInstanceUID: "1.2.840.10008.2.1",
                                modality: "MR",
                                seriesNumber: 3,
                                images: [
                                    DicomDirectoryImage(
                                        referencedFileID: ["IMAGES", "IMG0002"],
                                        referencedSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                                        referencedSOPInstanceUID: "1.2.840.10008.2.1.1",
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
    }

    private func makeSinglePatientDirectory() -> DicomDirectory {
        var directory = makeTwoPatientDirectory()
        directory.patients = Array(directory.patients.prefix(1))
        return directory
    }

    private func readUL(tag: Int, in data: Data, range: Range<Int>? = nil) -> UInt32? {
        guard let valueOffset = elementValueOffset(tag: tag, in: data, range: range ?? 0..<data.count) else {
            return nil
        }
        return UInt32(data[valueOffset]) |
            UInt32(data[valueOffset + 1]) << 8 |
            UInt32(data[valueOffset + 2]) << 16 |
            UInt32(data[valueOffset + 3]) << 24
    }

    private func elementValueOffset(tag: Int, in data: Data, range: Range<Int>) -> Int? {
        let group = UInt16((tag >> 16) & 0xFFFF)
        let element = UInt16(tag & 0xFFFF)
        let header = Data([
            UInt8(group & 0x00FF), UInt8(group >> 8),
            UInt8(element & 0x00FF), UInt8(element >> 8),
            0x55, 0x4C, 0x04, 0x00
        ])
        return data[range].range(of: header)?.upperBound
    }

    private func directoryRecordItems(in data: Data) -> [(itemStart: Int, range: Range<Int>)] {
        var items: [(Int, Range<Int>)] = []
        var searchOffset = 0
        let itemTag = Data([0xFE, 0xFF, 0x00, 0xE0])
        while let range = data[searchOffset..<data.count].range(of: itemTag) {
            let itemStart = range.lowerBound
            let lengthOffset = itemStart + 4
            let length = Int(UInt32(data[lengthOffset]) |
                UInt32(data[lengthOffset + 1]) << 8 |
                UInt32(data[lengthOffset + 2]) << 16 |
                UInt32(data[lengthOffset + 3]) << 24)
            let itemEnd = itemStart + 8 + length
            items.append((itemStart, itemStart..<itemEnd))
            searchOffset = itemEnd
        }
        return items
    }

    private func explicitStringElement(tag: Int, vr: String, value: Data) -> Data {
        var padded = value
        if !padded.count.isMultiple(of: 2) {
            padded.append(0x20)
        }
        return tagData(tag) + Data(vr.utf8) + uint16Data(UInt16(padded.count)) + padded
    }

    private func explicitLongElement(tag: Int, vr: String, value: Data) -> Data {
        tagData(tag) + Data(vr.utf8) + Data([0, 0]) + uint32Data(UInt32(value.count)) + value
    }

    private func tagData(_ tag: Int) -> Data {
        uint16Data(UInt16((tag >> 16) & 0xFFFF)) + uint16Data(UInt16(tag & 0xFFFF))
    }

    private func uint16Data(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private func uint32Data(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8(value >> 24)
        ])
    }
}

private enum Tags {
    static let offsetOfFirstRootRecord = 0x00041200
    static let offsetOfLastRootRecord = 0x00041202
    static let offsetOfNextDirectoryRecord = 0x00041400
    static let offsetOfLowerLevelDirectoryEntity = 0x00041420
}
