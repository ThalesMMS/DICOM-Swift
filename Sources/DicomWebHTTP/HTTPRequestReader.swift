import Foundation
import DicomCore

actor HTTPRequestReader {
    struct Request: Sendable {
        let request: DicomWebHTTPRequest
        let close: Bool
        let expectContinue: Bool
    }
    private let channel: HTTPByteChannel
    private let configuration: DicomWebHTTPListenerConfiguration
    private var buffer = Data()
    private var remaining = 0
    private var chunked = false
    private var chunkRemaining = 0
    private var needsDelimiter = false
    private var total = 0
    private var done = true
    init(channel: HTTPByteChannel, configuration: DicomWebHTTPListenerConfiguration) {
        self.channel = channel; self.configuration = configuration
    }
    func takeBufferedBytes() -> Data {
        let saved = buffer
        buffer = Data()
        return saved
    }
    private func fill() async throws { buffer.append(try await channel.next()) }
    private func line(limit: Int, status: Int = 431) async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                guard range.lowerBound <= limit, let result = String(data: buffer[..<range.lowerBound], encoding: .utf8) else {
                    throw HTTPFailure(status: status)
                }
                buffer = Data(buffer[range.upperBound...]); return result
            }
            guard buffer.count <= limit else { throw HTTPFailure(status: status) }
            try await fill()
        }
    }
    func request(tls: Bool, localPort: UInt16?) async throws -> Request {
        let first = try await line(limit: configuration.maximumHeaderBytes)
        let words = first.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[2] == "HTTP/1.1", let method = DicomWebHTTPMethod(rawValue: String(words[0])),
              words[1].hasPrefix("/"), !words[1].hasPrefix("//"), !words[1].contains("#") else { throw HTTPFailure(status: 400) }
        var headers: [String: String] = [:]
        var bytes = first.utf8.count + 2
        while true {
            let header = try await line(limit: configuration.maximumHeaderBytes - bytes)
            bytes += header.utf8.count + 2
            guard bytes <= configuration.maximumHeaderBytes else { throw HTTPFailure(status: 431) }
            if header.isEmpty { break }
            guard let colon = header.firstIndex(of: ":") else { throw HTTPFailure(status: 400) }
            let name = String(header[..<colon]).lowercased()
            let value = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || "!#$%&'*+-.^_`|~".utf8.contains($0) }),
                  !value.utf8.contains(where: { $0 < 32 && $0 != 9 }), headers[name] == nil else { throw HTTPFailure(status: 400) }
            headers[name] = value
        }
        guard let host = headers["host"], !host.contains("/"), !host.contains("@"), !host.contains("\\"),
              let url = URL(string: "\(tls ? "https" : "http")://\(host)\(words[1])"), url.host != nil else { throw HTTPFailure(status: 400) }
        var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if origin.port == nil, let localPort { origin.port = Int(localPort) }
        guard headers["transfer-encoding"] == nil || headers["content-length"] == nil else { throw HTTPFailure(status: 400) }
        chunked = headers["transfer-encoding"]?.lowercased() == "chunked"
        if headers["transfer-encoding"] != nil, !chunked { throw HTTPFailure(status: 400) }
        remaining = 0
        if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(length) else { throw HTTPFailure(status: 400) }
            guard n <= configuration.maximumBodyBytes else { throw HTTPFailure(status: 413) }
            remaining = n
        }
        total = 0; chunkRemaining = 0; needsDelimiter = false; done = !chunked && remaining == 0
        return Request(request: .init(method: method, url: origin.url!, headers: headers), close: headers["connection"]?.lowercased() == "close",
                       expectContinue: headers["expect"]?.lowercased() == "100-continue")
    }
    func bodyChunk() async throws -> Data? {
        if done { return nil }
        if chunked, chunkRemaining == 0 {
            if needsDelimiter {
                guard try await line(limit: 0, status: 400).isEmpty else { throw HTTPFailure(status: 400) }
                needsDelimiter = false
            }
            let size = try await line(limit: configuration.maximumHeaderBytes, status: 400)
            let text = size.split(separator: ";", omittingEmptySubsequences: false)[0]
            guard !text.isEmpty, text.allSatisfy(\.isHexDigit), let n = Int(text, radix: 16) else { throw HTTPFailure(status: 400) }
            guard n <= configuration.maximumBodyBytes - total else { throw DicomWebHTTPBodyError.payloadTooLarge }
            if n == 0 {
                var trailerBytes = 0
                while true {
                    let trailer = try await line(limit: configuration.maximumHeaderBytes - trailerBytes)
                    trailerBytes += trailer.utf8.count + 2
                    guard trailerBytes <= configuration.maximumHeaderBytes else { throw HTTPFailure(status: 431) }
                    if trailer.isEmpty { break }
                    guard trailer.contains(":"), !trailer.hasPrefix(" "), !trailer.hasPrefix("\t") else { throw HTTPFailure(status: 400) }
                }
                done = true; return nil
            }
            chunkRemaining = n
        }
        if buffer.isEmpty { try await fill() }
        let count = min(buffer.count, min(64 * 1024, chunked ? chunkRemaining : remaining))
        let data = Data(buffer.prefix(count)); buffer = Data(buffer.dropFirst(count))
        total += count
        if chunked { chunkRemaining -= count; needsDelimiter = chunkRemaining == 0 }
        else { remaining -= count; done = remaining == 0 }
        return data
    }
}
