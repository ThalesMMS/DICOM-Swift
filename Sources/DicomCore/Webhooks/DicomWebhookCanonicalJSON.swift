import Foundation

public enum DicomWebhookCanonicalJSON {
    /// UTF-8 JSON; keys use JSONEncoder sortedKeys ordering, no insignificant whitespace,
    /// RFC 8259 string escaping with literal Unicode and unescaped slashes. Object nulls
    /// are omitted recursively; array nulls retain their positions. Dates are UTC ISO-8601
    /// whole seconds. JSONEncoder numeric tokens are expanded to plain decimal notation.
    /// This is the v1 webhook format, not RFC 8785/JCS.
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter().string(from:
                Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))))
        }
        // Preserve JSONEncoder's numeric tokens: a JSONSerialization/NSNumber round trip
        // can turn 1e-7 into 9.9999999999999995e-8 on Apple Foundation.
        let bytes = Array(try encoder.encode(value))
        var index = 0
        func quotedString() -> String {
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 92 { index += 1 }
                else if byte == 34 { break }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        func compactValue() -> String {
            if bytes[index] == 34 { return quotedString() }
            if bytes[index] == 123 {
                index += 1
                var members = [String]()
                while bytes[index] != 125 {
                    let key = quotedString()
                    index += 1 // colon
                    let value = compactValue()
                    if value != "null" { members.append(key + ":" + value) }
                    if bytes[index] == 44 { index += 1 }
                }
                index += 1
                return "{" + members.joined(separator: ",") + "}"
            }
            if bytes[index] == 91 {
                index += 1
                var elements = [String]()
                while bytes[index] != 93 {
                    elements.append(compactValue())
                    if bytes[index] == 44 { index += 1 }
                }
                index += 1
                return "[" + elements.joined(separator: ",") + "]"
            }
            let start = index
            while index < bytes.count && ![44, 93, 125].contains(bytes[index]) { index += 1 }
            return plainDecimal(String(decoding: bytes[start..<index], as: UTF8.self))
        }
        return Data(compactValue().utf8)
    }

    private static func plainDecimal(_ token: String) -> String {
        let parts = token.lowercased().split(separator: "e")
        guard parts.count == 2, let exponent = Int(parts[1]) else { return token }
        let negative = parts[0].hasPrefix("-")
        let mantissa = parts[0].filter { $0 != "-" }
        let decimalPosition = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) }
            ?? mantissa.count
        let digits = mantissa.filter { $0 != "." }
        let position = decimalPosition + exponent
        let magnitude: String
        if position <= 0 { magnitude = "0." + String(repeating: "0", count: -position) + digits }
        else if position >= digits.count { magnitude = digits + String(repeating: "0", count: position - digits.count) }
        else {
            let split = digits.index(digits.startIndex, offsetBy: position)
            magnitude = String(digits[..<split]) + "." + String(digits[split...])
        }
        return (negative ? "-" : "") + magnitude
    }
}
