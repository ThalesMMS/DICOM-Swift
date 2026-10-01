import DicomCore
import Foundation
import XCTest
@testable import dicomtool

final class WebConflictRetentionTests: XCTestCase {
    func test_overBudget_evictsOldestKeepsIncomingAndRestartServesOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try WebDirectoryStorage(directory: directory)
        let original = try instance(patientID: "ORIGINAL")
        _ = try await storage.store(instances: [original])
        let conflicts = directory.appendingPathComponent(".conflicts")
        let oldest = try sparseFile(in: conflicts, name: "z-oldest.dcm", created: 1000)
        let newer = try sparseFile(in: conflicts, name: "a-newer.dcm", created: 2000)
        let incoming = try instance(patientID: "CONFLICT")
        let result = try await storage.store(instances: [incoming])
        XCTAssertEqual(result.first?.warningReason, 0xB000)
        XCTAssertNil(result.first?.failureReason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
        let files = try FileManager.default.contentsOfDirectory(at: conflicts, includingPropertiesForKeys: nil)
        let archived = try XCTUnwrap(files.first { $0.lastPathComponent != newer.lastPathComponent })
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try Data(contentsOf: archived), incoming.part10Data)
        let total = try files.reduce(Int64(0)) {
            $0 + (try FileManager.default.attributesOfItem(atPath: $1.path)[.size] as! NSNumber).int64Value
        }
        XCTAssertEqual(total, 300 * 1024 * 1024 + Int64(incoming.part10Data.count))
        XCTAssertLessThanOrEqual(total, DicomConflictRetention.maximumBytes)
        let restarted = try WebDirectoryStorage(directory: directory)
        let recovered = try await restarted.instance(study: "1.2", series: "1.2.3", instance: "1.2.3.4")
        XCTAssertEqual(recovered.part10Data, original.part10Data)
    }

    func test_cleanupFailure_keepsB000AndIncomingBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try WebDirectoryStorage(directory: directory,
            conflictFileSystem: DicomFaultInjectingFileSystem(operation: .remove, fault: .fail(EACCES)))
        _ = try await storage.store(instances: [instance(patientID: "ORIGINAL")])
        let conflicts = directory.appendingPathComponent(".conflicts")
        let oldest = try sparseFile(in: conflicts, name: "oldest.dcm", created: 1000)
        let newer = try sparseFile(in: conflicts, name: "newer.dcm", created: 2000)
        let incoming = try instance(patientID: "CONFLICT")
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://store.test/dicom-web")!),
                                    transport: DicomWebServer(storage: storage))
        let response = try await client.storeInstances([.init(data: incoming.part10Data)])
        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(response.acceptedInstanceCount, 1)
        XCTAssertEqual(response.storeResponse?.instances.first?.warningReason, 0xB000)
        XCTAssertNil(response.storeResponse?.instances.first?.failureReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.path))
        let files = try FileManager.default.contentsOfDirectory(at: conflicts, includingPropertiesForKeys: nil)
        let archived = try XCTUnwrap(files.first { !["oldest.dcm", "newer.dcm"].contains($0.lastPathComponent) })
        XCTAssertEqual(try Data(contentsOf: archived), incoming.part10Data)
    }

    private func instance(patientID: String) throws -> DicomWebStoredInstance {
        let dataset = DicomDataSet(elements: [
            .init(tag: 0x00080016, vr: .UI, value: .strings([DicomStorageSOPClassUIDs.secondaryCaptureImageStorage])),
            .init(tag: 0x00080018, vr: .UI, value: .strings(["1.2.3.4"])),
            .init(tag: 0x0020000D, vr: .UI, value: .strings(["1.2"])),
            .init(tag: 0x0020000E, vr: .UI, value: .strings(["1.2.3"])),
            .init(tag: 0x00100020, vr: .LO, value: .strings([patientID]))
        ])
        return DicomWebStoredInstance(dataSet: dataset, part10Data: try DicomDataSetWriter.part10Data(from: dataset),
            studyInstanceUID: "1.2", seriesInstanceUID: "1.2.3", sopInstanceUID: "1.2.3.4",
            sopClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage)
    }

    private func sparseFile(in directory: URL, name: String, created: TimeInterval) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name)
        try Data().write(to: path)
        // Issue #2530: logical file sizes exercise the real limit without writing hundreds of MiB.
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 300 * 1024 * 1024)
        let date = Date(timeIntervalSince1970: created)
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: path.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.creationDate] as? Date, date)
        return path
    }
}
