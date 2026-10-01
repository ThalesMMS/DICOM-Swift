import Foundation

public struct DicomCommitmentEvidence: Sendable {
    public let filePresent: Bool
    public let checksumMatchesRecorded: Bool
    public let registered: Bool
    public let durability: DicomDurabilityLevel
    public init(filePresent: Bool, checksumMatchesRecorded: Bool, registered: Bool, durability: DicomDurabilityLevel) {
        self.filePresent = filePresent; self.checksumMatchesRecorded = checksumMatchesRecorded
        self.registered = registered; self.durability = durability
    }
    public func failureReason(policy: DicomDurabilityPolicy) -> Int? {
        if !filePresent || !registered { return 0x0112 }
        if !checksumMatchesRecorded || durability < policy.required { return 0x0110 }
        return nil
    }
}

public protocol DicomCommitmentEvidenceProviding: Sendable {
    func evidence(for reference: DicomStorageCommitmentReference) async throws -> DicomCommitmentEvidence
}

public struct DicomIngestCommitmentEvidenceProvider: DicomCommitmentEvidenceProviding {
    public let registrar: any DicomIngestRegistrar
    public let fileSystem: any DicomIngestFileSystem
    public init(registrar: any DicomIngestRegistrar, fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) {
        self.registrar = registrar; self.fileSystem = fileSystem
    }
    public func evidence(for reference: DicomStorageCommitmentReference) async throws -> DicomCommitmentEvidence {
        guard let record = try await registrar.records(sopInstanceUID: reference.sopInstanceUID).first(where: {
            $0.sopClassUID == reference.sopClassUID && $0.sopInstanceUID == reference.sopInstanceUID && !$0.isConflict
        }) else { return .init(filePresent: false, checksumMatchesRecorded: false, registered: false, durability: .receivedInMemory) }
        let present = try fileSystem.exists(record.path)
        let matches = present && !record.contentSHA256.isEmpty && (try? fileSystem.checksum(record.path)) == record.contentSHA256
        return .init(filePresent: present, checksumMatchesRecorded: matches, registered: true, durability: registrar.durability)
    }
}
