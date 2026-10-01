import Foundation
import CryptoKit
import Darwin
import HL7v2

/// A reused MSH-10 with different raw bytes is a different message, not a duplicate.
public struct MLLPMessageKey: Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let sendingApplication: String
    public let sendingFacility: String
    public let controlID: String
    public let payloadSHA256: String
    public init(message: HL7Message, raw: Data) {
        let fields = raw.prefix { $0 != 13 }.split(separator: raw.count > 3 ? raw[raw.startIndex + 3] : 124, omittingEmptySubsequences: false)
        sendingApplication = fields.count > 2 ? Data(fields[2]).base64EncodedString() : ""
        sendingFacility = fields.count > 3 ? Data(fields[3]).base64EncodedString() : ""
        controlID = message.controlID ?? ""
        payloadSHA256 = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }
    public var description: String { "MLLPMessageKey(redacted)" }
    public var debugDescription: String { description }
}

public enum MLLPLedgerDecision: Sendable, Equatable {
    case process
    /// Replay the stored outcome with the complete MLLP frame. Empty data means the ACK was suppressed by policy.
    case duplicateAlreadyAcked(ack: Data, outcome: MLLPProcessingOutcome)
    case duplicateInProgress
}

/// Each transition must be atomic and durable before returning. Never send an ACK before recordOutcome.
/// A begun entry without an outcome requires host reconciliation; it must not be silently reclaimed.
public protocol MLLPInboundLedger: Sendable {
    func begin(key: MLLPMessageKey) async throws -> MLLPLedgerDecision
    func recordOutcome(key: MLLPMessageKey, outcome: MLLPProcessingOutcome, ackBytes: Data) async throws
    func recover() async throws -> [MLLPMessageKey]
    func markAckSent(key: MLLPMessageKey) async throws
}

public enum MLLPLedgerError: Error { case invalidTransition, corruptJournal, storageFailure }

