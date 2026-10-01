import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

final class ArchiveCommandTests: XCTestCase {
    @MainActor
    func test_backupVerifyTamperRehearseEvidenceAndUnauthorizedPlan() async throws {
        defer { fflush(nil) }
        let fs = DicomLocalIngestFileSystem()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let evidenceURL = root.appendingPathComponent("evidence")
        try fs.createDirectory(source)
        defer { try? fs.remove(root) }
        let dataSet = DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 1, count: 12)),
            options: .init(sopInstanceUID: "2.25.235799", studyInstanceUID: "2.25.23572", seriesInstanceUID: "2.25.23573"),
            requiredType2Attributes: .init())
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
        try bytes.write(to: source.appendingPathComponent("object.dcm"))
        var backup = try ArchiveCommand.Backup.parse(["--source-root", source.path, "--destination-root", destination.path,
                                                      "--evidence", evidenceURL.path])
        try await backup.run()
        let inventory = try JSONDecoder().decode(DicomBackupInventory.self,
            from: Data(contentsOf: destination.appendingPathComponent("inventory.json")))
        let store = DicomBackupEvidenceStore(directory: evidenceURL)
        XCTAssertEqual(try store.load(inventoryID: inventory.inventoryID).status, .copied)
        var verify = try ArchiveCommand.VerifyBackup.parse(["--destination-root", destination.path,
            "--evidence", evidenceURL.path, "--inventory-id", inventory.inventoryID])
        try await verify.run()
        XCTAssertEqual(try store.load(inventoryID: inventory.inventoryID).status, .verified)
        var tampered = bytes
        tampered[tampered.count - 1] ^= 1
        try tampered.write(to: destination.appendingPathComponent("object.dcm"))
        do { try await verify.run(); XCTFail("Expected exit 2") }
        catch { XCTAssertEqual(error as? ExitCode, ExitCode(2)) }
        XCTAssertEqual(try store.load(inventoryID: inventory.inventoryID).status, .copied)

        let fresh = root.appendingPathComponent("fresh")
        backup.destinationRoot = fresh.path
        try await backup.run()
        let freshInventory = try JSONDecoder().decode(DicomBackupInventory.self,
            from: Data(contentsOf: fresh.appendingPathComponent("inventory.json")))
        verify.destinationRoot = fresh.path
        verify.inventoryId = freshInventory.inventoryID
        try await verify.run()
        var rehearsal = try ArchiveCommand.Rehearse.parse(["--destination-root", fresh.path, "--evidence", evidenceURL.path,
            "--inventory-id", freshInventory.inventoryID, "--into", root.appendingPathComponent("rehearsal").path])
        try await rehearsal.run()
        var evidence = try ArchiveCommand.Evidence.parse(["--evidence", evidenceURL.path,
                                                         "--inventory-id", freshInventory.inventoryID])
        try evidence.run()
        XCTAssertEqual(try store.load(inventoryID: freshInventory.inventoryID).status, .restoreRehearsed)
        var plan = try ArchiveCommand.Plan.parse(["--root", source.path, "--key", "object.dcm", "--json"])
        try await plan.run()
        let planURL = root.appendingPathComponent("plan.json")
        let input = DicomDestructivePlan(actions: [.init(kind: .delete, objectKey: "object.dcm", providerID: "root",
            locator: "object.dcm", byteCount: Int64(bytes.count), reason: "test", lastVerifiedCopy: false)])
        try JSONEncoder().encode(input).write(to: planURL)
        var execute = try ArchiveCommand.ExecutePlan.parse(["--plan", planURL.path, "--root", source.path])
        do { try await execute.run(); XCTFail("Expected exit 3") }
        catch { XCTAssertEqual(error as? ExitCode, ExitCode(3)) }
        execute.authorize = "explicit-authorization"
        try await execute.run()
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("object.dcm")), bytes)
    }

    func test_packageInspectVerifyExtractAndTamper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("INPUT")
        let dataSet = DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 1, count: 12)),
            options: .init(sopInstanceUID: "2.25.23571", studyInstanceUID: "2.25.23572", seriesInstanceUID: "2.25.23573"),
            requiredType2Attributes: .init())
        try DicomDataSetWriter.part10Data(from: dataSet).write(to: source)
        let zip = root.appendingPathComponent("study.zip")
        var package = try ArchiveCommand.Package.parse([source.path, "--output", zip.path, "--producer", "tests"])
        try package.run()
        var inspect = try ArchiveCommand.Inspect.parse([zip.path, "--json"])
        try inspect.run()
        var verify = try ArchiveCommand.Verify.parse([zip.path])
        XCTAssertNoThrow(try verify.run())
        let output = root.appendingPathComponent("extracted")
        var extract = try ArchiveCommand.Extract.parse([zip.path, "--member", "INPUT", "--output", output.path])
        try extract.run()
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: output.appendingPathComponent("INPUT")))
        var bytes = try Data(contentsOf: zip)
        let original = try Data(contentsOf: source)
        let range = try XCTUnwrap(bytes.range(of: original))
        bytes[range.upperBound - 1] ^= 1
        try bytes.write(to: zip)
        XCTAssertThrowsError(try verify.run()) { XCTAssertEqual($0 as? ExitCode, ExitCode(2)) }
    }
}

