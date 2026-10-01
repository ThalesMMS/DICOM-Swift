import Foundation
import XCTest
@testable import DicomCore

struct BackupFixture: Sendable {
    let root: URL
    let source: DicomLocalDiskProvider
    let destination: DicomLocalDiskProvider
    let inventory: DicomBackupInventory
    let fs = DicomLocalIngestFileSystem()
    init(count: Int = 2) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = .init(id: "source", root: root.appendingPathComponent("source"))
        destination = .init(id: "destination", root: root.appendingPathComponent("destination"))
        try fs.createDirectory(source.root)
        try fs.createDirectory(destination.root)
        var objects: [DicomBackupInventory.Object] = []
        for index in 0..<count {
            let key = "object\(index).dcm"
            let file = source.root.appendingPathComponent(key)
            let data = try Self.part10(sop: "2.25.2357\(index)")
            try data.write(to: file)
            objects.append(.init(objectKey: key, sourceLocator: key, byteCount: Int64(data.count),
                sha256: try fs.checksum(file), references: try DicomObjectReference.read(from: file)))
        }
        inventory = .init(producer: "tests", objects: objects)
    }
    static func part10(sop: String) throws -> Data {
        let dataSet = DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 1, count: 12)),
            options: .init(sopInstanceUID: sop, studyInstanceUID: "2.25.23571", seriesInstanceUID: "2.25.23572"),
            requiredType2Attributes: .init())
        return try DicomDataSetWriter.part10Data(from: dataSet)
    }
    func cleanup() { try? fs.remove(root) }
    func copy() async throws -> DicomBackupCopier.CopyReport {
        try await DicomBackupCopier().copy(inventory: inventory, from: source, to: destination)
    }
    func verify() async throws -> DicomBackupVerifier.VerifyReport {
        try await DicomBackupVerifier().verify(inventory: inventory, at: destination,
                                             scratch: root.appendingPathComponent("scratch"))
    }
}

final class DicomBackupCopierVerifierTests: XCTestCase {
    @MainActor
    func test_copyAndIndependentVerification_allObjectsAndInventoryPublished() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let copy = try await fixture.copy()
        XCTAssertEqual(copy.copied.count, 2)
        XCTAssertTrue(copy.failed.isEmpty)
        let stored = try Data(contentsOf: fixture.destination.root.appendingPathComponent("inventory.json"))
        XCTAssertEqual(stored, try fixture.inventory.encode())
        let report = try await fixture.verify()
        XCTAssertEqual(report.status, .verified)
        XCTAssertEqual(report.verifiedObjects, 2)
        XCTAssertEqual(try fixture.fs.contentsOf(fixture.root.appendingPathComponent("scratch")).count, 0)
    }

    @MainActor
    func test_sourceChangedAfterInventory_copyReportsIntegrityFailure() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        try Data("changed".utf8).write(to: fixture.source.root.appendingPathComponent("object0.dcm"))
        let report = try await fixture.copy()
        XCTAssertEqual(report.failed.map(\.objectKey), ["object0.dcm"])
        XCTAssertTrue(report.failed[0].reason.contains("integrity"))
        XCTAssertFalse(try fixture.fs.exists(fixture.destination.root.appendingPathComponent("object0.dcm")))
    }

    @MainActor
    func test_cancelledCopy_leavesNoPartial() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        do {
            _ = try await DicomBackupCopier().copy(inventory: fixture.inventory, from: fixture.source,
                to: fixture.destination, isCancelled: { true })
            XCTFail("Expected cancellation")
        } catch { XCTAssertEqual(error as? DicomStorageProviderError, .cancelled) }
        XCTAssertTrue(try fixture.fs.contentsOf(fixture.destination.root).isEmpty)
    }

    @MainActor
    func test_cancellationDuringDestinationWrite_removesPartial() async throws {
        let fixture = try BackupFixture(count: 1)
        defer { fixture.cleanup() }
        let cancellation = BackupCancellation()
        let provider = DicomLocalDiskProvider(id: "destination", root: fixture.destination.root,
            fileSystem: CancellingBackupFileSystem(cancellation: cancellation))
        do {
            _ = try await DicomBackupCopier().copy(inventory: fixture.inventory, from: fixture.source,
                to: provider, isCancelled: { cancellation.value })
            XCTFail("Expected cancellation during publication")
        } catch { XCTAssertEqual(error as? DicomStorageProviderError, .cancelled) }
        XCTAssertTrue(cancellation.value)
        XCTAssertTrue(try fixture.fs.contentsOf(fixture.destination.root).isEmpty)
    }

    @MainActor
    func test_tamperedMissingAndExtraObjects_verificationFails() async throws {
        let fixture = try BackupFixture(count: 3)
        defer { fixture.cleanup() }
        _ = try await fixture.copy()
        let file = fixture.destination.root.appendingPathComponent("object0.dcm")
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: file)
        try fixture.fs.remove(fixture.destination.root.appendingPathComponent("object1.dcm"))
        try Data("extra".utf8).write(to: fixture.destination.root.appendingPathComponent("extra"))
        let report = try await fixture.verify()
        XCTAssertEqual(report.mismatched, ["object0.dcm"])
        XCTAssertEqual(report.missing, ["object1.dcm"])
        XCTAssertEqual(report.unexpected, ["extra"])
        XCTAssertEqual(report.verifiedObjects, 1)
        XCTAssertEqual(report.status, .failed)
        var evidence = DicomBackupEvidence(inventoryID: fixture.inventory.inventoryID, destinationProviderID: "destination")
        XCTAssertThrowsError(try evidence.recordVerified(report: report))
    }

    @MainActor
    func test_missingInventory_verificationFails() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.copy()
        try fixture.fs.remove(fixture.destination.root.appendingPathComponent(DicomBackupInventory.fileName))
        let report = try await fixture.verify()
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.missing, [DicomBackupInventory.fileName])
        XCTAssertTrue(report.mismatched.isEmpty)
        XCTAssertEqual(report.verifiedObjects, fixture.inventory.objects.count)
    }

    @MainActor
    func test_tamperedInventory_verificationRevokesEvidence() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        var evidence = DicomBackupEvidence(inventoryID: fixture.inventory.inventoryID,
            destinationProviderID: fixture.destination.id)
        try evidence.recordCopied(report: await fixture.copy())
        try evidence.recordVerified(report: await fixture.verify())
        let inventoryURL = fixture.destination.root.appendingPathComponent(DicomBackupInventory.fileName)
        var bytes = try Data(contentsOf: inventoryURL)
        let producer = try XCTUnwrap(bytes.range(of: Data("tests".utf8)))
        bytes.replaceSubrange(producer, with: Data("other".utf8))
        try bytes.write(to: inventoryURL)
        let report = try await fixture.verify()
        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.mismatched, [DicomBackupInventory.fileName])
        XCTAssertTrue(report.missing.isEmpty)
        XCTAssertEqual(report.verifiedObjects, fixture.inventory.objects.count)
        XCTAssertThrowsError(try evidence.recordVerified(report: report))
        XCTAssertEqual(evidence.status, .copied)
        XCTAssertNil(evidence.verified)
    }

    @MainActor
    func test_lateSourceArrival_isExcludedFromSnapshot() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        try Data("late".utf8).write(to: fixture.source.root.appendingPathComponent("late"))
        let report = try await fixture.copy()
        XCTAssertEqual(report.copied.count, 2)
        let late = try await fixture.destination.head("late")
        XCTAssertNil(late)
    }

    func test_inventoryEncoding_isDeterministic() throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let other = DicomBackupInventory(inventoryID: fixture.inventory.inventoryID,
            createdAt: fixture.inventory.createdAt, producer: "tests", objects: fixture.inventory.objects.reversed())
        XCTAssertEqual(try other.encode(), try fixture.inventory.encode())
        XCTAssertEqual(try other.inventorySHA256, try fixture.inventory.inventorySHA256)
    }

    @MainActor
    func test_A1PackageProvider_verifiesAndRehearsesMembers() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let package = fixture.root.appendingPathComponent("study.zip")
        _ = try DicomStudyPackageWriter().write(members: fixture.inventory.objects.map {
            .init(sourceURL: fixture.source.root.appendingPathComponent($0.objectKey), relativePath: $0.objectKey)
        }, to: package, producer: "tests", includeDICOMDIR: false)
        let provider = try DicomStudyPackageBackupProvider(id: "package", url: package)
        let verified = try await DicomBackupVerifier().verify(inventory: fixture.inventory, at: provider,
                                                             scratch: fixture.root)
        // The package manifest does not replace the captured backup inventory.
        XCTAssertEqual(verified.status, .failed)
        XCTAssertEqual(verified.missing, [DicomBackupInventory.fileName])
        XCTAssertEqual(verified.verifiedObjects, 2)
        let rehearsal = try await DicomRestoreRehearsal().rehearse(inventory: fixture.inventory, from: provider,
            into: fixture.root.appendingPathComponent("restored"))
        XCTAssertEqual(rehearsal.reopened, 2)
        XCTAssertEqual(rehearsal.status, .ok)
    }
}

