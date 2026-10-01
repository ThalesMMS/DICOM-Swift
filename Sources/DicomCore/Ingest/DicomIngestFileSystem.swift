import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public protocol DicomIngestFileSystem: Sendable {
    func createDirectory(_ path: URL) throws
    func write(_ data: Data, to path: URL, append: Bool) throws
    func fsyncFile(_ path: URL) throws
    func fsyncDirectory(_ path: URL) throws
    /// Synchronizes every path before returning, allowing a shared device flush.
    func synchronize(files: [URL], directories: [URL]) throws
    /// Must fail if the destination exists. Both paths must be on the same filesystem.
    func rename(_ source: URL, to destination: URL) throws
    func exchange(_ first: URL, _ second: URL) throws
    func remove(_ path: URL) throws
    func exists(_ path: URL) throws -> Bool
    func read(_ path: URL) throws -> Data
    func lastByte(_ path: URL) throws -> UInt8?
    func contentsOf(_ directory: URL) throws -> [URL]
    func readChunks(_ path: URL, consume: (Data) throws -> Void) throws
}

public extension DicomIngestFileSystem {
    // issue #2532: an unsupported filesystem must fail before moving either recoverable version.
    func exchange(_ first: URL, _ second: URL) throws { throw POSIXError(.ENOTSUP) }

    func synchronize(files: [URL], directories: [URL]) throws {
        for path in files { try fsyncFile(path) }
        for path in directories { try fsyncDirectory(path) }
    }

