import Foundation
import XCTest
@testable import DicomCore

/// File-set mechanisms (#2323): leaf record types beyond IMAGE, read diagnostics for corrupt DICOMDIRs, validation
/// of every reference inside the media root, atomic build/update that never touches the sources, cancellation
/// and copy failures without partial artifacts.
final class DicomFileSetTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fileset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    // MARK: - Sources

    private func secondaryCapture(_ instance: Int, series: String = "2.25.232399.2") throws -> URL {
        let dataSet = DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: UInt8(instance), count: 12)),
            options: .init(sopInstanceUID: "2.25.2323990\(instance)", studyInstanceUID: "2.25.232399.1", seriesInstanceUID: series,
                           patientName: "Fileset^Case", patientID: "FS-1", seriesNumber: 1, instanceNumber: instance),
            requiredType2Attributes: .init())
        let url = directory.appendingPathComponent("sc\(instance).dcm")
        try DicomDataSetWriter.part10Data(from: dataSet).write(to: url)
        return url
    }

    private func encapsulatedPDF() throws -> URL {
        let url = directory.appendingPathComponent("doc.dcm")
        try DicomEncapsulatedDocumentBuilder.write(documentData: Data("%PDF-1.4\n%%EOF\n".utf8), to: url, options: .init(
            kind: .pdf, sopInstanceUID: "2.25.23239951", studyInstanceUID: "2.25.232399.1", seriesInstanceUID: "2.25.23239950",
            patientName: "Fileset^Case", patientID: "FS-1", seriesNumber: 9, instanceNumber: 1, documentTitle: "Report"))
        return url
    }

    private func waveform() throws -> URL {
        let url = directory.appendingPathComponent("ecg.dcm")
        let group = DicomWaveformMultiplexGroup(label: "G1", samplingFrequency: 500, sampleInterpretation: .signed16,
                                                channels: [DicomWaveformChannel(number: 1, label: "I", sensitivity: 1, bitsStored: 16, samples: [1, 2, 3, 4])])
        try DicomWaveformBuilder.write(multiplexGroups: [group], to: url, options: .init(
            kind: .twelveLeadECG, sopInstanceUID: "2.25.23239961", studyInstanceUID: "2.25.232399.1", seriesInstanceUID: "2.25.23239960",
            patientName: "Fileset^Case", patientID: "FS-1", seriesNumber: 5, instanceNumber: 1, contentDate: "20260909", contentTime: "120000"))
        return url
    }

    // MARK: - Build, validate, update

    func test_leafRecord_rejectsFileMetaDatasetIdentityMismatches() throws {
        let dataSet = recordSource(sopClass: "1.2.840.10008.5.1.4.1.1.7")
        let meta = try DicomPart10FileMetaParser.parse(DicomDataSetWriter.part10Data(from: dataSet))
        let matching = try DicomFileSet.leafRecord(for: dataSet, fileMeta: meta, fileID: ["MATCH"])
        XCTAssertEqual(matching.referencedSOPClassUID, dataSet.string(for: .sopClassUID))
        XCTAssertEqual(matching.referencedSOPInstanceUID, dataSet.string(for: .sopInstanceUID))
        for tag in [DicomTag.sopClassUID, .sopInstanceUID] {
            var mismatched = dataSet
            mismatched.set(.init(tag: tag.rawValue, vr: .UI, value: .strings(["2.25.2405.999"])))
            XCTAssertThrowsError(try DicomFileSet.leafRecord(for: mismatched, fileMeta: meta, fileID: ["MISMATCH"])) {
                guard case DicomFileSet.Error.inconsistentFileSet(let issues) = $0 else { return XCTFail("\($0)") }
                XCTAssertEqual(issues.map(\.code), [.referenceMismatch])
                XCTAssertEqual(issues.first?.fileID, ["MISMATCH"])
            }
            let absent = DicomDataSet(elements: dataSet.elements.filter { $0.tag != tag.rawValue })
            XCTAssertEqual(try DicomFileSet.leafRecord(for: absent, fileMeta: meta, fileID: ["MATCH"]), matching)
        }
    }

    func test_buildAddAndValidate_rejectFileMetaDatasetIdentityMismatches() async throws {
        let initial = try secondaryCapture(1)
        for (index, tag) in [DicomTag.sopClassUID, .sopInstanceUID].enumerated() {
            let source = try secondaryCapture(index + 2)
            let original = try Data(contentsOf: source)
            let meta = try DicomPart10FileMetaParser.parse(original)
            let built = try await DicomFileSet.build(files: [source], destination: directory.appendingPathComponent("VALID\(index)"), fileSetID: "VALID")
            XCTAssertTrue(try DicomFileSet.validate(directoryFileURL: built.directoryFileURL).isConsistent)
            let leaf = try XCTUnwrap(DicomDirectoryReader.read(from: built.directoryFileURL).patients.first?.studies.first?.series.first?.images.first)
            var dataSet = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: original))
            dataSet.set(.init(tag: tag.rawValue, vr: .UI, value: .strings(["2.25.2405.999"])))
            let mismatched = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
                mediaStorageSOPClassUID: meta.mediaStorageSOPClassUID, mediaStorageSOPInstanceUID: meta.mediaStorageSOPInstanceUID))
            try mismatched.write(to: source)
            try mismatched.write(to: leaf.resolvedFileURL(relativeTo: built.rootURL))
            let report = try DicomFileSet.validate(directoryFileURL: built.directoryFileURL)
            XCTAssertFalse(report.isConsistent)
            XCTAssertEqual(report.issues.map(\.code), [.referenceMismatch])

            let rejected = directory.appendingPathComponent("REJECT\(index)")
            do { _ = try await DicomFileSet.build(files: [source], destination: rejected, fileSetID: "REJECT"); XCTFail("mismatch accepted") }
            catch {
                guard case DicomFileSet.Error.inconsistentFileSet(let issues) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(issues.map(\.code), [.referenceMismatch])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
            let existing = try await DicomFileSet.build(files: [initial], destination: directory.appendingPathComponent("ADD\(index)"), fileSetID: "ADD")
            let before = try Data(contentsOf: existing.directoryFileURL)
            do { _ = try await DicomFileSet.add(files: [source], toFileSetAt: existing.rootURL); XCTFail("mismatch accepted") }
            catch {
                guard case DicomFileSet.Error.inconsistentFileSet(let issues) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(issues.map(\.code), [.referenceMismatch])
            }
            XCTAssertEqual(try Data(contentsOf: existing.directoryFileURL), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.rootURL.appendingPathComponent("IMAGES").path), ["I0000001"])
            XCTAssertEqual(try Data(contentsOf: source), mismatched, "source is never modified")
        }
    }

    func test_buildAndValidate_acceptFileMetaLargerThanFourKiB() async throws {
        let source = try secondaryCapture(1)
        var data = try Data(contentsOf: source)
        let meta = try DicomPart10FileMetaParser.parse(data)
        let extra = Data([2, 0, 2, 1, 0x4F, 0x42, 0, 0, 0x88, 0x13, 0, 0]) + Data(count: 5000)
        data.insert(contentsOf: extra, at: meta.dataSetOffset)
        withUnsafeBytes(of: UInt32(meta.dataSetOffset - 144 + extra.count).littleEndian) {
            data.replaceSubrange(140..<144, with: $0)
        }
        try data.write(to: source)
        XCTAssertGreaterThan(try DicomPart10FileMetaParser.parse(data).dataSetOffset, 4096)
        let result = try await DicomFileSet.build(files: [source], destination: directory.appendingPathComponent("LARGEMETA"), fileSetID: "META")
        XCTAssertTrue(try DicomFileSet.validate(directoryFileURL: result.directoryFileURL).isConsistent)
    }

    func test_recordProfilesAndExporter_acceptOnlyTheDeclaredSOPClasses() async throws {
        XCTAssertEqual(DicomFileSet.recordProfile(forSOPClassUID: "1.2.840.10008.5.1.4.1.1.66.1")?.recordType, "REGISTRATION")
        XCTAssertEqual(DicomFileSet.recordProfile(forSOPClassUID: "1.2.840.10008.5.1.4.1.1.66.5")?.recordType, "SURFACE")
        XCTAssertEqual(DicomFileSetExporter.supportedSOPClassUIDs, DicomFileSet.supportedSOPClassUIDs)
        let unsupported = ["1.2.840.10008.5.1.4.1.1.999", "1.2.840.10008.5.1.4.1.1.88.999", "1.2.840.10008.5.1.4.1.1.66.2"]
        for (index, uid) in (DicomFileSetExporter.supportedSOPClassUIDs.sorted() + unsupported).enumerated() {
            let source = directory.appendingPathComponent("profile\(index).dcm")
            try DicomDataSetWriter.part10Data(from: recordSource(sopClass: uid)).write(to: source)
            let destination = directory.appendingPathComponent("profile\(index).zip")
            if unsupported.contains(uid) {
                XCTAssertNil(DicomFileSet.recordProfile(forSOPClassUID: uid))
                do { _ = try await DicomFileSetExporter().export(files: [source], to: destination); XCTFail("unsupported SOP accepted") }
                catch { XCTAssertEqual(error as? DicomFileSetExporter.ExportError, .unsupportedSOPClass(file: source.lastPathComponent, uid: uid)) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            } else {
                XCTAssertNotNil(DicomFileSet.recordProfile(forSOPClassUID: uid))
                do {
                    let result = try await DicomFileSetExporter().export(files: [source], to: destination)
                    XCTAssertEqual(result.instanceCount, 1, uid)
                } catch { XCTFail("\(uid): \(error)") }
            }
        }
    }

    func test_recordKeys_enforceTypeOneConditionalAndTypeTwoPresence() async throws {
        let cases = [("9.1.1", 0x00080023, 0x00080023), ("481.3", 0x30060008, 0x30060008),
                     ("88.22", 0x0040A030, 0x0040A073), ("11.1", 0x00081115, 0x00081115),
                     ("11.4", 0x00700402, 0x00700402), ("104.2", 0x0040E001, 0x0040E001)]
        for (index, testCase) in cases.enumerated() {
            let (suffix, tag, sourceTag) = testCase
            let dataSet = recordSource(sopClass: "1.2.840.10008.5.1.4.1.1." + suffix)
            let meta = try DicomPart10FileMetaParser.parse(DicomDataSetWriter.part10Data(from: dataSet))
            let missing = DicomDataSet(elements: dataSet.elements.filter { $0.tag != sourceTag })
            XCTAssertThrowsError(try DicomFileSet.leafRecord(for: missing, fileMeta: meta, fileID: ["TEST"])) {
                guard case DicomFileSet.Error.inconsistentFileSet(let issues) = $0 else { return XCTFail("\($0)") }
                XCTAssertTrue(issues.contains { $0.code == .missingRecordKey && $0.detail == String(format: "%08X", tag) })
            }
            let source = directory.appendingPathComponent("keys\(index).dcm")
            try DicomDataSetWriter.part10Data(from: dataSet).write(to: source)
            let built = try await DicomFileSet.build(files: [source], destination: directory.appendingPathComponent("KEYS\(index)"), fileSetID: "KEYS")
            var records = try DicomDirectoryReader.read(from: built.directoryFileURL)
            records.patients[0].studies[0].series[0].images[0].keys.removeAll { $0.tag == tag }
            try DicomDirectoryWriter.write(records, to: built.directoryFileURL)
            let report = try DicomFileSet.validate(directoryFileURL: built.directoryFileURL)
            XCTAssertFalse(report.isConsistent)
            XCTAssertTrue(report.issues.contains { $0.code == .missingRecordKey && $0.detail == String(format: "%08X", tag) })
        }
    }

    func test_srRecord_selectsLatestVerificationAcrossOffsetsAndPrecision() throws {
        let cases: [([String], String?, String?)] = [
            (["20260913100000-0300", "20260913110000+0000"], nil, "20260913100000-0300"),
            (["20260913100000", "20260913110000+0000"], "-0300", "20260913100000-0300"),
            (["20260913100000.000002", "20260913100000.000001"], nil, "20260913100000.000002"),
            (["202609", "20260831120000"], nil, "202609"),
            (["20260913100000"], "", "20260913100000"),
            (["20260913100000", "20260913110000+0000"], nil, nil)
        ]
        for (dates, offset, expected) in cases {
            var dataSet = recordSource(sopClass: "1.2.840.10008.5.1.4.1.1.88.22")
            dataSet.set(.init(tag: 0x0040A073, vr: .SQ, value: .sequence(dates.map { date in
                .init(dataSet: .init(elements: [.init(tag: 0x0040A030, vr: .DT, value: .strings([date]))]))
            })))
            if let offset { dataSet.set(.init(tag: 0x00080201, vr: .SH, value: .strings([offset]))) }
            let meta = try DicomPart10FileMetaParser.parse(DicomDataSetWriter.part10Data(from: dataSet))
            if let expected {
                let record = try DicomFileSet.leafRecord(for: dataSet, fileMeta: meta, fileID: ["SR"])
                XCTAssertEqual(DicomDataSet(elements: record.keys).string(for: 0x0040A030), expected)
            } else {
                XCTAssertThrowsError(try DicomFileSet.leafRecord(for: dataSet, fileMeta: meta, fileID: ["SR"]))
            }
        }
    }

    private func recordSource(sopClass: String) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            .init(tag: 0x00080016, vr: .UI, value: .strings([sopClass])),
            .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.2405.100"])),
            .init(tag: 0x00100020, vr: .LO, value: .strings(["FILESET"])),
            .init(tag: 0x00100010, vr: .PN, value: .strings(["Fileset^Case"])),
            .init(tag: 0x0020000D, vr: .UI, value: .strings(["2.25.2405.101"])),
            .init(tag: 0x0020000E, vr: .UI, value: .strings(["2.25.2405.102"])),
            .init(tag: 0x00080060, vr: .CS, value: .strings(["OT"])),
            .init(tag: 0x00200011, vr: .IS, value: .strings(["1"])),
            .init(tag: 0x00200013, vr: .IS, value: .strings(["1"])),
            .init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: 0x00280011, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: 0x00280002, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: 0x00280004, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: 0x00280100, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: 0x00280101, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: 0x00280102, vr: .US, value: .unsignedIntegers([7])),
            .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([1, 0]))),
            .init(tag: 0x00700080, vr: .CS, value: .strings(["CONTENT"])),
            .init(tag: 0x00700081, vr: .LO, value: .empty),
            .init(tag: 0x00700084, vr: .PN, value: .empty),
            .init(tag: 0x3004000A, vr: .CS, value: .strings(["PLAN"])),
            .init(tag: 0x30060002, vr: .SH, value: .strings(["STRUCT"])),
            .init(tag: 0x300A0002, vr: .SH, value: .strings(["PLAN"])),
            .init(tag: 0x0040A491, vr: .CS, value: .strings(["COMPLETE"])),
            .init(tag: 0x0040A493, vr: .CS, value: .strings(["VERIFIED"])),
            .init(tag: 0x00420010, vr: .ST, value: .empty),
            .init(tag: 0x00420012, vr: .LO, value: .strings(["application/pdf"])),
            .init(tag: 0x0040E001, vr: .ST, value: .strings(["2.25.2405.103"]))
        ]
        for tag in [0x00080023, 0x00700082] { elements.append(.init(tag: tag, vr: .DA, value: .strings(["20260913"]))) }
        for tag in [0x00080033, 0x00700083] { elements.append(.init(tag: tag, vr: .TM, value: .strings(["120000"]))) }
        for (tag, vr) in [(0x30060008, DicomVR.DA), (0x30060009, .TM), (0x300A0006, .DA), (0x300A0007, .TM)] {
            elements.append(.init(tag: tag, vr: vr, value: .empty))
        }
        for tag in [0x00081115, 0x00700402, 0x0040A043] {
            elements.append(.init(tag: tag, vr: .SQ, value: .sequence([.init(dataSet: .init())])))
        }
        elements.append(.init(tag: 0x0040A073, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
            .init(tag: 0x0040A030, vr: .DT, value: .strings(["20260913120000"]))
        ]))])))
        return .init(elements: elements)
    }

    func test_build_publishesEveryRecordTypeAtomicallyAndValidates() async throws {
        let sources = [try secondaryCapture(1), try secondaryCapture(2), try encapsulatedPDF(), try waveform()]
        let originals = try sources.map { try Data(contentsOf: $0) }
        let destination = directory.appendingPathComponent("MEDIA", isDirectory: true)
        let result = try await DicomFileSet.build(files: sources, destination: destination, fileSetID: "ISIS_TEST")
        XCTAssertEqual(result.instanceCount, 4)
        XCTAssertEqual(result.recordTypes, ["IMAGE": 2, "ENCAP DOC": 1, "WAVEFORM": 1])
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, originals, "sources are never modified")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".MEDIA.partial") }, "staging removed")
        let report = try DicomFileSet.validate(directoryFileURL: result.directoryFileURL)
        XCTAssertTrue(report.isConsistent, "\(report.issues)")
        XCTAssertEqual(report.referencedInstanceCount, 4)
        let read = try DicomDirectoryReader.readWithDiagnostics(from: result.directoryFileURL)
        XCTAssertTrue(read.isStructurallyConsistent, "\(read.diagnostics)")
        let leaves = read.directory.patients.flatMap { $0.studies.flatMap { $0.series.flatMap(\.images) } }
        XCTAssertEqual(Set(leaves.map(\.recordType)), ["IMAGE", "ENCAP DOC", "WAVEFORM"])
        let document = try XCTUnwrap(leaves.first { $0.recordType == "ENCAP DOC" })
        XCTAssertEqual(document.referencedFileID, ["DOCS", "D0000001"])
        XCTAssertEqual(document.keys.first { $0.tag == 0x00420010 }?.stringValue, "Report")
        XCTAssertEqual(document.keys.first { $0.tag == 0x00420012 }?.stringValue, "application/pdf")
        let ecg = try XCTUnwrap(leaves.first { $0.recordType == "WAVEFORM" })
        XCTAssertEqual(ecg.keys.map(\.tag), [0x00080023, 0x00080033])
        // Every leaf resolves inside the root to the referenced instance.
        for leaf in leaves {
            let url = try leaf.resolvedFileURL(relativeTo: destination)
            let meta = try DicomPart10FileMetaParser.parse(try Data(contentsOf: url))
            XCTAssertEqual(meta.mediaStorageSOPInstanceUID, leaf.referencedSOPInstanceUID)
        }
        // Update: add another instance, DICOMDIR swapped atomically, references still consistent.
        let more = try secondaryCapture(3)
        let updated = try await DicomFileSet.add(files: [more], toFileSetAt: destination)
        XCTAssertEqual(updated.instanceCount, 5)
        let leavesAfter = try DicomDirectoryReader.read(from: result.directoryFileURL).patients.flatMap { $0.studies.flatMap { $0.series.flatMap(\.images) } }
        XCTAssertEqual(leavesAfter.filter { $0.recordType == "IMAGE" }.map(\.referencedFileID), [["IMAGES", "I0000001"], ["IMAGES", "I0000002"], ["IMAGES", "I0000003"]])
        XCTAssertTrue(try DicomFileSet.validate(directoryFileURL: result.directoryFileURL).isConsistent)
        // A duplicate instance is refused and leaves the file-set untouched.
        let before = try Data(contentsOf: result.directoryFileURL)
        do { _ = try await DicomFileSet.add(files: [more], toFileSetAt: destination); XCTFail("duplicate accepted") } catch {
            XCTAssertEqual(error as? DicomFileSet.Error, .duplicateSOPInstanceUID("2.25.23239903"))
        }
        XCTAssertEqual(try Data(contentsOf: result.directoryFileURL), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path).contains { $0.hasPrefix(".staging") })
    }

    func test_leafCharacterSetAndNonASCIIKey_surviveDirectoryRewrite() async throws {
        let source = try encapsulatedPDF()
        var dataSet = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: Data(contentsOf: source)))
        dataSet.set(.init(tag: 0x00080005, vr: .CS, value: .strings(["ISO_IR 192"])))
        dataSet.set(.init(tag: 0x00420010, vr: .ST, value: .strings(["Lésion"])))
        try DicomDataSetWriter.part10Data(from: dataSet).write(to: source)
        let result = try await DicomFileSet.build(files: [source], destination: directory.appendingPathComponent("UTF8"), fileSetID: "UTF8")
        let original = try DicomDirectoryReader.read(from: result.directoryFileURL)
        let rewritten = try DicomDirectoryReader.read(data: DicomDirectoryWriter.part10Data(from: original))
        for value in [original, rewritten] {
            let leaf = try XCTUnwrap(value.patients.first?.studies.first?.series.first?.images.first)
            XCTAssertEqual(leaf.keys.first { $0.tag == 0x00080005 }?.stringValue, "ISO_IR 192")
            XCTAssertEqual(leaf.keys.first { $0.tag == 0x00420010 }?.stringValue, "Lésion")
        }
    }

    func test_build_refusesSymbolicLinksNonPart10AndExistingDestinations() async throws {
        let source = try secondaryCapture(1)
        let link = directory.appendingPathComponent("link.dcm")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let destination = directory.appendingPathComponent("OUT", isDirectory: true)
        do { _ = try await DicomFileSet.build(files: [link], destination: destination, fileSetID: "X"); XCTFail() } catch {
            XCTAssertEqual(error as? DicomFileSet.Error, .sourceIsSymbolicLink("link.dcm"))
        }
        let text = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        do { _ = try await DicomFileSet.build(files: [text], destination: destination, fileSetID: "X"); XCTFail() } catch {
            XCTAssertEqual(error as? DicomFileSet.Error, .sourceIsNotPart10("notes.txt"))
        }
        do { _ = try await DicomFileSet.build(files: [source], destination: destination, fileSetID: "bad id!"); XCTFail() } catch {
            XCTAssertEqual(error as? DicomFileSet.Error, .invalidFileSetID("bad id!"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        _ = try await DicomFileSet.build(files: [source], destination: destination, fileSetID: "X")
        do { _ = try await DicomFileSet.build(files: [source], destination: destination, fileSetID: "X"); XCTFail() } catch {
            XCTAssertEqual(error as? DicomFileSet.Error, .destinationExists(destination.path))
        }
    }

    func test_build_cancellationAndCopyFailureLeaveNoArtifact() async throws {
        let sources = [try secondaryCapture(1), try secondaryCapture(2)]
        let destination = directory.appendingPathComponent("CANCELLED", isDirectory: true)
        let task = Task { try await DicomFileSet.build(files: sources, destination: destination, fileSetID: "X") }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation must propagate") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".CANCELLED") })
        let failing = FailingCopyFileManager()
        let broken = directory.appendingPathComponent("BROKEN", isDirectory: true)
        do { _ = try await DicomFileSet.build(files: sources, destination: broken, fileSetID: "X", fileManager: failing); XCTFail() } catch {
            XCTAssertEqual((error as NSError).domain, "DicomFileSetTests.disk")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".BROKEN") })
        XCTAssertTrue(sources.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: - Corrupt or inconsistent DICOMDIRs

    private func fileSet() async throws -> DicomFileSet.BuildResult {
        try await DicomFileSet.build(files: [try secondaryCapture(1), try secondaryCapture(2)], destination: directory.appendingPathComponent("SET", isDirectory: true), fileSetID: "SET")
    }

    private func patched(_ data: Data, tag: Int, occurrence: Int = 0, value: UInt32) -> Data {
        var data = data
        let header = Data([UInt8(tag >> 16 & 0xFF), UInt8(tag >> 24), UInt8(tag & 0xFF), UInt8(tag >> 8 & 0xFF), 0x55, 0x4C, 0x04, 0x00])
        var search = data.startIndex, found = 0
        while let range = data[search...].range(of: header) {
            if found == occurrence {
                withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(range.upperBound..<range.upperBound + 4, with: $0) }
                return data
            }
            found += 1; search = range.upperBound
        }
        XCTFail("tag not found"); return data
    }

    func test_readDiagnostics_reportCyclesDanglingOffsetsAndInactiveRecords() async throws {
        let built = try await fileSet()
        let data = try Data(contentsOf: built.directoryFileURL)
        let firstItem = try XCTUnwrap(data.range(of: Data([0xFE, 0xFF, 0x00, 0xE0]))).lowerBound
        // The first PATIENT record's next offset points at itself.
        let cyclic = try DicomDirectoryReader.readWithDiagnostics(data: patched(data, tag: 0x00041400, value: UInt32(firstItem)))
        XCTAssertEqual(cyclic.diagnostics.map(\.code), [.cycleDetected])
        XCTAssertEqual(cyclic.directory.patients.count, 1)
        // The PATIENT record's lower offset points into the middle of nowhere.
        let dangling = try DicomDirectoryReader.readWithDiagnostics(data: patched(data, tag: 0x00041420, value: 7))
        XCTAssertEqual(dangling.diagnostics.map(\.code), [.danglingOffset])
        XCTAssertEqual(dangling.directory.patients.first?.studies.count, 0)
        // No root offset: sequential fallback is reported, not silent.
        let noRoot = try DicomDirectoryReader.readWithDiagnostics(data: patched(data, tag: 0x00041200, value: 0))
        XCTAssertEqual(noRoot.diagnostics.map(\.code), [.sequentialFallback])
        XCTAssertEqual(noRoot.directory.patients.first?.studies.first?.series.first?.images.count, 2)
        // An inactive record is reported by the validator as a structural issue.
        var inactive = data
        // Record In-use Flag (0004,1410) US, Explicit VR Little Endian header.
        let flagRange = try XCTUnwrap(inactive.range(of: Data([0x04, 0x00, 0x10, 0x14, 0x55, 0x53, 0x02, 0x00])))
        inactive.replaceSubrange(flagRange.upperBound..<flagRange.upperBound + 2, with: [0, 0])
        try inactive.write(to: built.directoryFileURL)
        let report = try DicomFileSet.validate(directoryFileURL: built.directoryFileURL)
        XCTAssertEqual(report.issues.map(\.code), [.structural])
        XCTAssertFalse(report.isConsistent)
    }

    func test_validate_reportsMissingMismatchedDuplicateAndEscapingReferences() async throws {
        let built = try await fileSet()
        let root = built.rootURL
        var directory = try DicomDirectoryReader.read(from: built.directoryFileURL)
        // Remove one referenced file, point another at a foreign instance, duplicate a UID, and add an escaping File ID.
        try FileManager.default.removeItem(at: root.appendingPathComponent("IMAGES/I0000002"))
        let foreign = try secondaryCapture(7, series: "2.25.9")
        try FileManager.default.copyItem(at: foreign, to: root.appendingPathComponent("IMAGES/I0000009"))
        try FileManager.default.copyItem(at: foreign, to: root.appendingPathComponent("IMAGES/STRAY"))
        var images = directory.patients[0].studies[0].series[0].images
        images[0].referencedFileID = ["IMAGES", "I0000009"]
        images.append(DicomDirectoryImage(referencedFileID: ["..", "sc1"], referencedSOPClassUID: images[0].referencedSOPClassUID,
                                          referencedSOPInstanceUID: images[0].referencedSOPInstanceUID, recordType: "IMAGE"))
        images.append(DicomDirectoryImage(referencedFileID: ["IMAGES", "toolongname9"], referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.7",
                                          referencedSOPInstanceUID: "2.25.1", recordType: "IMAGE"))
        images.append(DicomDirectoryImage(referencedFileID: ["IMAGES", "I0000001"], referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.7",
                                          referencedSOPInstanceUID: "2.25.23239901", recordType: "PRESENTATION"))
        directory.patients[0].studies[0].series[0].images = images
        try DicomDirectoryWriter.write(directory, to: built.directoryFileURL)
        let report = try DicomFileSet.validate(directoryFileURL: built.directoryFileURL)
        XCTAssertFalse(report.isConsistent)
        XCTAssertEqual(Set(report.issues.map(\.code)), [.referenceMismatch, .referencedFileMissing, .duplicateSOPInstanceUID, .referenceEscapesRoot, .invalidFileID, .unsupportedRecordType, .missingRecordKey, .unreferencedFile])
        XCTAssertTrue(report.issues.contains { $0.code == .referenceEscapesRoot && $0.fileID == ["..", "sc1"] })
        XCTAssertTrue(report.issues.contains { $0.code == .unreferencedFile })
        // A symbolic link in place of a referenced file is refused.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("IMAGES/I0000002"), withDestinationURL: foreign)
        XCTAssertTrue(try DicomFileSet.validate(directoryFileURL: built.directoryFileURL).issues.contains { $0.code == .referencedFileIsSymbolicLink })
    }

    func test_exporter_acceptsEveryRecordTypeTheFileSetKnows() async throws {
        let archive = directory.appendingPathComponent("export.zip")
        let result = try await DicomFileSetExporter().export(files: [try secondaryCapture(1), try encapsulatedPDF(), try waveform()], to: archive, fileSetID: "EXP")
        XCTAssertEqual(result.instanceCount, 3)
    }

    private final class FailingCopyFileManager: FileManager, @unchecked Sendable {
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            throw NSError(domain: "DicomFileSetTests.disk", code: 28)
        }
    }

    func test_add_rejectsInconsistentDirectoryBeforePublishing() async throws {
        let built = try await fileSet()
        try FileManager.default.removeItem(at: built.rootURL.appendingPathComponent("IMAGES/I0000001"))
        let before = try Data(contentsOf: built.directoryFileURL)
        do {
            _ = try await DicomFileSet.add(files: [try secondaryCapture(3)], toFileSetAt: built.rootURL)
            XCTFail("inconsistent file-set accepted")
        } catch { XCTAssertTrue(error is DicomFileSet.Error) }
        XCTAssertEqual(try Data(contentsOf: built.directoryFileURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: built.rootURL.appendingPathComponent("IMAGES/I0000003").path))
    }

    func test_add_rejectsIntermediateSymlinkAndValidationReportsEscape() async throws {
        let built = try await fileSet()
        let outside = directory.appendingPathComponent("OUTSIDE")
        let images = built.rootURL.appendingPathComponent("IMAGES")
        try FileManager.default.moveItem(at: images, to: outside)
        try FileManager.default.createSymbolicLink(at: images, withDestinationURL: outside)
        let before = try Data(contentsOf: built.directoryFileURL)
        XCTAssertTrue(try DicomFileSet.validate(directoryFileURL: built.directoryFileURL).issues.contains { $0.code == .referenceEscapesRoot })
        do {
            _ = try await DicomFileSet.add(files: [try secondaryCapture(3)], toFileSetAt: built.rootURL)
            XCTFail("escaping destination accepted")
        } catch { XCTAssertTrue(error is DicomFileSet.Error) }
        XCTAssertEqual(try Data(contentsOf: built.directoryFileURL), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted(), ["I0000001", "I0000002"])
    }

    func test_add_rollsBackPublishedFilesOnMoveOrSwapFailure() async throws {
        let built = try await fileSet()
        let before = try Data(contentsOf: built.directoryFileURL)
        let sources = [try encapsulatedPDF(), try secondaryCapture(3)]
        for failsSwap in [false, true] {
            let failing = FailingPublishFileManager(failsSwap: failsSwap)
            do {
                _ = try await DicomFileSet.add(files: sources, toFileSetAt: built.rootURL, fileManager: failing)
                XCTFail("publication failure ignored")
            } catch { XCTAssertEqual((error as NSError).domain, "DicomFileSetTests.disk") }
            XCTAssertEqual(try Data(contentsOf: built.directoryFileURL), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: built.rootURL.path).sorted(), ["DICOMDIR", "IMAGES"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: built.rootURL.appendingPathComponent("IMAGES").path).sorted(), ["I0000001", "I0000002"])
            XCTAssertTrue(try DicomFileSet.validate(directoryFileURL: built.directoryFileURL).isConsistent)
        }
    }

    func test_validate_requiresAllReferencedIdentifiers() async throws {
        let built = try await fileSet()
        let original = try DicomDirectoryReader.read(from: built.directoryFileURL)
        for keyPath in [\DicomDirectoryImage.referencedSOPInstanceUID, \.referencedSOPClassUID, \.referencedTransferSyntaxUID] {
            var directory = original
            directory.patients[0].studies[0].series[0].images[0][keyPath: keyPath] = nil
            try DicomDirectoryWriter.write(directory, to: built.directoryFileURL)
            let report = try DicomFileSet.validate(directoryFileURL: built.directoryFileURL)
            XCTAssertFalse(report.isConsistent)
            XCTAssertEqual(report.issues.map(\.code), [.missingRecordKey])
        }
    }

    private final class FailingPublishFileManager: FileManager, @unchecked Sendable {
        let failsSwap: Bool
        var moves = 0

        init(failsSwap: Bool) { self.failsSwap = failsSwap; super.init() }

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            moves += 1
            if !failsSwap, moves == 2 { throw NSError(domain: "DicomFileSetTests.disk", code: 28) }
            try super.moveItem(at: srcURL, to: dstURL)
        }

        override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL, backupItemName: String?,
                                  options: FileManager.ItemReplacementOptions, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
            throw NSError(domain: "DicomFileSetTests.disk", code: 28)
        }
    }
}
