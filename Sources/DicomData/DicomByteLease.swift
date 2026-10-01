import Foundation

/// A bounded owned view. Closing its source prevents new accesses; an access already
/// in progress retains its storage until the closure returns. Pointers must not escape.
public final class DicomByteLease: Sendable {
    public let range: Range<Int>
    public var count: Int { bytes.count }
    private let bytes: Data
    private let lifetime: DicomByteSourceLifetime

    package init(bytes: Data, range: Range<Int>, lifetime: DicomByteSourceLifetime) {
        self.bytes = bytes
        self.range = range
        self.lifetime = lifetime
    }

    public func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
        try lifetime.checkOpen()
        return try bytes.withUnsafeBytes(body)
    }

    /// Explicit compatibility copy, independent of subsequent source closure.
    public func copyData() throws -> Data {
        try lifetime.checkOpen()
        let result = bytes.withUnsafeBytes { Data($0) }
        lifetime.recordCopy(bytes.count)
        return result
    }

    package func retainedData() throws -> Data {
        try lifetime.checkOpen()
        return bytes
    }
}
