import Foundation

/// A request body of byte and file segments, sent in order without first being copied into one buffer or file. A
/// transport reads it with `makeInputStream()` as many times as it must send it: every stream starts again from the
/// first byte, so a repeated attempt or a body URLSession asks for again after a challenge or a redirect is whole.
public struct DicomWebHTTPRequestBody: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        case data(Data)
        /// The first `length` bytes of the file. A file that holds fewer bytes fails the stream that reads it.
        case file(URL, length: Int)
    }

    public private(set) var segments: [Segment]

    public init(segments: [Segment] = []) {
        self.segments = segments
    }

    /// The exact byte count of the body, for its Content-Length.
    public var length: Int {
        segments.reduce(0) { total, segment in
            switch segment {
            case .data(let data): total + data.count
            case .file(_, let length): total + length
            }
        }
    }

    /// A new stream over the whole body, from its first byte.
    public func makeInputStream() -> InputStream {
        DicomWebSegmentedInputStream(segments: segments)
    }

    /// Appends bytes, joined to the previous segment when that one also holds bytes.
    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        if case .data(var last)? = segments.last {
            segments.removeLast()
            last.append(data)
            segments.append(.data(last))
        } else {
            segments.append(.data(data))
        }
    }

    mutating func append(_ segment: Segment) {
        if case .data(let data) = segment { append(data) } else { segments.append(segment) }
    }

    /// Writes the body to `file`, for a transport that sends a body only from a single file.
    func write(to file: URL) throws {
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        for segment in segments {
            switch segment {
            case .data(let data):
                try output.write(contentsOf: data)
            case .file(let url, let length):
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                var remaining = length
                while remaining > 0 {
                    try Task.checkCancellation()
                    let copied = try autoreleasepool { () throws -> Int in
                        let chunk = try input.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
                        try output.write(contentsOf: chunk)
                        return chunk.count
                    }
                    guard copied > 0 else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
                    remaining -= copied
                }
            }
        }
    }
}
