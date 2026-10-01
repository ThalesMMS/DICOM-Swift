import Foundation
import CryptoKit

public struct DicomJPIPTarget: Sendable {
    public let codestreams: [Data]
    public let identifier: String
    public init(codestreams: [Data]) {
        self.codestreams = codestreams
        var digest = SHA256()
        for data in codestreams {
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { digest.update(data: Data($0)) }
            digest.update(data: data)
        }
        identifier = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public protocol DicomJPIPTargetProviding: Sendable {
    /// Implementations must enforce the supplied byte budget before reading or allocating target data.
    func target(named name: String, maximumBytes: Int) async throws -> DicomJPIPTarget
}

/// Resolves regular files strictly beneath a configured directory, including after symlink resolution.
public struct DicomJPIPDirectoryTargetProvider: DicomJPIPTargetProviding {
    public let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL.resolvingSymlinksInPath() }
    public func target(named name: String, maximumBytes: Int) async throws -> DicomJPIPTarget {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
            throw DicomJPIPServerError.targetNotFound
        }
        let url = directory.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(directory.path + "/") else { throw DicomJPIPServerError.targetNotFound }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize else { throw DicomJPIPServerError.targetNotFound }
        guard size <= maximumBytes else { throw DicomJPIPServerError.limitExceeded }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw DicomJPIPServerError.limitExceeded }
        if data.count >= 132 && data[128..<132] == Data("DICM".utf8) {
            let decoder = try await DCMDecoder(contentsOf: url)
            guard let descriptor = decoder.encapsulatedPixelDataDescriptor else { throw DicomJPIPServerError.unsupportedCodestream }
            var frames: [Data] = [], bytes = 0
            for frame in 0..<descriptor.numberOfFrames {
                guard let payload = decoder.getEncapsulatedFrame(frame)?.data else { throw DicomJPIPServerError.malformedCodestream }
                guard payload.count <= maximumBytes - bytes else { throw DicomJPIPServerError.limitExceeded }
                bytes += payload.count; frames.append(try Self.codestream(payload))
            }
            return .init(codestreams: frames)
        }
        return .init(codestreams: [try Self.codestream(data)])
    }
    static func codestream(_ data: Data) throws -> Data {
        if data.starts(with: [255, 79]) {
            if data.last == 0, data.count >= 3, data.suffix(3) == Data([255, 217, 0]) { return Data(data.dropLast()) }
            return data
        }
        var at = 0
        func uint(_ p: Int, _ count: Int) throws -> Int {
            var value = 0
            for byte in data[p..<p + count] {
                guard value <= (Int.max - Int(byte)) / 256 else { throw DicomJPIPServerError.malformedCodestream }
                value = value * 256 + Int(byte)
            }
            return value
        }
        while data.count - at >= 8 {
            var size = try uint(at, 4), header = 8
            if size == 1 {
                guard data.count - at >= 16 else { throw DicomJPIPServerError.malformedCodestream }
                size = try uint(at + 8, 8); header = 16
            } else if size == 0 { size = data.count - at }
            guard size >= header, size <= data.count - at else { throw DicomJPIPServerError.malformedCodestream }
            if data[at + 4..<at + 8] == Data("jp2c".utf8) { return Data(data[at + header..<at + size]) }
            at += size
        }
        throw DicomJPIPServerError.unsupportedCodestream
    }
}
