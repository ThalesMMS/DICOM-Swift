import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DicomDeliveryOutboxError: Error, Equatable {
    case duplicateIdempotencyKey, duplicateDeliveryID, missingDelivery, invalidTransition, invalidItem, corruptJournal
}

/// Hosts must make each operation atomic and durable before returning. Enqueue is all-or-nothing.
/// Lease increments attempts, excludes live leases, and reserves destination slots atomically.
/// A routine row waiting > 10 times the oldest STAT wait precedes STAT. Otherwise statShare is
/// a percentage carried across lease calls, including calls requesting only one row.
/// settle fences stale workers using the unique lease owner. Completion and partial retry insertion
/// must commit together. This is at-least-once delivery; peers must deduplicate idempotency keys.
public protocol DicomDeliveryOutboxStoring: Sendable {
    func enqueue(_ items: [DicomDeliveryItem]) async throws
    func lease(max: Int, owner: String, now: Date, leaseSeconds: TimeInterval, statShare: Int) async throws
        -> [DicomDeliveryItem]
    func lease(max: Int, owner: String, now: Date, leaseSeconds: TimeInterval, statShare: Int,
               destinationSlots: [String: Int]) async throws -> [DicomDeliveryItem]
    func complete(deliveryID: String, receipt: DicomDeliveryReceipt) async throws
    func fail(deliveryID: String, errorClass: DicomDeliveryErrorClass, message: String, retryAt: Date?) async throws
    func markUncertain(deliveryID: String, message: String) async throws
    func cancel(deliveryID: String) async throws
    func requeueDeadLetter(deliveryID: String, now: Date) async throws
    func releaseExpiredLeases(now: Date) async throws
    func isDelivered(destinationID: String, idempotencyKey: String) async throws -> Bool
    func fetch(states: Set<DicomDeliveryState>) async throws -> [DicomDeliveryItem]
    func counts() async throws -> [DicomDeliveryState: Int]
    func settle(deliveryID: String, leaseOwner: String, settlement: DicomDeliverySettlement) async throws
}

public enum DicomDeliverySettlement: Sendable {
    case complete(DicomDeliveryReceipt, retry: DicomDeliveryItem?)
    case fail(DicomDeliveryErrorClass, String, retryAt: Date?)
    case cancel
    /// Same terminal cancellation, with a durable policy reason; error classes are unchanged.
    case cancelWithReason(String)
}

