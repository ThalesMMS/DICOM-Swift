import Foundation

/// Shared, fixed diagnostics: the description never includes response bodies, identifiers, URLs or query values.
/// What the server said about a refused status travels apart, in `retryAfter`, `warning` and `bodyPreview`, for a
/// caller that chooses to show or act on it.
public struct DicomWebError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case badRequest, unauthorized, forbidden, notFound, notAcceptable, conflict
        case unsupportedMediaType, tooLarge, server, invalidResponse, originDenied
    }
    public let kind: Kind
    public let statusCode: Int
    public let code: String?
    /// Seconds the server asked to wait before trying again (`Retry-After`, given in seconds or as an HTTP date).
    public private(set) var retryAfter: TimeInterval? = nil
    /// The response's `Warning` header.
    public private(set) var warning: String? = nil
    /// The start of the response body, at most 4 KiB, with every credential the client sent and every
    /// credential-like header line removed.
    public private(set) var bodyPreview: String? = nil
    /// Every Accept a retrieve with a `DicomWebAcceptList` sent, in order, when it ended on a fallback status: every
    /// range refused, or a 500 the list does not move on from; nil otherwise. They hold media types and transfer
    /// syntax UIDs only.
    public internal(set) var attemptedAccepts: [String]? = nil
    public var errorDescription: String? { "DICOMweb \(kind.rawValue) (HTTP \(statusCode))." }
    /// Leaves the server's text out, so an interpolated or logged error carries no body.
    public var description: String {
        "DicomWebError(kind: \(kind.rawValue), statusCode: \(statusCode), code: \(code ?? "nil"), "
            + "retryAfter: \(retryAfter.map { String($0) } ?? "nil")"
            + (attemptedAccepts.map { ", attemptedAccepts: [\($0.joined(separator: " | "))]" } ?? "") + ")"
    }
    public init(kind: Kind, statusCode: Int? = nil, code: String? = nil) {
        self.kind = kind
        self.code = code
        self.statusCode = statusCode ?? Self.defaultStatus(kind)
    }
    public init(statusCode: Int, code: String? = nil) {
        let kind: Kind
        switch statusCode {
        case 400: kind = .badRequest
        case 401: kind = .unauthorized
        case 403: kind = .forbidden
        case 404: kind = .notFound
        case 406: kind = .notAcceptable
        case 409: kind = .conflict
        case 413: kind = .tooLarge
        case 415: kind = .unsupportedMediaType
        default: kind = .server
        }
        self.init(kind: kind, statusCode: statusCode, code: code)
    }
    private static func defaultStatus(_ kind: Kind) -> Int {
        switch kind {
        case .badRequest: 400
        case .unauthorized: 401
        case .forbidden, .originDenied: 403
        case .notFound: 404
        case .notAcceptable: 406
        case .conflict: 409
        case .tooLarge: 413
        case .unsupportedMediaType: 415
        case .server: 500
        case .invalidResponse: 502
        }
    }

    /// The error for a response whose status the client refused, with the server's diagnostics. `body` is the start
    /// of the response body; `credentials` are the headers the client sent that must not come back in the preview.
    init(statusCode: Int, headers: [String: String], body: Data, credentials: [String: String], now: Date = Date()) {
        self.init(statusCode: statusCode, code: headers.dicomWebHeaderValue("X-DICOMweb-Error-Code"))
        retryAfter = headers.dicomWebHeaderValue("Retry-After").flatMap { Self.retryAfter($0, now: now) }
        warning = headers.dicomWebHeaderValue("Warning")
        let preview = Self.sanitizedPreview(body, credentials: credentials)
        bodyPreview = preview.isEmpty ? nil : preview
    }

    static let maximumBodyPreviewBytes = 4 * 1024

    /// `Retry-After` as delta-seconds or an HTTP date (RFC 9110 10.2.3); a date already past means no wait.
    static func retryAfter(_ value: String, now: Date) -> TimeInterval? {
        let value = value.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty, value.allSatisfy(\.isASCIIDigit) { return TimeInterval(value) }
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }

    /// Response bytes read for a preview: the preview, plus room for a credential that straddles its end.
    static let bodyPreviewReadBytes = 2 * maximumBodyPreviewBytes

    /// `body` as text, without the values of `credentials` and without the value of any credential header the server
    /// echoed (`Authorization: …`, `"Cookie": "…"`), cut to `maximumBodyPreviewBytes`. Redaction runs before the cut,
    /// so a credential that crosses the limit is not left in part.
    static func sanitizedPreview(_ body: Data, credentials: [String: String]) -> String {
        var text = String(decoding: body.prefix(bodyPreviewReadBytes), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        var secrets: Set<String> = []
        for value in credentials.values {
            secrets.insert(value)
            // "Bearer <token>" or "Basic <credentials>": the server may echo the second word alone.
            if let space = value.firstIndex(of: " ") { secrets.insert(String(value[value.index(after: space)...])) }
        }
        for secret in secrets.sorted(by: { $0.count > $1.count })
        where secret.trimmingCharacters(in: .whitespaces).count >= 4 {
            text = text.replacingOccurrences(of: secret, with: "[redacted]")
        }
        let names = Set(credentials.keys.map { $0.lowercased() })
            .union(["authorization", "proxy-authorization", "cookie", "set-cookie"])
            .map(NSRegularExpression.escapedPattern(for:)).sorted().joined(separator: "|")
        if let expression = try? NSRegularExpression(pattern: "(?i)((?:\(names))\"?\\s*[:=]\\s*)(\"[^\"]*\"|[^\\r\\n]*)") {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                       withTemplate: "$1[redacted]")
        }
        guard text.utf8.count > maximumBodyPreviewBytes else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maximumBodyPreviewBytes)
        while UTF8.isContinuation(text.utf8[end]) { end = text.utf8.index(before: end) }
        return String(text[..<end])
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
