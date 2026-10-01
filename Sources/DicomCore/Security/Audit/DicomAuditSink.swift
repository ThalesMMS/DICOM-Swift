import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public protocol DicomAuditSink: Sendable {
    func record(_ event: DicomAuditEvent) async throws
    func flush() async throws
}
public enum DicomAuditFailurePolicy: Sendable {
    case failClosed, bestEffort
    case spool(directory: URL, maxBytes: Int64)
}
public enum DicomAuditError: Error, Equatable, Sendable {
    case sinkUnavailable, spoolFull, fileSystemFailure, invalidConfiguration, invalidFrame, timeout
}

/// Synchronous durable operations allow the recorder actor to update its journal without reentrant writes.
/// A spool directory has one recorder owner. Implementations must not follow symbolic links.
public protocol DicomAuditFileSystem: Sendable {
    func read(_ url: URL) throws -> Data
    func append(_ data: Data, to url: URL, maxBytes: Int64) throws
    func replace(_ url: URL, with data: Data) throws
}

public struct DicomAuditLocalFileSystem: DicomAuditFileSystem {
    public init() {}
    public func read(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 && errno == ENOENT { return Data() }
        guard fd >= 0 else { throw DicomAuditError.fileSystemFailure }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return try handle.readToEnd() ?? Data()
    }
    public func append(_ data: Data, to url: URL, maxBytes: Int64) throws {
        try directory(url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw DicomAuditError.fileSystemFailure }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw DicomAuditError.fileSystemFailure }
        guard maxBytes >= 0, status.st_size <= maxBytes, Int64(data.count) <= maxBytes - status.st_size else {
            throw DicomAuditError.spoolFull
        }
        try writeAll(data, fd: fd)
        guard fsync(fd) == 0 else { throw DicomAuditError.fileSystemFailure }
        try syncDirectory(url.deletingLastPathComponent())
    }
    public func replace(_ url: URL, with data: Data) throws {
        try directory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".audit-\(UUID().uuidString)")
        defer { _ = unlink(temporary.path) }
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw DicomAuditError.fileSystemFailure }
        defer { close(fd) }
        try writeAll(data, fd: fd)
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw DicomAuditError.fileSystemFailure }
        try syncDirectory(url.deletingLastPathComponent())
    }
    private func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw DicomAuditError.fileSystemFailure }
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw DicomAuditError.fileSystemFailure }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw DicomAuditError.fileSystemFailure }
    }
    private func writeAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw DicomAuditError.fileSystemFailure }
                offset += count
            }
        }
    }
}

public actor DicomAuditRecorder {
    public struct Stats: Equatable, Sendable {
        public var recorded = 0
        public var sinkFailures = 0
        public var dropped = 0
        public var spooled = 0
        public var drained = 0
    }
    private let sinks: [any DicomAuditSink]
    private let policy: DicomAuditFailurePolicy
    private let fileSystem: any DicomAuditFileSystem
    private var counters = Stats()
    private var draining = false
    public init(sinks: [any DicomAuditSink], policy: DicomAuditFailurePolicy,
                fileSystem: any DicomAuditFileSystem = DicomAuditLocalFileSystem()) {
        self.sinks = sinks; self.policy = policy; self.fileSystem = fileSystem
    }
    public func record(_ input: DicomAuditEvent) async throws {
        let event = DicomAuditPHIMinimizer.minimize(input)
        do { try await deliver(event); counters.recorded += 1 }
        catch {
            counters.sinkFailures += 1
            switch policy {
            case .failClosed: throw DicomAuditError.sinkUnavailable
            case .bestEffort: counters.dropped += 1
            case .spool(let directory, let maxBytes):
                var line = try DicomAuditMessageJSON.encode(event); line.append(10)
                try fileSystem.append(line, to: directory.appendingPathComponent("audit.jsonl"), maxBytes: maxBytes)
                counters.spooled += 1
            }
        }
    }
    /// At-least-once delivery: a crash after delivery but before journal acknowledgement may replay a record.
    /// Partial multi-sink success can also replay to a recovered sink; consumers should deduplicate when needed.
    public func drainSpool() async throws {
        guard case .spool(let directory, _) = policy, !draining else { return }
        draining = true; defer { draining = false }
        let url = directory.appendingPathComponent("audit.jsonl")
        // Bound this drain to its initial snapshot; newly spooled lines are retained for the next drain.
        let snapshot = try fileSystem.read(url)
        var consumed = 0
        for line in snapshot.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            let event = try DicomAuditMessageJSON.decode(Data(line))
            do { try await deliver(event) }
            catch { counters.sinkFailures += 1; throw DicomAuditError.sinkUnavailable }
            let current = try fileSystem.read(url)
            let prefix = Data(line) + Data([10])
            guard current.starts(with: prefix) else { throw DicomAuditError.fileSystemFailure }
            try fileSystem.replace(url, with: Data(current.dropFirst(prefix.count)))
            consumed += prefix.count; counters.drained += 1
        }
        if consumed != snapshot.count { throw DicomAuditError.fileSystemFailure }
    }
    public func flush() async throws {
        do {
            guard !sinks.isEmpty else { throw DicomAuditError.sinkUnavailable }
            for sink in sinks { try await sink.flush() }
        } catch {
            counters.sinkFailures += 1
            if case .bestEffort = policy { return }
            throw DicomAuditError.sinkUnavailable
        }
    }
    public func stats() -> Stats { counters }
    private func deliver(_ event: DicomAuditEvent) async throws {
        guard !sinks.isEmpty else { throw DicomAuditError.sinkUnavailable }
        var failed = false
        for sink in sinks {
            do { try await sink.record(event) } catch { failed = true }
        }
        if failed { throw DicomAuditError.sinkUnavailable }
    }
}

public actor DicomInMemoryAuditSink: DicomAuditSink {
    public private(set) var events: [DicomAuditEvent] = []
    public init() {}
    public func record(_ event: DicomAuditEvent) { events.append(DicomAuditPHIMinimizer.minimize(event)) }
    public func flush() {}
}
public actor DicomFileAuditSink: DicomAuditSink {
    private let url: URL
    private let fileSystem: any DicomAuditFileSystem
    public init(url: URL, fileSystem: any DicomAuditFileSystem = DicomAuditLocalFileSystem()) {
        self.url = url; self.fileSystem = fileSystem
    }
    public func record(_ event: DicomAuditEvent) throws {
        var data = try DicomAuditMessageJSON.encode(event); data.append(10)
        try fileSystem.append(data, to: url, maxBytes: .max)
    }
    public func flush() {} // Every record is fsynced before returning.
}