/// An optional journal backs the same transition logic used by the in-memory implementation.
/// Each JSONL record contains the changed rows and scheduler cursor. A partial final line is ignored
/// on replay and separated before the next append. A failed write poisons this instance: reopen it.
public actor DicomInMemoryDeliveryOutbox: DicomDeliveryOutboxStoring {
    private struct Record: Codable {
        var rows: [DicomDeliveryItem]
        var cursor: Int
    }
    private var rows: [String: DicomDeliveryItem] = [:]
    private var cursor = 99
    private let journal: URL?
    private let fileSystem: any DicomIngestFileSystem
    private var poisoned = false

    public init() {
        journal = nil
        fileSystem = DicomLocalIngestFileSystem()
    }

    public init(directory: URL, fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) throws {
        self.fileSystem = fileSystem
        journal = directory.appendingPathComponent("delivery.jsonl")
        try fileSystem.createDirectory(directory)
        let path = directory.appendingPathComponent("delivery.jsonl")
        let lock = try DicomDeliveryJournalLock(path: path)
        defer { lock.unlock() }
        (rows, cursor) = try Self.replay(path: path, fileSystem: fileSystem)
    }

    private static func replay(path: URL, fileSystem: any DicomIngestFileSystem) throws
        -> ([String: DicomDeliveryItem], Int) {
        var rows: [String: DicomDeliveryItem] = [:]
        var cursor = 99
        if try fileSystem.exists(path) {
            let bytes = try fileSystem.read(path)
            let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
            let recovery = Data("{\"deliveryRecovery\":true}".utf8)
            for (index, line) in lines.dropLast().enumerated() where !line.isEmpty {
                if Data(line) == recovery { continue }
                guard let record = try? JSONDecoder().decode(Record.self, from: Data(line)) else {
                    guard index + 1 < lines.count, Data(lines[index + 1]) == recovery else {
                        throw DicomDeliveryOutboxError.corruptJournal
                    }
                    continue
                }
                for row in record.rows { rows[row.deliveryID] = row }
                cursor = record.cursor
            }
            if let tail = lines.last, !tail.isEmpty {
                if let record = try? JSONDecoder().decode(Record.self, from: Data(tail)) {
                    for row in record.rows { rows[row.deliveryID] = row }
                    cursor = record.cursor
                    try fileSystem.write(Data([10]), to: path, append: true)
                } else {
                    // A marker commits the decision to discard this torn final append, without rewriting history.
                    var marker = Data([10])
                    marker.append(recovery)
                    marker.append(10)
                    try fileSystem.write(marker, to: path, append: true)
                }
                try fileSystem.fsyncFile(path)
            }
        } else {
            try fileSystem.write(Data(), to: path, append: false)
            try fileSystem.fsyncFile(path)
            try fileSystem.fsyncDirectory(path.deletingLastPathComponent())
        }
        return (rows, cursor)
    }

    private func transaction() throws -> DicomDeliveryJournalLock? {
        guard !poisoned else { throw DicomDeliveryOutboxError.corruptJournal }
        guard let journal else { return nil }
        let lock = try DicomDeliveryJournalLock(path: journal)
        do {
            (rows, cursor) = try Self.replay(path: journal, fileSystem: fileSystem)
            let size = try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size >= 1024 * 1024 {
                var snapshot = try JSONEncoder().encode(Record(rows: rows.values.sorted { $0.deliveryID < $1.deliveryID }, cursor: cursor))
                snapshot.append(10)
                if size / 4 > snapshot.count {
                    let temporary = journal.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".snapshot")
                    defer { try? fileSystem.remove(temporary) }
                    try fileSystem.write(snapshot, to: temporary, append: false)
                    try fileSystem.fsyncFile(temporary)
                    #if canImport(Darwin)
                    let result = Darwin.rename(temporary.path, journal.path)
                    #else
                    let result = Glibc.rename(temporary.path, journal.path)
                    #endif
                    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    try fileSystem.fsyncDirectory(journal.deletingLastPathComponent())
                }
            }
        }
        catch { lock.unlock(); throw error }
        return lock
    }

    private func persist(_ changed: [DicomDeliveryItem], cursor nextCursor: Int? = nil) throws {
        guard !poisoned else { throw DicomDeliveryOutboxError.corruptJournal }
        if let journal {
            do {
                var bytes = try JSONEncoder().encode(Record(rows: changed, cursor: nextCursor ?? cursor))
                bytes.append(10)
                try fileSystem.write(bytes, to: journal, append: true)
                try fileSystem.fsyncFile(journal)
            } catch {
                poisoned = true
                throw error
            }
        }
        for row in changed { rows[row.deliveryID] = row }
        if let nextCursor { cursor = nextCursor }
    }

    private func validate(_ items: [DicomDeliveryItem]) throws {
        var ids = Set(rows.keys)
        var keys = Set(rows.values.map { [$0.destinationID, $0.idempotencyKey] })
        for item in items {
            guard !item.deliveryID.isEmpty, !item.destinationID.isEmpty, !item.idempotencyKey.isEmpty,
                  item.byteCount >= 0, item.attempts >= 0 else { throw DicomDeliveryOutboxError.invalidItem }
            guard ids.insert(item.deliveryID).inserted else { throw DicomDeliveryOutboxError.duplicateDeliveryID }
            guard keys.insert([item.destinationID, item.idempotencyKey]).inserted else {
                throw DicomDeliveryOutboxError.duplicateIdempotencyKey
            }
        }
    }

    public func enqueue(_ items: [DicomDeliveryItem]) throws {
        let lock = try transaction()
        defer { lock?.unlock() }
        try validate(items)
        try persist(items)
    }

    public func lease(max: Int, owner: String, now: Date, leaseSeconds: TimeInterval,
                      statShare: Int) throws -> [DicomDeliveryItem] {
        let lock = try transaction()
        defer { lock?.unlock() }
        return try select(max: max, owner: owner, now: now, leaseSeconds: leaseSeconds, statShare: statShare,
                  destinationSlots: Dictionary(uniqueKeysWithValues: Set(rows.values.map(\.destinationID)).map {
                    ($0, max)
                  }))
    }

    public func lease(max limit: Int, owner: String, now: Date, leaseSeconds: TimeInterval,
                      statShare: Int, destinationSlots: [String: Int]) throws -> [DicomDeliveryItem] {
        let lock = try transaction()
        defer { lock?.unlock() }
        return try select(max: limit, owner: owner, now: now, leaseSeconds: leaseSeconds,
                          statShare: statShare, destinationSlots: destinationSlots)
    }

    private func select(max limit: Int, owner: String, now: Date, leaseSeconds: TimeInterval,
                        statShare: Int, destinationSlots: [String: Int]) throws -> [DicomDeliveryItem] {
        guard limit > 0, leaseSeconds.isFinite, leaseSeconds > 0 else { return [] }
        let live = rows.values.filter { $0.state == .leased && ($0.leaseUntil ?? .distantPast) > now }
        let available = Swift.max(0, limit - live.count)
        var slots = destinationSlots
        for row in live { slots[row.destinationID, default: 0] -= 1 }
        var due = rows.values.filter {
            [.pending, .retryWait, .uncertain].contains($0.state) && $0.nextAttemptAt <= now
        }.sorted { ($0.createdAt, $0.deliveryID) < ($1.createdAt, $1.deliveryID) }
        var chosen: [DicomDeliveryItem] = []
        var nextCursor = cursor
        while chosen.count < available {
            due.removeAll { slots[$0.destinationID, default: 0] <= 0 }
            guard !due.isEmpty else { break }
            let stat = due.firstIndex { $0.priority == .stat }
            let routine = due.firstIndex { $0.priority == .routine }
            let index: Int
            if let stat, let routine {
                let aged = now.timeIntervalSince(due[routine].createdAt) >
                    10 * Swift.max(0, now.timeIntervalSince(due[stat].createdAt))
                nextCursor += Swift.min(99, Swift.max(1, statShare))
                if aged || nextCursor < 100 { index = routine } else { index = stat; nextCursor -= 100 }
                if aged { nextCursor = Swift.min(nextCursor, 99) }
            } else { index = stat ?? routine! }
            var item = due.remove(at: index)
            item.state = .leased
            item.leaseOwner = owner
            item.leaseUntil = now.addingTimeInterval(leaseSeconds)
            item.attempts += 1
            item.updatedAt = now
            chosen.append(item)
            slots[item.destinationID, default: 0] -= 1
        }
        if !chosen.isEmpty { try persist(chosen, cursor: nextCursor) }
        return chosen
    }

    private func row(_ id: String) throws -> DicomDeliveryItem {
        guard let item = rows[id] else { throw DicomDeliveryOutboxError.missingDelivery }
        return item
    }

    public func settle(deliveryID: String, leaseOwner: String, settlement: DicomDeliverySettlement) throws {
        let lock = try transaction()
        defer { lock?.unlock() }
        let item = try row(deliveryID)
        guard item.state == .leased, item.leaseOwner == leaseOwner else { return }
        try apply(item, settlement)
    }

    private func apply(_ original: DicomDeliveryItem, _ settlement: DicomDeliverySettlement) throws {
        var item = original
        guard item.state != .cancelled && item.state != .delivered else { return }
        var children: [DicomDeliveryItem] = []
        switch settlement {
        case .complete(let receipt, let retry):
            item.state = .delivered
            item.receipt = receipt
            if let retry { try validate([retry]); children = [retry] }
        case .fail(let errorClass, let message, let retryAt):
            item.state = errorClass == .cancelled ? .cancelled :
                retryAt == nil ? .deadLetter : errorClass == .uncertain ? .uncertain : .retryWait
            item.lastErrorClass = errorClass
            item.lastError = message
            if let retryAt { item.nextAttemptAt = retryAt }
        case .cancel: item.state = .cancelled; item.lastErrorClass = .cancelled
        case .cancelWithReason(let reason):
            item.state = .cancelled; item.lastErrorClass = .cancelled; item.lastError = reason
        }
        item.leaseOwner = nil
        item.leaseUntil = nil
        item.updatedAt = Date()
        try persist([item] + children)
    }

    public func complete(deliveryID: String, receipt: DicomDeliveryReceipt) throws {
        let lock = try transaction()
        defer { lock?.unlock() }
        try apply(row(deliveryID), .complete(receipt, retry: nil))
    }
    public func fail(deliveryID: String, errorClass: DicomDeliveryErrorClass, message: String,
                     retryAt: Date?) throws {
        let lock = try transaction()
        defer { lock?.unlock() }
        try apply(row(deliveryID), .fail(errorClass, message, retryAt: retryAt))
    }
    public func markUncertain(deliveryID: String, message: String) throws {
        let lock = try transaction()
        defer { lock?.unlock() }
        try apply(row(deliveryID), .fail(.uncertain, message, retryAt: Date()))
    }
    public func cancel(deliveryID: String) throws {
        let lock = try transaction()
        defer { lock?.unlock() }
        try apply(row(deliveryID), .cancel)
    }
    public func requeueDeadLetter(deliveryID: String, now: Date) throws {
        let lock = try transaction()
        defer { lock?.unlock() }
        var item = try row(deliveryID)
        guard item.state == .deadLetter else { throw DicomDeliveryOutboxError.invalidTransition }
        item.state = .pending
        item.attempts = 0
        item.nextAttemptAt = now
        item.updatedAt = now
        try persist([item])
    }
    public func releaseExpiredLeases(now: Date) throws {
        let lock = try transaction()
        defer { lock?.unlock() }
        let expired = rows.values.filter { $0.state == .leased && ($0.leaseUntil ?? .distantPast) <= now }
        let changed = expired.map { original in
            var item = original
            item.state = .uncertain
            item.lastErrorClass = .uncertain
            item.lastError = "Lease expired; peer may have accepted the attempt"
            item.leaseOwner = nil
            item.leaseUntil = nil
            item.nextAttemptAt = now
            item.updatedAt = now
            return item
        }
        if !changed.isEmpty { try persist(changed) }
    }
    public func isDelivered(destinationID: String, idempotencyKey: String) throws -> Bool {
        let lock = try transaction()
        defer { lock?.unlock() }
        return rows.values.contains { $0.destinationID == destinationID && $0.idempotencyKey == idempotencyKey &&
            $0.state == .delivered }
    }
    public func fetch(states: Set<DicomDeliveryState>) throws -> [DicomDeliveryItem] {
        let lock = try transaction()
        defer { lock?.unlock() }
        return rows.values.filter { states.contains($0.state) }.sorted { $0.deliveryID < $1.deliveryID }
    }
    public func counts() throws -> [DicomDeliveryState: Int] {
        let lock = try transaction()
        defer { lock?.unlock() }
        return Dictionary(grouping: rows.values, by: \.state).mapValues(\.count)
    }
}

