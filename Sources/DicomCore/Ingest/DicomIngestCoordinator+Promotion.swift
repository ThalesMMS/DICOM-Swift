import Foundation

public extension DicomIngestRecord {
    // issue #2532: slot identity and path stay stable while the two stored byte versions trade places.
    func replacingContent(with other: DicomIngestRecord) -> Self {
        .init(ingestID: ingestID, sopClassUID: other.sopClassUID, sopInstanceUID: sopInstanceUID,
              transferSyntaxUID: other.transferSyntaxUID, path: path,
              contentSHA256: other.contentSHA256, isConflict: isConflict)
    }
}

public extension DicomIngestCoordinator {
    // issue #2532: promotion is an explicit ingest transaction, never a new arrival classified by hash.
    func promoteConflict(at path: URL, replacing canonicalPath: URL) async throws -> DicomIngestResult {
        // issue #2532: an adapter without atomic receipt replacement must refuse before exchanging files.
        guard registrar.supportsPromotion else { throw DicomIngestError.invalidJournal }
        await registrar.gate.acquire()
        do {
            try await completePendingPromotions()
            // issue #2532: directory enumeration and persisted receipts may spell the same file as /var or /private/var.
            let conflictLocation = path.standardizedFileURL.resolvingSymlinksInPath()
            let canonicalLocation = canonicalPath.standardizedFileURL.resolvingSymlinksInPath()
            let rootLocation = root.standardizedFileURL.resolvingSymlinksInPath()
            let metadata = try await DicomIngestMetadata.read(at: path)
            let original = try await DicomIngestMetadata.read(at: canonicalPath)
            guard metadata.studyInstanceUID == original.studyInstanceUID,
                  metadata.seriesInstanceUID == original.seriesInstanceUID,
                  metadata.sopInstanceUID == original.sopInstanceUID,
                  metadata.sopClassUID == original.sopClassUID,
                  conflictLocation.deletingLastPathComponent().path == rootLocation.appendingPathComponent(".conflicts").path,
                  canonicalLocation.deletingLastPathComponent().path == rootLocation.path else {
                throw DicomIngestError.invalidIdentity
            }
            let records = try await registrar.records(sopInstanceUID: metadata.sopInstanceUID)
            guard let canonical = records.first(where: {
                !$0.isConflict && $0.path.standardizedFileURL.resolvingSymlinksInPath() == canonicalLocation
            }), let conflict = records.first(where: {
                $0.isConflict && $0.path.standardizedFileURL.resolvingSymlinksInPath() == conflictLocation
            }),
                  canonical.contentSHA256 != conflict.contentSHA256 else { throw DicomIngestError.invalidIdentity }
            guard try fileSystem.checksum(path) == conflict.contentSHA256,
                  try fileSystem.checksum(canonicalPath) == canonical.contentSHA256 else {
                throw DicomIngestError.contentChanged
            }
            try Task.checkCancellation()
            var entry = DicomIngestJournalEntry(root: root)
            entry.promotionCanonical = canonical
            entry.promotionConflict = conflict
            entry.sopInstanceUID = canonical.sopInstanceUID
            entry.sopClassUID = conflict.sopClassUID
            entry.transferSyntaxUID = conflict.transferSyntaxUID
            entry.finalPath = canonical.path
            entry.checksum = conflict.contentSHA256
            await registrar.gate.beginPromotion()
            try await mark(&entry, .published, .intent)
            let result = try await finishPromotion(&entry)
            await registrar.gate.release()
            return result
        } catch { await registrar.gate.release(); throw error }
    }
}

extension DicomIngestCoordinator {
    // issue #2532: settle an interrupted swap before another arrival can classify against stale receipts.
    func completePendingPromotions() async throws {
        // issue #2532: normal imports must not rescan a lifetime of settled journal history.
        guard await registrar.gate.hasPendingPromotion else { return }
        var latest: [UUID: DicomIngestJournalEntry] = [:]
        for entry in try await journal.replayCandidates() where entry.promotionCanonical != nil {
            latest[entry.ingestID] = entry
        }
        for var entry in latest.values where !(entry.stage == .registered && entry.phase == .done) {
            _ = try await finishPromotion(&entry)
        }
        await registrar.gate.endPromotion()
    }

    func finishPromotion(_ entry: inout DicomIngestJournalEntry) async throws -> DicomIngestResult {
        guard let canonical = entry.promotionCanonical, let conflict = entry.promotionConflict else {
            throw DicomIngestError.invalidJournal
        }
        let current = try fileSystem.checksum(canonical.path)
        let retained = try fileSystem.checksum(conflict.path)
        if current == canonical.contentSHA256, retained == conflict.contentSHA256 {
            try fileSystem.exchange(canonical.path, conflict.path)
        } else if current != conflict.contentSHA256 || retained != canonical.contentSHA256 {
            throw DicomIngestError.contentChanged
        }
        // issue #2532: hash orientation makes replay idempotent even if the process died inside exchange.
        try fileSystem.synchronize(files: [canonical.path, conflict.path], directories: [
            canonical.path.deletingLastPathComponent(), conflict.path.deletingLastPathComponent()
        ])
        try await journal.append(contentsOf: [checkpoint(&entry, .published, .done),
                                              checkpoint(&entry, .registered, .intent)])
        try await registrar.promote(canonical: canonical, conflict: conflict)
        try await mark(&entry, .registered, .done)
        await registrar.gate.endPromotion()
        DicomConflictRetention.enforce(in: conflict.path.deletingLastPathComponent(),
                                      preserving: [conflict.path], fileSystem: fileSystem)
        return .init(record: canonical.replacingContent(with: conflict), classification: .new, durability: achieved)
    }
}
