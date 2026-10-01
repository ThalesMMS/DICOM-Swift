import Dispatch
import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Descriptor access is confined to `queue`; queued operations retain this object.
/// Anonymous mappings cannot SIGBUS when the external file is truncated.
package final class DicomFileByteStorage: @unchecked Sendable {
    package let count: Int
    private let path: String
    private let snapshot: Revision
    private var descriptor: Int32
    private let queue: DispatchQueue

    private struct Revision: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64

        init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(value.st_ino)
            size = Int64(value.st_size)
            #if canImport(Darwin)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanos = Int64(value.st_ctimespec.tv_nsec)
            #else
            modifiedSeconds = Int64(value.st_mtim.tv_sec)
            modifiedNanos = Int64(value.st_mtim.tv_nsec)
            changedSeconds = Int64(value.st_ctim.tv_sec)
            changedNanos = Int64(value.st_ctim.tv_nsec)
            #endif
        }
    }

    private init(path: String, queue: DispatchQueue) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw DicomByteSource.Failure.io(errno) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0 else {
            let code = errno
            _ = systemClose(fd)
            throw DicomByteSource.Failure.io(code)
        }
        guard attributes.st_size >= 0, attributes.st_size <= Int.max,
              (attributes.st_mode & S_IFMT) == S_IFREG else {
            _ = systemClose(fd)
            throw DicomByteSource.Failure.invalidSize
        }
        descriptor = fd
        self.path = path
        self.queue = queue
        snapshot = Revision(attributes)
        count = Int(attributes.st_size)
    }

    deinit { if descriptor >= 0 { _ = systemClose(descriptor) } }

    package static func openFile(_ url: URL) async throws -> DicomFileByteStorage {
        guard url.isFileURL else { throw DicomByteSource.Failure.invalidSource }
        let queue = DispatchQueue(label: "dicom.byte-source.file", qos: .userInitiated)
        return try await perform(on: queue) { cancelled in
            if cancelled() { throw CancellationError() }
            return try DicomFileByteStorage(path: url.path, queue: queue)
        }
    }

    package func read(_ range: Range<Int>, mapped: Bool) async throws -> Data {
        try await Self.perform(on: queue) { cancelled in
            if cancelled() { throw CancellationError() }
            try self.validateRevision()
            let length = range.count
            guard length > 0 else { return Data() }
            let allocation: UnsafeMutableRawPointer?
            if mapped {
                allocation = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
                guard allocation != MAP_FAILED else { throw DicomByteSource.Failure.io(errno) }
            } else {
                allocation = malloc(length)
            }
            guard let buffer = allocation else { throw DicomByteSource.Failure.allocationFailed }
            var transferred = false
            defer {
                if !transferred {
                    if mapped { _ = munmap(buffer, length) } else { free(buffer) }
                }
            }
            var received = 0
            while received < length {
                if cancelled() { throw CancellationError() }
                let amount = pread(self.descriptor, buffer.advanced(by: received),
                                   min(length - received, 256 * 1024), off_t(range.lowerBound + received))
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw DicomByteSource.Failure.io(errno)
                }
                guard amount > 0 else {
                    throw DicomByteSource.Failure.shortRead(expected: length, actual: received)
                }
                received += amount
            }
            try self.validateRevision()
            if cancelled() { throw CancellationError() }
            transferred = true
            return Data(bytesNoCopy: buffer, count: length, deallocator: .custom { pointer, count in
                if mapped { _ = munmap(pointer, count) } else { free(pointer) }
            })
        }
    }

    package func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.descriptor >= 0 {
                    _ = systemClose(self.descriptor)
                    self.descriptor = -1
                }
                continuation.resume()
            }
        }
    }

    private func validateRevision() throws {
        guard descriptor >= 0 else { throw DicomByteSource.Failure.closed }
        var descriptorAttributes = stat()
        var pathAttributes = stat()
        guard fstat(descriptor, &descriptorAttributes) == 0,
              stat(path, &pathAttributes) == 0,
              Revision(descriptorAttributes) == snapshot,
              Revision(pathAttributes) == snapshot else {
            throw DicomByteSource.Failure.changed
        }
    }

    private static func perform<Value: Sendable>(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable (@Sendable () -> Bool) throws -> Value
    ) async throws -> Value {
        let cancellation = Mutex(false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try operation { cancellation.withLock { $0 } } })
                }
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
    }
}

private func systemClose(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(descriptor)
    #else
    Glibc.close(descriptor)
    #endif
}
