import Foundation

/// Stable logical offsets over memory, bounded file reads or an explicitly injected
/// remote range transport. Identities are opaque and contain no path, URL or credentials.
public actor DicomByteSource {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case invalidSize
        case invalidSource
        case invalidRange
        case readLimit
        case totalReadLimit
        case concurrentReadLimit
        case closed
        case changed
        case shortRead(expected: Int, actual: Int)
        case io(Int32)
        case allocationFailed
        case invalidEntityTag
        case invalidContentRange
        case rangeUnsupported
        case httpStatus(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidSize: "The source must be a regular file with a representable byte count."
            case .invalidSource: "A local byte source requires a file URL."
            case .invalidRange: "The byte range lies outside the source."
            case .readLimit: "The read exceeds the per-response byte limit."
            case .totalReadLimit: "The source has exhausted its reserved byte budget."
            case .concurrentReadLimit: "The source has reached its concurrent read limit."
            case .closed: "The byte source is closed or invalidated."
            case .changed: "The source revision changed; acquired views have been invalidated."
            case .shortRead(let expected, let actual): "Short byte read: expected \(expected), received \(actual)."
            case .io(let code): "Byte source I/O failed with code \(code)."
            case .allocationFailed: "The bounded byte buffer could not be allocated."
            case .invalidEntityTag: "A strong, valid entity tag is required for remote ranges."
            case .invalidContentRange: "The remote Content-Range does not match the requested extent."
            case .rangeUnsupported: "The remote source did not supply a permitted byte-range response."
            case .httpStatus(let status): "The remote range request returned HTTP \(status)."
            }
        }
    }

    public struct Limits: Sendable {
        public let maximumReadBytes: Int
        public let maximumTotalReadBytes: Int
        public let maximumConcurrentReads: Int

        public init(maximumReadBytes: Int = 64 * 1024 * 1024,
                    maximumTotalReadBytes: Int = 512 * 1024 * 1024,
                    maximumConcurrentReads: Int = 4) {
            self.maximumReadBytes = max(0, maximumReadBytes)
            self.maximumTotalReadBytes = max(0, maximumTotalReadBytes)
            self.maximumConcurrentReads = max(0, maximumConcurrentReads)
        }
    }

    public struct Metrics: Sendable {
        public fileprivate(set) var readCount = 0
        public fileprivate(set) var requestedBytes = 0
        public fileprivate(set) var budgetedBytes = 0
        /// Payload bytes of successful validated reads, including permitted complete responses.
        /// Failed attempts retain their full reservation in `budgetedBytes`.
        public fileprivate(set) var receivedBytes = 0
        public fileprivate(set) var storageCopiedBytes = 0
        public fileprivate(set) var compatibilityCopiedBytes = 0
        /// The first 128 requests, bounded independently of the source's lifetime.
        public fileprivate(set) var ranges: [Range<Int>] = []
    }

    public enum FileStorage: Sendable {
        case buffer
        /// Bounded anonymous mapping filled with pread, not a mapping of a mutable file.
        /// The file-to-buffer copy is counted; this is not a zero-copy claim.
        case mappedSnapshot
    }

    private enum Storage: Sendable {
        case memory(Data)
        case file(DicomFileByteStorage, FileStorage)
        case remote(DicomByteRangeTransport, entityTag: String, maximumFullResponseBytes: Int)
    }

    public nonisolated let count: Int
    public nonisolated let revision: UUID
    public nonisolated let limits: Limits
    private var storage: Storage
    private let lifetime = DicomByteSourceLifetime()
    private var counters = Metrics()
    private var activeReads = 0
    private var closed = false

    public init(data: Data, limits: Limits = Limits()) {
        count = data.count
        revision = UUID()
        self.limits = limits
        storage = .memory(data)
    }

    private init(file: DicomFileByteStorage, storage: FileStorage, limits: Limits) {
        count = file.count
        revision = UUID()
        self.limits = limits
        self.storage = .file(file, storage)
    }

    public static func openFile(_ url: URL, storage: FileStorage = .buffer,
                                limits: Limits = Limits()) async throws -> DicomByteSource {
        let file = try await DicomFileByteStorage.openFile(url)
        do { try Task.checkCancellation() }
        catch { await file.close(); throw error }
        return DicomByteSource(file: file, storage: storage, limits: limits)
    }

    /// Requires an independently obtained length and strong ETag. By default a server
    /// that ignores Range is refused. A complete response is allowed only within the
    /// explicit cap and the ordinary per-read budget; it is never cached implicitly.
    public init(remote: DicomByteRangeTransport, count: Int, entityTag: String,
                maximumFullResponseBytes: Int = 0, limits: Limits = Limits()) throws {
        guard count >= 0 else { throw Failure.invalidSize }
        guard entityTag.count >= 2, entityTag.first == "\"", entityTag.last == "\"",
              entityTag.utf8.dropFirst().dropLast().allSatisfy({ $0 == 0x21 || (0x23...0x7E).contains($0) || $0 >= 0x80 }) else { throw Failure.invalidEntityTag }
        self.count = count
        revision = UUID()
        self.limits = limits
        storage = .remote(remote, entityTag: entityTag, maximumFullResponseBytes: max(0, maximumFullResponseBytes))
    }

    public var metrics: Metrics {
        var result = counters
        result.compatibilityCopiedBytes = lifetime.copiedBytes
        return result
    }

    package func recordCompatibilityCopy(_ count: Int) { lifetime.recordCopy(count) }

    package func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
    }

    public func read(_ range: Range<Int>) async throws -> DicomByteLease {
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard range.lowerBound >= 0, range.upperBound <= count else { throw Failure.invalidRange }
        guard range.count <= limits.maximumReadBytes else { throw Failure.readLimit }
        let responseLimit: Int
        if case .remote(_, _, let fullLimit) = storage, !range.isEmpty, count <= fullLimit {
            responseLimit = min(limits.maximumReadBytes, max(range.count, count))
        } else { responseLimit = range.count }
        guard responseLimit <= limits.maximumTotalReadBytes - counters.budgetedBytes else {
            throw Failure.totalReadLimit
        }
        guard activeReads < limits.maximumConcurrentReads else { throw Failure.concurrentReadLimit }
        activeReads += 1
        counters.readCount += 1
        counters.requestedBytes += range.count
        counters.budgetedBytes += responseLimit
        if counters.ranges.count < 128 { counters.ranges.append(range) }
        defer { activeReads -= 1 }

        let bytes: Data
        do {
            switch storage {
            case .memory(let data):
                let lower = data.startIndex + range.lowerBound
                bytes = data[lower..<(lower + range.count)]
            case .file(let file, let mode):
                bytes = try await file.read(range, mapped: mode == .mappedSnapshot)
                counters.storageCopiedBytes += bytes.count
            case .remote(let transport, let entityTag, let maximumFullResponseBytes):
                if range.isEmpty {
                    bytes = Data()
                } else {
                    let response = try await transport.read(.init(range: range, ifMatch: entityTag,
                                                                  maximumResponseBytes: responseLimit))
                    if response.status == 412 { throw Failure.changed }
                    if response.status == 416 { throw Failure.rangeUnsupported }
                    guard response.body.count <= responseLimit else { throw Failure.readLimit }
                    guard response.status == 200 || response.status == 206 else { throw Failure.httpStatus(response.status) }
                    guard response.entityTag == entityTag else { throw Failure.changed }
                    switch response.status {
                    case 206:
                        guard validContentRange(response.contentRange, for: range) else { throw Failure.invalidContentRange }
                        bytes = response.body
                    case 200:
                        guard count <= maximumFullResponseBytes, count <= responseLimit,
                              response.body.count == count else { throw Failure.rangeUnsupported }
                        let start = response.body.startIndex + range.lowerBound
                        bytes = response.body[start..<(start + range.count)]
                    default: throw Failure.httpStatus(response.status)
                    }
                    counters.receivedBytes += response.body.count
                }
            }
        } catch {
            if error as? Failure == .changed {
                closed = true
                lifetime.close()
                if case .file(let file, _) = storage { await file.close() }
            }
            throw error
        }
        try Task.checkCancellation()
        guard !closed else { throw Failure.closed }
        guard bytes.count == range.count else { throw Failure.shortRead(expected: range.count, actual: bytes.count) }
        if case .remote = storage {} else { counters.receivedBytes += bytes.count }
        return DicomByteLease(bytes: bytes, range: range, lifetime: lifetime)
    }

    private func validContentRange(_ header: String?, for range: Range<Int>) -> Bool {
        guard let header else { return false }
        let fields = header.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return false }
        let extent = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard extent.count == 2 else { return false }
        let positions = extent[0].split(separator: "-", omittingEmptySubsequences: false)
        guard positions.count == 2 else { return false }
        let values = [positions[0], positions[1], extent[1]]
        guard values.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return false }
        return Int(values[0]) == range.lowerBound && Int(values[1]) == range.upperBound - 1
            && Int(values[2]) == count
    }

    public func close() async {
        closed = true
        lifetime.close()
        let previous = storage
        storage = .memory(Data())
        if case .file(let file, _) = previous { await file.close() }
    }
}
