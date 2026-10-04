import Foundation

/// The part of a response body that arrived while its reader was behind, kept in a file only its owner can read or
/// write (0600) until it is read. Bytes are read back in the order they were written. Removing the file, or releasing
/// this object, closes and deletes it.
final class DicomWebResponseSpillFile {
    let url: URL
    private let descriptor: Int32
    private var written: Int64 = 0
    private var read: Int64 = 0
    private var removed = false

    init(in directory: URL) throws {
        url = directory.appendingPathComponent("DicomWebResponse-\(UUID().uuidString)")
        descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Self.lastError() }
    }

    deinit { remove() }

    /// Whether some written bytes are still to be read.
    var hasUnreadBytes: Bool { read < written }

    func append(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = pwrite(descriptor, bytes.baseAddress! + offset, bytes.count - offset,
                                   off_t(written) + off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.lastError() }
                offset += count
            }
        }
        written += Int64(data.count)
    }

    /// The next unread bytes, at most `maximumCount` of them.
    func readNext(upTo maximumCount: Int) throws -> Data {
        var data = Data(count: Int(min(Int64(maximumCount), written - read)))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = pread(descriptor, bytes.baseAddress! + offset, bytes.count - offset,
                                  off_t(read) + off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw count == 0 ? POSIXError(.EIO) : Self.lastError() }
                offset += count
            }
        }
        read += Int64(data.count)
        return data
    }

    func remove() {
        guard !removed else { return }
        removed = true
        close(descriptor)
        unlink(url.path)
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
