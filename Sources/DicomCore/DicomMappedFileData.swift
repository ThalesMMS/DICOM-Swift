import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A file's bytes from an offset on, mapped instead of read (issue #2793): a zero-based `Data` over the file that
/// takes no memory of its own, which `Data(contentsOf:options:)` gives only from offset 0 and slicing a mapped
/// `Data` into a zero-based one loses (it copies). The mapping is private and writable: a caller that mutates the
/// bytes gets its own copies of the touched pages, and the file never changes.
enum DicomMappedFileData {
    static func data(contentsOf url: URL, from offset: Int = 0) throws -> Data {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw failure(url) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failure(url) }
        let size = Int(info.st_size)
        guard offset >= 0, offset <= size else { throw POSIXError(.EINVAL) }
        guard offset < size else { return Data() }
        let pageSize = Int(getpagesize())
        let mappedOffset = offset / pageSize * pageSize
        let mappedLength = size - mappedOffset
        guard let base = mmap(nil, mappedLength, PROT_READ | PROT_WRITE, MAP_PRIVATE, descriptor, off_t(mappedOffset)),
              base != MAP_FAILED else {
            throw failure(url)
        }
        return Data(bytesNoCopy: base + (offset - mappedOffset), count: size - offset,
                    deallocator: .custom { _, _ in munmap(base, mappedLength) })
    }

    private static func failure(_ url: URL) -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path])
    }
}