extension ArchiveCommandTests {
    @MainActor
    func test_putGetRecallAndResumeRoundTrip() async throws {
        defer { fflush(nil) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileSystem = DicomLocalIngestFileSystem()
        try fileSystem.createDirectory(root)
        defer { try? fileSystem.remove(root) }
        let source = root.appendingPathComponent("input")
        try fileSystem.write(Data("opaque archive package bytes".utf8), to: source, append: false)
        let remote = root.appendingPathComponent("remote")
        let destination = root.appendingPathComponent("cache")
        let journalURL = root.appendingPathComponent("journal")
        for key in ["one", "two"] {
            var put = try ArchiveCommand.Put.parse(["--root", remote.path, "--key", key, source.path])
            try await put.run()
        }
        let output = root.appendingPathComponent("download")
        var get = try ArchiveCommand.Get.parse(["--root", remote.path, "--key", "one", "--output", output.path])
        try await get.run()
        XCTAssertEqual(try fileSystem.checksum(output), try fileSystem.checksum(source))
        var recall = try ArchiveCommand.Recall.parse(["--source-root", remote.path, "--destination-root", destination.path,
                                                     "--journal", journalURL.path, "--key", "one", "two"])
        try await recall.run()
        let journal = DicomTransferJournal(directory: journalURL)
        let manifestURL = try XCTUnwrap(fileSystem.contentsOf(journalURL).first { $0.pathExtension == "json" })
        var manifest = try journal.load(transferID: manifestURL.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(manifest.totals.verifiedItems, 2)
        manifest.items[1].state = .pending
        try journal.save(manifest)
        // Resume verifies the published copy without requiring the source to be reachable.
        try fileSystem.remove(remote)
        var resume = try ArchiveCommand.Resume.parse(["--journal", journalURL.path, "--source-root", remote.path,
                                                     "--destination-root", destination.path])
        try await resume.run()
        XCTAssertEqual(try journal.load(transferID: manifest.transferID).totals.verifiedItems, 2)
        XCTAssertEqual(try fileSystem.checksum(destination.appendingPathComponent("two")), try fileSystem.checksum(source))
    }

    @MainActor
    func test_resumeFailedItemExitsTwo() async throws {
        defer { fflush(nil) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileSystem = DicomLocalIngestFileSystem()
        try fileSystem.createDirectory(root)
        defer { try? fileSystem.remove(root) }
        let journalURL = root.appendingPathComponent("journal")
        let manifest = DicomTransferManifest(sourceProviderID: "source", destinationProviderID: "destination",
            items: [.init(objectKey: "missing", sourceLocator: "missing", destinationLocator: "missing",
                          byteCount: 1, sha256: String(repeating: "0", count: 64))])
        try DicomTransferJournal(directory: journalURL).save(manifest)
        var resume = try ArchiveCommand.Resume.parse(["--journal", journalURL.path,
            "--source-root", root.path, "--destination-root", root.appendingPathComponent("cache").path])
        do { try await resume.run(); XCTFail("Expected failed transfer exit") }
        catch { XCTAssertEqual(error as? ExitCode, ExitCode(2)) }
    }
}