private final class BackupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
}

private struct CancellingBackupFileSystem: DicomIngestFileSystem {
    let cancellation: BackupCancellation
    private let base = DicomLocalIngestFileSystem()
    func createDirectory(_ path: URL) throws { try base.createDirectory(path) }
    func write(_ data: Data, to path: URL, append: Bool) throws {
        try base.write(data, to: path, append: append)
        if append { cancellation.cancel() }
    }
    func fsyncFile(_ path: URL) throws { try base.fsyncFile(path) }
    func fsyncDirectory(_ path: URL) throws { try base.fsyncDirectory(path) }
    func rename(_ source: URL, to destination: URL) throws { try base.rename(source, to: destination) }
    func remove(_ path: URL) throws { try base.remove(path) }
    func exists(_ path: URL) throws -> Bool { try base.exists(path) }
    func read(_ path: URL) throws -> Data { try base.read(path) }
    func contentsOf(_ directory: URL) throws -> [URL] { try base.contentsOf(directory) }
    func readChunks(_ path: URL, consume: (Data) throws -> Void) throws { try base.readChunks(path, consume: consume) }
}

extension DicomBackupCopierVerifierTests {
    @MainActor
    func test_copyRetryAcceptsIdenticalObjectsAndInventory() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.copy()
        let retry = try await fixture.copy()
        XCTAssertTrue(retry.failed.isEmpty)
        XCTAssertEqual(retry.copied.count, 2)
        var evidence = DicomBackupEvidence(inventoryID: fixture.inventory.inventoryID, destinationProviderID: "destination")
        XCTAssertNoThrow(try evidence.recordCopied(report: retry))
        try Data("conflict".utf8).write(to: fixture.destination.root.appendingPathComponent("object0.dcm"))
        let conflicting = try await fixture.copy()
        XCTAssertEqual(conflicting.failed.map(\.objectKey), ["object0.dcm"])
        XCTAssertEqual(try Data(contentsOf: fixture.destination.root.appendingPathComponent("object0.dcm")), Data("conflict".utf8))
        try Data("different inventory".utf8).write(to: fixture.destination.root.appendingPathComponent("inventory.json"))
        await storageError(.integrity("inventory.json")) { _ = try await fixture.copy() }
    }
}
