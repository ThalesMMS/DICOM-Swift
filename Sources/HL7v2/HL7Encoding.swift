import Foundation

public struct HL7EncodingCharacters: Equatable, Sendable {
    public let field: Character
    public let component: Character
    public let repetition: Character
    public let escape: Character
    public let subcomponent: Character
    public let truncation: Character?

    public static let standard = try! Self()

    public init(field: Character = "|", component: Character = "^", repetition: Character = "~",
                escape: Character = "\\", subcomponent: Character = "&", truncation: Character? = nil) throws {
        let characters = [field, component, repetition, escape, subcomponent] + (truncation.map { [$0] } ?? [])
        guard Set(characters).count == characters.count, characters.allSatisfy({ character in
            let bytes = Array(String(character).utf8)
            return bytes.count == 1 && (33...126).contains(bytes[0]) &&
                !(48...57).contains(bytes[0]) && !(65...90).contains(bytes[0]) && !(97...122).contains(bytes[0])
        }) else { throw HL7ParseError.encodingCharacters(HL7Path(segment: "MSH", field: 2)) }
        self.field = field
        self.component = component
        self.repetition = repetition
        self.escape = escape
        self.subcomponent = subcomponent
        self.truncation = truncation
    }

    public init(field: Character, msh2: String) throws {
        let chars = Array(msh2)
        guard chars.count == 4 || chars.count == 5 else {
            throw HL7ParseError.encodingCharacters(HL7Path(segment: "MSH", field: 2))
        }
        try self.init(field: field, component: chars[0], repetition: chars[1], escape: chars[2],
                      subcomponent: chars[3], truncation: chars.count == 5 ? chars[4] : nil)
    }

    public var msh2: String { String([component, repetition, escape, subcomponent] + (truncation.map { [$0] } ?? [])) }
}

public enum HL7Charset: Codable, Equatable, Sendable {
    case ascii, iso8859(Int), utf8, windows1252, unknown(String)

    public init(declaration: String) {
        switch declaration.trimmingCharacters(in: .whitespaces).uppercased() {
        case "", "ASCII": self = .ascii
        case "UNICODE UTF-8", "UTF-8", "UNICODE": self = .utf8
        case "WINDOWS-1252", "WINDOWS 1252", "CP1252": self = .windows1252
        case let name where name.hasPrefix("8859/"):
            if let number = Int(name.dropFirst(5)), (1...9).contains(number) || number == 15 {
                self = .iso8859(number)
            } else { self = .unknown(declaration) }
        default: self = .unknown(declaration)
        }
    }

    public var stringEncoding: String.Encoding {
        switch self {
        case .ascii: .ascii
        case .utf8: .utf8
        case .windows1252: .windowsCP1252
        case .unknown: .isoLatin1
        case .iso8859(1): .isoLatin1
        case .iso8859(2): .isoLatin2
        // Foundation's NSStringEncoding representation of ISO-8859 CF encodings.
        case .iso8859(let number): String.Encoding(rawValue: UInt(0x80000200 + number))
        }
    }

    func decode(_ bytes: Data) -> String? {
        if self == .iso8859(1) || { if case .unknown = self { return true }; return false }() {
            return String(String.UnicodeScalarView(bytes.map { Unicode.Scalar(UInt32($0))! }))
        }
        return String(data: bytes, encoding: stringEncoding)
    }

    func encode(_ text: String) -> Data? {
        if self == .iso8859(1) || { if case .unknown = self { return true }; return false }() {
            guard text.unicodeScalars.allSatisfy({ $0.value <= 255 }) else { return nil }
            return Data(text.unicodeScalars.map { UInt8($0.value) })
        }
        return text.data(using: stringEncoding, allowLossyConversion: false)
    }
}