/// In-memory transitions, optionally backed by an fsynced JSONL journal. The journal is sensitive state,
/// not a diagnostic log: it contains replayable ACKs. Cooperating instances use an advisory file lock.
public actor MLLPInMemoryLedger: MLLPInboundLedger {
    private struct Outcome: Codable {
        let kind: String
        var code: String?
        var text: String?
        var findings: [[String: String]]?
        init(_ outcome: MLLPProcessingOutcome) {
            kind = outcome.description
            switch outcome {
            case .accepted: break
            case .rejectedApplication(let code, let text): self.code = code; self.text = text
            case .error(let text), .uncertain(let text): self.text = text
            case .rejectedStructure(let findings):
                self.findings = findings.map {
                    ["code": $0.code.rawValue, "path": $0.path.description,
                     "severity": String(describing: $0.severity), "detail": $0.detail,
                     "segmentOccurrence": String($0.segmentOccurrence)]
                }
            }
        }
        func processingOutcome() throws -> MLLPProcessingOutcome {
            switch kind {
            case "accepted": return .accepted
            case "rejectedApplication":
                guard let code, let text else { throw MLLPLedgerError.corruptJournal }
                return .rejectedApplication(code: code, text: text)
            case "error":
                guard let text else { throw MLLPLedgerError.corruptJournal }
                return .error(text: text)
            case "uncertain":
                guard let text else { throw MLLPLedgerError.corruptJournal }
                return .uncertain(reason: text)
            case "rejectedStructure":
                guard let findings else { throw MLLPLedgerError.corruptJournal }
                return .rejectedStructure(try findings.map { finding in
                    guard let rawCode = finding["code"], let code = HL7ValidationFinding.Code(rawValue: rawCode),
                          let rawPath = finding["path"], let path = rawPath == "message" ? HL7Path() : HL7Path(rawPath),
                          let rawSeverity = finding["severity"], let severity = HL7Diagnostic.Severity(rawValue: rawSeverity),
                          let detail = finding["detail"], let occurrence = finding["segmentOccurrence"].flatMap({ Int($0) }) else {
                        throw MLLPLedgerError.corruptJournal
                    }
                    return .init(code: code, path: path, severity: severity, detail: detail, segmentOccurrence: occurrence)
                })
            default: throw MLLPLedgerError.corruptJournal
            }
        }
    }
    private struct Entry: Codable {
        let key: MLLPMessageKey
        var outcome: Outcome?
        var ack: Data?
        var sent = false
    }
    private var entries: [MLLPMessageKey: Entry] = [:]
    private let journal: URL?
    private var journalState: stat?
    public init() { journal = nil }
    fileprivate init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        journal = directory.appendingPathComponent("inbound.jsonl")
    }
    private func transaction<T>(_ action: () throws -> T) throws -> T {
        guard let journal else { return try action() }
        let fd = open(journal.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw MLLPLedgerError.storageFailure }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw MLLPLedgerError.storageFailure }
        defer { flock(fd, LOCK_UN) }
        do {
            var current = stat()
            guard fstat(fd, &current) == 0 else { throw MLLPLedgerError.storageFailure }
            let previous = journalState
            let unchanged = previous.map {
                $0.st_mtimespec.tv_sec == current.st_mtimespec.tv_sec &&
                $0.st_mtimespec.tv_nsec == current.st_mtimespec.tv_nsec &&
                $0.st_ctimespec.tv_sec == current.st_ctimespec.tv_sec &&
                $0.st_ctimespec.tv_nsec == current.st_ctimespec.tv_nsec
            } ?? false
            let appendOnly = previous.map {
                $0.st_dev == current.st_dev && $0.st_ino == current.st_ino &&
                (current.st_size > $0.st_size || (current.st_size == $0.st_size && unchanged))
            } ?? false
            let offset = appendOnly ? previous!.st_size : 0
            if !appendOnly { entries.removeAll() }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.seek(toOffset: UInt64(offset))
            let bytes = try handle.readToEnd() ?? Data()
            let complete = bytes.lastIndex(of: 10).map { $0 + 1 } ?? 0
            for line in bytes.prefix(complete).split(separator: 10) {
                guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line)) else {
                    throw MLLPLedgerError.corruptJournal
                }
                entries[entry.key] = entry
            }
            // Cooperating writers only append. Replacement, truncation and same-size rewrites reload the cache.
            // A torn final append never authorizes processing or sending an ACK.
            if complete < bytes.count {
                guard ftruncate(fd, offset + off_t(complete)) == 0, fsync(fd) == 0 else {
                    throw MLLPLedgerError.storageFailure
                }
            }
            let result = try action()
            guard fstat(fd, &current) == 0 else { throw MLLPLedgerError.storageFailure }
            journalState = current
            return result
        } catch {
            journalState = nil
            throw error
        }
    }
    private func persist(_ entry: Entry) throws {
        if let journal {
            let handle = try FileHandle(forWritingTo: journal)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            var bytes = try JSONEncoder().encode(entry); bytes.append(10)
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
        }
        entries[entry.key] = entry
    }
    public func begin(key: MLLPMessageKey) throws -> MLLPLedgerDecision {
        try transaction {
            if let entry = entries[key] {
                guard let ack = entry.ack else { return .duplicateInProgress }
                guard let outcome = entry.outcome else { throw MLLPLedgerError.corruptJournal }
                return .duplicateAlreadyAcked(ack: ack, outcome: try outcome.processingOutcome())
            }
            try persist(Entry(key: key))
            return .process
        }
    }
    public func recordOutcome(key: MLLPMessageKey, outcome: MLLPProcessingOutcome, ackBytes: Data) throws {
        try transaction {
            guard var entry = entries[key], entry.outcome == nil else { throw MLLPLedgerError.invalidTransition }
            entry.outcome = Outcome(outcome); entry.ack = ackBytes
            try persist(entry)
        }
    }
    public func recover() throws -> [MLLPMessageKey] {
        try transaction { entries.values.filter { $0.outcome != nil && !$0.sent }.map(\.key) }
    }
    public func markAckSent(key: MLLPMessageKey) throws {
        try transaction {
            guard var entry = entries[key], entry.outcome != nil else { throw MLLPLedgerError.invalidTransition }
            entry.sent = true
            try persist(entry)
        }
    }
}

public struct MLLPJSONLLedger: MLLPInboundLedger {
    private let store: MLLPInMemoryLedger
    public init(directory: URL) throws { store = try MLLPInMemoryLedger(directory: directory) }
    public func begin(key: MLLPMessageKey) async throws -> MLLPLedgerDecision { try await store.begin(key: key) }
    public func recordOutcome(key: MLLPMessageKey, outcome: MLLPProcessingOutcome, ackBytes: Data) async throws {
        try await store.recordOutcome(key: key, outcome: outcome, ackBytes: ackBytes)
    }
    public func recover() async throws -> [MLLPMessageKey] { try await store.recover() }
    public func markAckSent(key: MLLPMessageKey) async throws { try await store.markAckSent(key: key) }
}
