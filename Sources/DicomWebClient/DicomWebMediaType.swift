import Foundation

public struct DicomWebMediaType: Equatable, Sendable {
    public let type: String
    public let parameters: [String: String]

    public init(_ value: String) throws {
        let pieces = Self.split(value, separator: ";")
        let type = (pieces.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard type.split(separator: "/").count == 2, !value.utf8.contains(13), !value.utf8.contains(10) else {
            throw DicomWebError(kind: .badRequest)
        }
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw DicomWebError(kind: .badRequest) }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                guard value.count >= 2, value.hasSuffix("\"") else { throw DicomWebError(kind: .badRequest) }
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            guard parameters[key] == nil else { throw DicomWebError(kind: .badRequest) }
            parameters[key] = value
        }
        self.type = type
        self.parameters = parameters
    }

    init(type: String, parameters: [String: String]) {
        self.type = type
        self.parameters = parameters
    }

    /// The value for a header. `type` comes first and is always quoted; `q` comes last, where an Accept weight goes
    /// (RFC 9110 12.5.1); the other parameters follow in name order. A value that is an RFC 9110 token, such as a
    /// transfer syntax UID or `*`, goes unquoted, as dcm4che and dicomweb-client send it: some servers compare the
    /// raw text with the UID.
    public var headerValue: String {
        let order = { (key: String) in key == "type" ? 0 : key == "q" ? 2 : 1 }
        return type + parameters.keys.sorted { (order($0), $0) < (order($1), $1) }.map { key in
            let value = parameters[key]!
            guard key == "type" || !Self.isToken(value) else { return "; \(key)=\(value)" }
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "; \(key)=\"\(escaped)\""
        }.joined()
    }

    /// RFC 9110 5.6.2 `token`.
    private static func isToken(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
        }
    }

    package static func split(_ value: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if character == separator, !quoted { result.append(current); current = ""; continue }
            current.append(character)
            if escaped { escaped = false }
            else if character == "\\", quoted { escaped = true }
            else if character == "\"" { quoted.toggle() }
        }
        result.append(current)
        return result
    }
}