/// Uses the identical actor and transitions, with mandatory fsynced JSONL persistence.
public struct DicomJSONLDeliveryOutbox: DicomDeliveryOutboxStoring {
    private let store: DicomInMemoryDeliveryOutbox
    public init(directory: URL, fileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) throws {
        store = try DicomInMemoryDeliveryOutbox(directory: directory, fileSystem: fileSystem)
    }
    public func enqueue(_ items: [DicomDeliveryItem]) async throws { try await store.enqueue(items) }
    public func lease(max: Int, owner: String, now: Date, leaseSeconds: TimeInterval, statShare: Int)
        async throws -> [DicomDeliveryItem] {
        try await store.lease(max: max, owner: owner, now: now, leaseSeconds: leaseSeconds, statShare: statShare)
    }
    public func lease(max: Int, owner: String, now: Date, leaseSeconds: TimeInterval, statShare: Int,
                      destinationSlots: [String: Int]) async throws -> [DicomDeliveryItem] {
        try await store.lease(max: max, owner: owner, now: now, leaseSeconds: leaseSeconds, statShare: statShare,
                              destinationSlots: destinationSlots)
    }
    public func complete(deliveryID: String, receipt: DicomDeliveryReceipt) async throws {
        try await store.complete(deliveryID: deliveryID, receipt: receipt)
    }
    public func fail(deliveryID: String, errorClass: DicomDeliveryErrorClass, message: String,
                     retryAt: Date?) async throws {
        try await store.fail(deliveryID: deliveryID, errorClass: errorClass, message: message, retryAt: retryAt)
    }
    public func markUncertain(deliveryID: String, message: String) async throws {
        try await store.markUncertain(deliveryID: deliveryID, message: message)
    }
    public func cancel(deliveryID: String) async throws { try await store.cancel(deliveryID: deliveryID) }
    public func requeueDeadLetter(deliveryID: String, now: Date) async throws {
        try await store.requeueDeadLetter(deliveryID: deliveryID, now: now)
    }
    public func releaseExpiredLeases(now: Date) async throws { try await store.releaseExpiredLeases(now: now) }
    public func isDelivered(destinationID: String, idempotencyKey: String) async throws -> Bool {
        try await store.isDelivered(destinationID: destinationID, idempotencyKey: idempotencyKey)
    }
    public func fetch(states: Set<DicomDeliveryState>) async throws -> [DicomDeliveryItem] {
        try await store.fetch(states: states)
    }
    public func counts() async throws -> [DicomDeliveryState: Int] { try await store.counts() }
    public func settle(deliveryID: String, leaseOwner: String, settlement: DicomDeliverySettlement) async throws {
        try await store.settle(deliveryID: deliveryID, leaseOwner: leaseOwner, settlement: settlement)
    }
}

/// Advisory locking serializes cooperating CLI processes, including reads that refresh the snapshot.
private final class DicomDeliveryJournalLock {
    private var descriptor: Int32
    init(path: URL) throws {
        descriptor = open(path.appendingPathExtension("lock").path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(descriptor)
            descriptor = -1
            throw error
        }
    }
    func unlock() {
        if descriptor >= 0 { _ = flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }
    deinit { unlock() }
}