    func lastByte(_ path: URL) throws -> UInt8? { try read(path).last }
    func readChunks(_ path: URL, consume: (Data) throws -> Void) throws { try consume(read(path)) }
    func checksum(_ path: URL) throws -> String {
        var hash = SHA256()
        try readChunks(path) { hash.update(data: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct DicomLocalIngestFileSystem: DicomIngestFileSystem {
    public init() {}
    public func createDirectory(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    public func write(_ data: Data, to path: URL, append: Bool = false) throws {
        let fd = open(path.path, O_WRONLY | O_CREAT | (append ? O_APPEND : O_EXCL), 0o600)
        guard fd >= 0 else { throw failure(path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        do { try handle.write(contentsOf: data) } catch { throw DicomIngestError.mapped(error, path: path, required: Int64(data.count)) }
    }
    public func fsyncFile(_ path: URL) throws { try sync(path) }
    public func fsyncDirectory(_ path: URL) throws { try sync(path) }
    /// One barrier per path, then one media flush per device. On iOS `fsync` is itself a full
    /// media flush, so the per-path step uses `F_BARRIERFSYNC` and only the final `F_FULLFSYNC`
    /// pays for the flush.
    public func synchronize(files: [URL], directories: [URL]) throws {
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors { close(descriptor) } }
        var devices: [dev_t: (descriptor: Int32, path: URL)] = [:]
        var visited = Set<URL>()
        for path in files + directories where visited.insert(path).inserted {
            let descriptor = open(path.path, O_RDONLY)
            guard descriptor >= 0 else { throw failure(path) }
            descriptors.append(descriptor)
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw failure(path) }
            #if canImport(Darwin)
            if fcntl(descriptor, F_BARRIERFSYNC) != 0 {
                guard errno == EINVAL || errno == ENOTSUP, fsync(descriptor) == 0 else { throw failure(path) }
            }
            #else
            guard fsync(descriptor) == 0 else { throw failure(path) }
            #endif
            if devices[info.st_dev] == nil { devices[info.st_dev] = (descriptor, path) }
        }
        #if canImport(Darwin)
        for device in devices.values {
            if fcntl(device.descriptor, F_FULLFSYNC) == 0 { continue }
            guard errno == EINVAL || errno == ENOTSUP else { throw failure(device.path) }
        }
        #endif
    }
    private func sync(_ path: URL) throws {
        let fd = open(path.path, O_RDONLY)
        guard fd >= 0 else { throw failure(path) }
        defer { close(fd) }
        #if canImport(Darwin)
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard errno == EINVAL || errno == ENOTSUP else { throw failure(path) }
        #endif
        guard fsync(fd) == 0 else { throw failure(path) }
    }
    public func rename(_ source: URL, to destination: URL) throws {
        #if canImport(Darwin)
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw failure(destination) }
        #else
        // link publishes atomically without replacement; replay tolerates both names after a crash.
        guard link(source.path, destination.path) == 0 else { throw failure(destination) }
        guard unlink(source.path) == 0 else { throw failure(source) }
        #endif
    }
    // issue #2532: a single namespace operation keeps the canonical path continuously readable.
    public func exchange(_ first: URL, _ second: URL) throws {
        #if canImport(Darwin)
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else { throw failure(first) }
        #else
        throw POSIXError(.ENOTSUP)
        #endif
    }
    public func remove(_ path: URL) throws { try FileManager.default.removeItem(at: path) }
    public func exists(_ path: URL) throws -> Bool {
        var info = stat()
        if lstat(path.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw failure(path)
    }
    /// Mapped, not read: verifying a large staged object does not load it (issue #2793).
    public func read(_ path: URL) throws -> Data { try Data(contentsOf: path, options: .alwaysMapped) }
    public func lastByte(_ path: URL) throws -> UInt8? {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length > 0 else { return nil }
        try handle.seek(toOffset: length - 1)
        return try handle.read(upToCount: 1)?.first
    }
    public func contentsOf(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
    public func readChunks(_ path: URL, consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        // Each chunk is released as the next is read (issue #2793): without a pool, a detached task keeps every
        // autoreleased chunk until it ends, the whole file.
        while true {
            #if canImport(ObjectiveC)
            let chunk = try autoreleasepool { try handle.read(upToCount: 1024 * 1024) }
            #else
            let chunk = try handle.read(upToCount: 1024 * 1024)
            #endif
            guard let data = chunk, !data.isEmpty else { return }
            try consume(data)
        }
    }
    private func failure(_ path: URL) -> Error {
        DicomIngestError.mapped(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO), path: path)
    }
}

public protocol DicomIngestDiskCapacityChecking: Sendable {
    func checkCapacity(required: Int64, at root: URL) throws
}

/// A crash is sticky: subsequent effects fail until a new wrapper is constructed at restart.
public final class DicomFaultInjectingFileSystem: DicomIngestFileSystem, @unchecked Sendable {
    public enum Operation: String, CaseIterable, Sendable {
        case createDirectory, write, fsyncFile, fsyncDirectory, rename, exchange, remove, exists, read, contentsOf
    }
    public enum Fault: Sendable { case fail(Int32), crashBefore, crashAfter, partialWrite(Int) }
    private let base: any DicomIngestFileSystem
    private let operation: Operation
    private let nth: Int
    private let fault: Fault
    private let lock = NSRecursiveLock()
    private var count = 0
    private var crashed = false
    public init(base: any DicomIngestFileSystem = DicomLocalIngestFileSystem(), operation: Operation,
                nth: Int = 1, fault: Fault = .crashAfter) {
        self.base = base; self.operation = operation; self.nth = nth; self.fault = fault
    }
    private func perform<T>(_ kind: Operation, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if crashed { throw DicomIngestCrash() }
        if kind == operation { count += 1 }
        let hit = kind == operation && count == nth
        if hit {
            switch fault {
            case .fail(let code): throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            case .crashBefore: crashed = true; throw DicomIngestCrash()
            default: break
            }
        }
        let result = try body()
        if hit, case .crashAfter = fault { crashed = true; throw DicomIngestCrash() }
        return result
    }
    public func createDirectory(_ path: URL) throws { try perform(.createDirectory) { try base.createDirectory(path) } }
    public func write(_ data: Data, to path: URL, append: Bool) throws {
        try perform(.write) {
            if operation == .write, count == nth, case .partialWrite(let size) = fault {
                try base.write(Data(data.prefix(size)), to: path, append: append)
                crashed = true
                throw DicomIngestCrash()
            }
            try base.write(data, to: path, append: append)
        }
    }
    public func fsyncFile(_ path: URL) throws { try perform(.fsyncFile) { try base.fsyncFile(path) } }
    public func fsyncDirectory(_ path: URL) throws { try perform(.fsyncDirectory) { try base.fsyncDirectory(path) } }
    public func exchange(_ first: URL, _ second: URL) throws {
        try perform(.exchange) { try base.exchange(first, second) }
    }
    public func rename(_ source: URL, to destination: URL) throws { try perform(.rename) { try base.rename(source, to: destination) } }
    public func remove(_ path: URL) throws { try perform(.remove) { try base.remove(path) } }
    public func exists(_ path: URL) throws -> Bool { try perform(.exists) { try base.exists(path) } }
    public func read(_ path: URL) throws -> Data { try perform(.read) { try base.read(path) } }
    public func contentsOf(_ directory: URL) throws -> [URL] { try perform(.contentsOf) { try base.contentsOf(directory) } }
    public func readChunks(_ path: URL, consume: (Data) throws -> Void) throws {
        try perform(.read) { try base.readChunks(path, consume: consume) }
    }
}
