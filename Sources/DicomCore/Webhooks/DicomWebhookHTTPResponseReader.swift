import Foundation
import Network

/// Bounded response framing for the dedicated, non-reusing webhook connection.
struct DicomWebhookHTTPResponseReader {
    let connection: NWConnection
    let maximumBodyBytes: Int
    private var buffer = Data()
    private var ended = false
    private let maximumHeaderBytes = 64 * 1024

    init(connection: NWConnection, maximumBodyBytes: Int) {
        self.connection = connection
        self.maximumBodyBytes = maximumBodyBytes
    }

    private mutating func fill() async throws {
        guard !ended else { throw URLError(.badServerResponse) }
        let (data, end) = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(Data, Bool), any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, end, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), end)) }
            }
        }
        buffer.append(data)
        ended = end
    }

    private mutating func line(limit: Int) async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                guard range.lowerBound <= limit, let text = String(data: buffer[..<range.lowerBound], encoding: .isoLatin1) else {
                    throw URLError(.badServerResponse)
                }
                buffer = Data(buffer[range.upperBound...])
                return text
            }
            guard buffer.count <= limit else { throw DicomWebhookTransportError.responseTooLarge }
            try await fill()
        }
    }

    mutating func response() async throws -> DicomWebHTTPResponse {
        var headerBytes = 0
        var status = 0
        var headers: [String: String] = [:]
        repeat {
            let first = try await line(limit: maximumHeaderBytes - headerBytes)
            headerBytes += first.utf8.count + 2
            let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(parts[0]),
                  let code = Int(parts[1]), (100...599).contains(code), code != 101 else { throw URLError(.badServerResponse) }
            status = code
            headers = [:]
            while true {
                let text = try await line(limit: maximumHeaderBytes - headerBytes)
                headerBytes += text.utf8.count + 2
                guard headerBytes <= maximumHeaderBytes else { throw DicomWebhookTransportError.responseTooLarge }
                if text.isEmpty { break }
                guard let colon = text.firstIndex(of: ":"), colon != text.startIndex,
                      !text.hasPrefix(" "), !text.hasPrefix("\t") else { throw URLError(.badServerResponse) }
                let name = text[..<colon].lowercased()
                let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let previous = headers[name] {
                    guard name != "content-length", name != "transfer-encoding" else { throw URLError(.badServerResponse) }
                    headers[name] = previous + ", " + value
                } else { headers[name] = value }
            }
        } while status < 200
        if status == 204 || status == 304 { return .init(statusCode: status, headers: headers) }
        var body = Data()
        if let encoding = headers["transfer-encoding"] {
            guard encoding.lowercased() == "chunked", headers["content-length"] == nil else { throw URLError(.badServerResponse) }
            while true {
                let size = try await line(limit: maximumHeaderBytes)
                let text = size.split(separator: ";", omittingEmptySubsequences: false)[0]
                guard !text.isEmpty, text.allSatisfy(\.isHexDigit), let count = Int(text, radix: 16) else {
                    throw URLError(.badServerResponse)
                }
                if count == 0 {
                    var trailerBytes = 0
                    while true {
                        let trailer = try await line(limit: maximumHeaderBytes - trailerBytes)
                        trailerBytes += trailer.utf8.count + 2
                        guard trailerBytes <= maximumHeaderBytes else { throw DicomWebhookTransportError.responseTooLarge }
                        if trailer.isEmpty { break }
                        guard trailer.contains(":"), !trailer.hasPrefix(" "), !trailer.hasPrefix("\t") else {
                            throw URLError(.badServerResponse)
                        }
                    }
                    break
                }
                try await append(count: count, to: &body)
                guard try await line(limit: 0).isEmpty else { throw URLError(.badServerResponse) }
            }
        } else if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length) else {
                throw URLError(.badServerResponse)
            }
            try await append(count: count, to: &body)
        } else {
            while true {
                guard buffer.count <= maximumBodyBytes - body.count else { throw DicomWebhookTransportError.responseTooLarge }
                body.append(buffer)
                buffer.removeAll()
                if ended { break }
                try await fill()
            }
        }
        return .init(statusCode: status, headers: headers, body: body)
    }

    private mutating func append(count: Int, to body: inout Data) async throws {
        guard count <= maximumBodyBytes - body.count else { throw DicomWebhookTransportError.responseTooLarge }
        var remaining = count
        while remaining > 0 {
            if buffer.isEmpty { try await fill() }
            let size = min(remaining, buffer.count)
            body.append(buffer.prefix(size))
            buffer = Data(buffer.dropFirst(size))
            remaining -= size
        }
    }
}
