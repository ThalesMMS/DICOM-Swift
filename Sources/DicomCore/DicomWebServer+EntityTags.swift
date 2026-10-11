import CryptoKit
import Foundation

/// Strong validators and conditional GET for search and retrieve (RFC 9110 §8.8.3, §13.1.2 and §15.4.5, issue
/// #3033). The tag covers the requested resource, the negotiated representation (Content-Type, including the
/// transfer syntax) and the stored data, so it changes with Accept, and every tagged response varies on Accept.
extension DicomWebServer {
    /// A strong entity tag over the request target, the response's Content-Type and `version`. A multipart boundary
    /// is generated per response, so it is left out of the Content-Type.
    func entityTag(for request: DicomWebHTTPRequest, contentType: String?, version: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data((path(request.url) ?? []).joined(separator: "/").utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data((URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? "").utf8))
        hasher.update(data: Data([0]))
        let representation = (contentType ?? "").split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.lowercased().hasPrefix("boundary=") }
            .joined(separator: ";")
        hasher.update(data: Data(representation.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: version)
        return "\"" + hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined() + "\""
    }

    /// Tags a complete 200 response by its body, which is derived from the stored data and the representation. The
    /// per-response multipart boundary is removed from the body first.
    func taggingBody(_ response: DicomWebHTTPResponse, request: DicomWebHTTPRequest) -> DicomWebHTTPResponse {
        guard request.method == .get, response.statusCode == 200 else { return response }
        var response = response
        var version = response.body
        if let boundary = response.headers["Content-Type"]?.split(separator: ";")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.lowercased().hasPrefix("boundary=") })?.dropFirst("boundary=".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")), !boundary.isEmpty {
            let marker = Data(boundary.utf8)
            while let range = version.range(of: marker) { version.removeSubrange(range) }
        }
        response.headers["ETag"] = entityTag(for: request, contentType: response.headers["Content-Type"], version: version)
        response.headers["Vary"] = "Accept"
        return response
    }

    /// The version of a stored instance for a streamed retrieve: its size and a digest of its first and last
    /// 64 KiB, without reading the whole object. A re-stored instance changes its header, length or tail.
    static func entityVersion(of stored: DicomWebStoredInstance) -> Data {
        let window = 64 * 1024
        var hasher = SHA256()
        hasher.update(data: Data(stored.sopInstanceUID.utf8))
        hasher.update(data: withUnsafeBytes(of: UInt64(stored.part10Data.count).bigEndian) { Data($0) })
        hasher.update(data: stored.part10Data.prefix(window))
        hasher.update(data: stored.part10Data.suffix(window))
        return Data(hasher.finalize())
    }

    /// Answers `If-None-Match` after the handler, so authentication and authorization already ran: a match with the
    /// current tag (or `*`) is 304 without a body and the response stream is cancelled unread. Tagged responses
    /// to authenticated requests are private.
    func applyingConditionalGET(_ response: DicomWebHTTPStreamedResponse, request: DicomWebHTTPRequest,
                                authenticated: Bool) -> DicomWebHTTPStreamedResponse {
        guard request.method == .get, response.statusCode == 200, let tag = response.headers["ETag"] else { return response }
        var response = response
        if authenticated { response.headers["Cache-Control"] = "private" }
        guard let condition = request.headers.dicomWebHeaderValue("If-None-Match") else { return response }
        let candidates = condition.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard candidates.contains("*") || candidates.contains(where: { $0 == tag || $0 == "W/" + tag }) else {
            return response
        }
        response.cancel()
        var headers: [String: String] = ["ETag": tag, "Vary": "Accept"]
        headers["Cache-Control"] = response.headers["Cache-Control"]
        return .init(statusCode: 304, headers: headers, body: AsyncThrowingStream { $0.finish() })
    }
}
