import Foundation
import XCTest
@testable import DicomCore

final class DicomBackupEvidenceTests: XCTestCase {
    @MainActor
    func test_independentMarks_requireAllLowerMarks() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let copied = try await fixture.copy()
        let verified = try await fixture.verify()
        let rehearsed = try await DicomRestoreRehearsal().rehearse(inventory: fixture.inventory,
            from: fixture.destination, into: fixture.root.appendingPathComponent("rehearsal"))
        var evidence = DicomBackupEvidence(inventoryID: fixture.inventory.inventoryID, destinationProviderID: "destination")
        XCTAssertEqual(evidence.status, .none)
        try evidence.recordVerified(report: verified)
        XCTAssertEqual(evidence.status, .inconsistent)
        try evidence.recordCopied(report: copied)
        XCTAssertEqual(evidence.status, .verified)
        try evidence.recordRehearsed(report: rehearsed)
        XCTAssertEqual(evidence.status, .restoreRehearsed)
        var onlyRehearsed = DicomBackupEvidence(inventoryID: fixture.inventory.inventoryID, destinationProviderID: "destination")
        try onlyRehearsed.recordRehearsed(report: rehearsed)
        XCTAssertEqual(onlyRehearsed.status, .inconsistent)
        try onlyRehearsed.recordCopied(report: copied)
        XCTAssertEqual(onlyRehearsed.status, .inconsistent)
    }

    @MainActor
    func test_failedVerification_invalidatesHigherMarksAndPersists() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        var evidence = DicomBackupEvidence(inventoryID: fixture.inventory.inventoryID, destinationProviderID: "destination")
        try evidence.recordCopied(report: await fixture.copy())
        try evidence.recordVerified(report: await fixture.verify())
        let store = DicomBackupEvidenceStore(directory: fixture.root.appendingPathComponent("evidence"))
        try store.save(evidence)
        try fixture.fs.remove(fixture.destination.root.appendingPathComponent("object0.dcm"))
        let failed = try await fixture.verify()
        XCTAssertThrowsError(try evidence.recordVerified(report: failed))
        XCTAssertEqual(evidence.status, .copied)
        try store.save(evidence)
        XCTAssertEqual(try store.load(inventoryID: fixture.inventory.inventoryID), evidence)
        XCTAssertEqual(try fixture.fs.contentsOf(store.directory).count, 1)
    }

    @MainActor
    func test_reportForDifferentInventory_cannotEarnMark() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        let report = try await fixture.copy()
        var evidence = DicomBackupEvidence(inventoryID: UUID().uuidString, destinationProviderID: "destination")
        XCTAssertThrowsError(try evidence.recordCopied(report: report))
        XCTAssertEqual(evidence.status, .none)
    }

    @MainActor
    func test_incompleteCopy_cannotEarnCopied() async throws {
        let fixture = try BackupFixture()
        defer { fixture.cleanup() }
        try Data().write(to: fixture.source.root.appendingPathComponent("object0.dcm"))
        let report = try await fixture.copy()
        var evidence = DicomBackupEvidence(inventoryID: fixture.inventory.inventoryID, destinationProviderID: "destination")
        XCTAssertThrowsError(try evidence.recordCopied(report: report))
    }
}
