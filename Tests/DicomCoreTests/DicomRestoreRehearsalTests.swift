import Foundation
import XCTest
@testable import DicomCore

final class DicomRestoreRehearsalTests: XCTestCase {
    @MainActor
    func test_nonEmptyDirectory_refusedWithoutRemovingContents() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        do {
            _ = try await DicomRestoreRehearsal().rehearse(inventory: fixture.inventory, from: fixture.destination,
                into: fixture.source.root, removeAfter: true)
            XCTFail("Expected refusal")
        } catch { XCTAssertEqual(error as? DicomStorageProviderError, .destinationExists) }
        XCTAssertTrue(try fixture.fs.exists(fixture.source.root.appendingPathComponent("object0.dcm")))
    }

    @MainActor
    func test_differentSOPInstance_failsWithIdentityReason() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.copy()
        try BackupFixture.part10(sop: "2.25.99999").write(to: fixture.destination.root.appendingPathComponent("object0.dcm"))
        let report = try await DicomRestoreRehearsal().rehearse(inventory: fixture.inventory,
            from: fixture.destination, into: fixture.root.appendingPathComponent("rehearsal"))
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.failed.map(\.objectKey), ["object0.dcm"])
        XCTAssertTrue(report.failed[0].reason.contains("identity"))
    }

    @MainActor
    func test_validRestore_reopensEveryObjectAndOptionalCleanup() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.copy()
        let into = fixture.root.appendingPathComponent("rehearsal")
        let report = try await DicomRestoreRehearsal().rehearse(inventory: fixture.inventory,
            from: fixture.destination, into: into)
        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(report.reopened, 2)
        let ref = fixture.inventory.objects[0].references
        let file = into.appendingPathComponent("\(ref.studyInstanceUID)/\(ref.seriesInstanceUID)/\(ref.sopInstanceUID).dcm")
        XCTAssertEqual(try fixture.fs.checksum(file), fixture.inventory.objects[0].sha256)
        let transient = fixture.root.appendingPathComponent("transient")
        _ = try await DicomRestoreRehearsal().rehearse(inventory: fixture.inventory,
            from: fixture.destination, into: transient, removeAfter: true)
        XCTAssertFalse(try fixture.fs.exists(transient))
    }

    @MainActor
    func test_sameUIDRepresentations_restoreAlongsideOriginal() async throws {
        let fixture = try BackupFixture(count: 1)
        defer { fixture.cleanup() }
        let original = try XCTUnwrap(fixture.inventory.objects.first)
        let file = fixture.source.root.appendingPathComponent(original.sourceLocator)
        let reference = try DicomObjectReference.read(from: file, role: .representation)
        let inventory = DicomBackupInventory(producer: "tests", objects: [original] + ["rep-a", "rep-b"].map {
            .init(objectKey: $0, sourceLocator: original.sourceLocator, byteCount: original.byteCount,
                sha256: original.sha256, references: reference)
        })
        let copied = try await DicomBackupCopier().copy(inventory: inventory, from: fixture.source,
                                                       to: fixture.destination)
        XCTAssertEqual(copied.copied.count, 3)
        XCTAssertTrue(copied.failed.isEmpty)
        let into = fixture.root.appendingPathComponent("rehearsal")
        let report = try await DicomRestoreRehearsal().rehearse(inventory: inventory,
            from: fixture.destination, into: into)
        XCTAssertEqual(report.status, .ok)
        XCTAssertEqual(report.reopened, 3)
        XCTAssertTrue(report.failed.isEmpty)
        let enumeration = try XCTUnwrap(FileManager.default.enumerator(at: into, includingPropertiesForKeys: nil))
        let restored = enumeration.compactMap { $0 as? URL }.filter { $0.pathExtension == "dcm" }
        XCTAssertEqual(restored.count, 3)
        for restoredFile in restored {
            XCTAssertEqual(try Data(contentsOf: restoredFile), try Data(contentsOf: file))
            XCTAssertEqual(try DicomObjectReference.read(from: restoredFile).sopInstanceUID,
                           original.references.sopInstanceUID)
        }
    }
}
