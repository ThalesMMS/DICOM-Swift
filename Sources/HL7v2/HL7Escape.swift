import Foundation

public enum HL7Escape {
    public struct Result: Equatable, Sendable {
        public let text: String
        public let diagnostics: [HL7Diagnostic]
    }

    public static func escape(_ text: String, encoding: HL7EncodingCharacters = .standard,
                              charset: HL7Charset = .utf8) -> String {
        let replacements: [Character: String] = [encoding.field: "F", encoding.component: "S",
            encoding.subcomponent: "T", encoding.repetition: "R", encoding.escape: "E"]
        return text.map { character in
            if let token = replacements[character] { return "\(encoding.escape)\(token)\(encoding.escape)" }
            if character.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
               let data = charset.encode(String(character)) {
                return hex(data, encoding: encoding)
            }
            return String(character)
        }.joined()
    }

    static func hex(_ bytes: Data, encoding: HL7EncodingCharacters) -> String {
        "\(encoding.escape)X" + bytes.map { String(format: "%02X", $0) }.joined() + String(encoding.escape)
    }

    public static func unescape(_ text: String, encoding: HL7EncodingCharacters = .standard,
                                charset: HL7Charset = .utf8, path: HL7Path? = nil) -> Result {
        var output = ""
        var diagnostics: [HL7Diagnostic] = []
        var cursor = text.startIndex
        let replacements: [String: Character] = ["F": encoding.field, "S": encoding.component,
            "T": encoding.subcomponent, "R": encoding.repetition, "E": encoding.escape]
        while cursor < text.endIndex {
            guard text[cursor] == encoding.escape else {
                output.append(text[cursor]); cursor = text.index(after: cursor); continue
            }
            let start = text.index(after: cursor)
            guard let end = text[start...].firstIndex(of: encoding.escape) else {
                output += text[cursor...]
                diagnostics.append(HL7Diagnostic(code: .unknownEscape, path: path, lengths: [text[cursor...].utf8.count]))
                break
            }
            let token = String(text[start..<end])
            let raw = String(text[cursor...end])
            if let character = replacements[token] { output.append(character) }
            else if token.hasPrefix("X"), let data = hexBytes(String(token.dropFirst())),
                    let decoded = charset.decode(data) { output += decoded }
            else {
                output += raw
                let code: HL7Diagnostic.Code?
                if token.hasPrefix("C") || token.hasPrefix("M") { code = .charsetSwitchIgnored }
                else if token == "H" || token == "N" || token.hasPrefix("Z") || token.hasPrefix(".") { code = nil }
                else { code = .unknownEscape }
                if let code { diagnostics.append(HL7Diagnostic(code: code, path: path, lengths: [raw.utf8.count])) }
            }
            cursor = text.index(after: end)
        }
        return Result(text: output, diagnostics: diagnostics)
    }

    private static func hexBytes(_ text: String) -> Data? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count % 2 == 0 else { return nil }
        guard bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        var result = Data()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let value = UInt8(String(decoding: bytes[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            result.append(value)
        }
        return result
    }
}
