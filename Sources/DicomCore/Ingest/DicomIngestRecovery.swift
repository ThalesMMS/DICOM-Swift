import Foundation

public struct DicomIngestRecoveryReport: Sendable {
    public enum Action: String, Sendable { case none, discardPartial, rehash, completePublication, register, quarantine }
    public enum Outcome: String, Sendable { case complete, discarded, quarantined, loss, failed }
    public struct Item: Sendable {
        public let ingestID: UUID
        public let action: Action
        public let outcome: Outcome
        public let path: URL?
    }
    public let items: [Item]
}

public enum DicomIngestRecovery {
    public static func replay(journal: any DicomIngestJournaling, fileSystem: any DicomIngestFileSystem,
                              registrar: any DicomIngestRegistrar) async throws -> DicomIngestRecoveryReport {
        await registrar.gate.acquire()
        do {
            let report = try await replayLocked(journal: journal, fileSystem: fileSystem, registrar: registrar)
            await registrar.gate.release()
            return report
        } catch { await registrar.gate.release(); throw error }
    }
    private static func replayLocked(journal: any DicomIngestJournaling, fileSystem: any DicomIngestFileSystem,
                                     registrar: any DicomIngestRegistrar) async throws -> DicomIngestRecoveryReport {
        var latest: [UUID: DicomIngestJournalEntry] = [:]
        for entry in try await journal.replayCandidates() { latest[entry.ingestID] = entry }
        var items: [DicomIngestRecoveryReport.Item] = []
        for id in latest.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            var entry = latest[id]!
            let coordinator = DicomIngestCoordinator(root: entry.root, fileSystem: fileSystem, journal: journal, registrar: registrar)
            var action = DicomIngestRecoveryReport.Action.none
            var outcome = DicomIngestRecoveryReport.Outcome.complete
            do {
                if entry.disposition == .quarantined {
                    action = .quarantine
                    if entry.phase == .intent { try await coordinator.quarantine(&entry) }
                    outcome = .quarantined
                } else if (entry.disposition == .discarded && entry.phase == .done) || (entry.stage == .registered && entry.phase == .done) {
                    outcome = entry.disposition == .discarded ? .discarded : .complete
                } else if entry.promotionCanonical != nil {
                    action = .completePublication
                    _ = try await coordinator.finishPromotion(&entry)
                } else if entry.disposition == .duplicate {
                    guard let path = entry.finalPath else { throw DicomIngestError.invalidJournal }
                    try coordinator.verify(path, entry: entry)
                    if try fileSystem.exists(entry.temporaryPath) { try fileSystem.remove(entry.temporaryPath) }
                    try fileSystem.fsyncDirectory(entry.temporaryPath.deletingLastPathComponent())
                    try await coordinator.mark(&entry, .registered, .done)
                } else if entry.stage == .received || entry.stage == .validated || (entry.stage == .staged && entry.phase == .intent) {
                    action = .discardPartial; entry.disposition = .discarded
                    try await coordinator.mark(&entry, .staged, .intent)
                    if try fileSystem.exists(entry.temporaryPath) {
                        try fileSystem.remove(entry.temporaryPath)
                        try fileSystem.fsyncDirectory(entry.temporaryPath.deletingLastPathComponent())
                    }
                    try await coordinator.mark(&entry, .staged, .done)
                    outcome = .discarded
                } else {
                    action = entry.checksum == nil ? .rehash : entry.stage == .registered ? .register : .completePublication
                    _ = try await coordinator.finish(&entry)
                }
            } catch is DicomIngestCrash { throw DicomIngestCrash() }
            catch DicomIngestError.missingFile { outcome = .loss }
            catch {
                if entry.disposition == .quarantined { action = .quarantine; outcome = .quarantined }
                else { outcome = .failed }
            }
            items.append(.init(ingestID: id, action: action, outcome: outcome, path: entry.finalPath))
        }
        return .init(items: items)
    }
}
