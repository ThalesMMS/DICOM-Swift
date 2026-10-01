import Foundation
import XCTest
@testable import DicomCore

final class DicomStorageCommitmentEvidenceTests: XCTestCase {
    func test_evidenceChecksMissingAndChangedFiles_beforeReportingCommitment() async throws {
        let fixture = try IngestFixture()
        defer { fixture.clean() }
        let stored = try await fixture.coordinator.ingest(part10Data: ingestBytes())
        let evidence = DicomIngestCommitmentEvidenceProvider(registrar: fixture.registrar)
        let reference = DicomStorageCommitmentReference(sopClassUID: stored.record.sopClassUID,
            sopInstanceUID: stored.record.sopInstanceUID)
        let report = DicomStorageCommitmentReport(transactionUID: "2.25.2356099", status: .committed, references: [reference])
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "INGEST"), commitmentEvidence: evidence,
                                     commitmentPolicy: .init(required: .publishedAndRegistered))
        let intact = await server.applyingCommitmentEvidence(to: report)
        XCTAssertEqual(intact.status, .committed)
        try ingestBytes(pixel: 9).write(to: stored.record.path)
        let changed = await server.applyingCommitmentEvidence(to: report)
        XCTAssertEqual(changed.status, .failed)
        XCTAssertEqual(changed.references.first?.failureReasonCode, 0x0110)
        try FileManager.default.removeItem(at: stored.record.path)
        let missing = await server.applyingCommitmentEvidence(to: report)
        XCTAssertEqual(missing.references.first?.failureReasonCode, 0x0112)
    }

    func test_retentionRequiresExplicitEvidence_andLegacyIsUnchanged() async throws {
        let reference = DicomStorageCommitmentReference(sopClassUID: "1.2.3", sopInstanceUID: "2.25.1")
        let report = DicomStorageCommitmentReport(transactionUID: "2.25.2", status: .committed, references: [reference])
        for level in [DicomDurabilityLevel.receivedInMemory, .fileSynced, .publishedAndRegistered, .retentionConfirmed] {
            let server = DicomDIMSEServer(configuration: .init(aeTitle: "INGEST"),
                commitmentEvidence: IngestFixedEvidence(level: level))
            let checked = await server.applyingCommitmentEvidence(to: report)
            XCTAssertEqual(checked.status, level == .retentionConfirmed ? .committed : .failed)
        }
        let legacy = DicomDIMSEServer(configuration: .init(aeTitle: "INGEST"))
        let checked = await legacy.applyingCommitmentEvidence(to: report)
        XCTAssertEqual(checked, report)
    }
}

private struct IngestFixedEvidence: DicomCommitmentEvidenceProviding {
    let level: DicomDurabilityLevel
    func evidence(for reference: DicomStorageCommitmentReference) -> DicomCommitmentEvidence {
        .init(filePresent: true, checksumMatchesRecorded: true, registered: true, durability: level)
    }
}
