import Foundation

public struct DicomSpecificCharacterSet: Equatable, Hashable, Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case unsupportedDeclaration
        case invalidEncodedText
        case unrepresentableText
    }
    public let definedTerms: [String]

    public static let defaultCharacterSet = DicomSpecificCharacterSet(definedTerms: ["ISO_IR 6"])

    public init(_ rawValue: String?) {
        let terms = rawValue?
            .components(separatedBy: "\\")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))) }
            ?? []
        self.init(definedTerms: terms)
    }

    public init(definedTerms: [String]) {
        let terms = definedTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))) }
        self.definedTerms = terms.allSatisfy(\.isEmpty) ? ["ISO_IR 6"] : terms
    }

    public var usesISO2022: Bool {
        normalizedTerms.contains { $0.hasPrefix("ISO 2022") }
    }

    package func decode(_ data: Data, vr: DicomVR = .LO) -> String {
        guard !data.isEmpty else { return "" }
        if let value = try? decodeValidated(data, vr: vr) { return normalize(value) }
        for encoding in decodingCandidates {
            if let value = String(data: data, encoding: encoding) {
                return normalize(value)
            }
        }
        return normalize(String(decoding: data, as: UTF8.self))
    }

    /// Decodes a text VR whose whitespace is part of the value. The caller is
    /// responsible for removing the single DICOM padding byte, if present.
    package func decodePreservingWhitespace(_ data: Data, vr: DicomVR = .UT) -> String {
        guard !data.isEmpty else { return "" }
        if let value = try? decodeValidated(data, vr: vr) { return value }
        for encoding in decodingCandidates {
            if let value = String(data: data, encoding: encoding) {
                return value.precomposedStringWithCanonicalMapping
            }
        }
        return String(decoding: data, as: UTF8.self).precomposedStringWithCanonicalMapping
    }

    package func encode(_ value: String) -> Data? {
        value.data(using: primaryEncoding)
    }

    /// Validated decoding never guesses a second encoding or inserts replacement characters.
    public func decodeValidated(_ data: Data) throws -> String {
        try decodeValidated(data, vr: .UT)
    }

    package func decodeValidated(_ data: Data, vr: DicomVR) throws -> String {
        if usesISO2022 || normalizedTerms == ["ISO_IR 13"] {
            return try DicomISO2022Codec(terms: normalizedTerms).decode(data, vr: vr)
        }
        let encoding = try validatedEncoding()
        if data.contains(0x1B) || (encoding == .ascii && data.contains(where: { $0 >= 0x80 })) {
            throw Failure.invalidEncodedText
        }
        guard let text = String(data: data, encoding: encoding) else { throw Failure.invalidEncodedText }
        return text
    }

    public func encodeValidated(_ value: String) throws -> Data {
        try encodeValidated(value, vr: .UT)
    }

    package func encodeValidated(_ value: String, vr: DicomVR) throws -> Data {
        if usesISO2022 || normalizedTerms == ["ISO_IR 13"] {
            return try DicomISO2022Codec(terms: normalizedTerms).encode(value, vr: vr)
        }
        let encoding = try validatedEncoding()
        guard !value.unicodeScalars.contains(where: { $0.value == 0x1B }),
              let bytes = value.data(using: encoding, allowLossyConversion: false),
              String(data: bytes, encoding: encoding) == value else { throw Failure.unrepresentableText }
        return bytes
    }

    package func validateDeclaration() throws {
        if usesISO2022 || normalizedTerms == ["ISO_IR 13"] { _ = try DicomISO2022Codec(terms: normalizedTerms) }
        else { _ = try validatedEncoding() }
    }

    private func validatedEncoding() throws -> String.Encoding {
        let terms = normalizedTerms.map { $0.isEmpty && usesISO2022 ? "ISO 2022 IR 6" : $0 }
        if terms == ["ISO_IR 6"] || terms == ["ISO 2022 IR 6"] { return .ascii }
        let single = ["ISO_IR 192", "ISO_IR 100", "ISO_IR 101", "ISO_IR 109", "ISO_IR 110", "ISO_IR 144",
                      "ISO_IR 127", "ISO_IR 126", "ISO_IR 138", "ISO_IR 148", "ISO_IR 166", "ISO_IR 203", "GB18030", "GBK"]
        if terms.count == 1, single.contains(terms[0]) {
            if terms[0] == "GBK" { return Self.coreFoundationEncoding(.GBK_95) }
            return primaryEncoding
        }
        throw Failure.unsupportedDeclaration
    }

    private var normalizedTerms: [String] {
        definedTerms.map { $0.uppercased() }
    }

    private var primaryEncoding: String.Encoding {
        let terms = normalizedTerms

        if terms.contains("ISO_IR 192") {
            return .utf8
        }
        if terms.contains("GB18030") || terms.contains("GBK") {
            return Self.coreFoundationEncoding(.GB_18030_2000)
        }
        if terms.contains("ISO_IR 100") {
            return .isoLatin1
        }
        if terms.contains("ISO_IR 101") {
            return .isoLatin2
        }
        if terms.contains("ISO_IR 109") {
            return Self.coreFoundationEncoding(.isoLatin3)
        }
        if terms.contains("ISO_IR 110") {
            return Self.coreFoundationEncoding(.isoLatin4)
        }
        if terms.contains("ISO_IR 144") {
            return Self.coreFoundationEncoding(.isoLatinCyrillic)
        }
        if terms.contains("ISO_IR 127") {
            return Self.coreFoundationEncoding(.isoLatinArabic)
        }
        if terms.contains("ISO_IR 126") {
            return Self.coreFoundationEncoding(.isoLatinGreek)
        }
        if terms.contains("ISO_IR 138") {
            return Self.coreFoundationEncoding(.isoLatinHebrew)
        }
        if terms.contains("ISO_IR 148") {
            return Self.coreFoundationEncoding(.isoLatin5)
        }
        if terms.contains("ISO_IR 203") {
            return Self.coreFoundationEncoding(.isoLatin9)
        }
        if terms.contains("ISO_IR 166") {
            return Self.coreFoundationEncoding(.isoLatinThai)
        }
        if terms.contains(where: { $0 == "ISO 2022 IR 13" || $0 == "ISO 2022 IR 87" || $0 == "ISO 2022 IR 159" }) {
            return .iso2022JP
        }
        if terms.contains("ISO_IR 13") {
            return .shiftJIS
        }
        if terms == ["ISO_IR 6"] || terms == ["ISO 2022 IR 6"] {
            return .ascii
        }
        return .utf8
    }

    private static func coreFoundationEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    private var decodingCandidates: [String.Encoding] {
        let candidates = [primaryEncoding, .utf8, .isoLatin1]
        var seen = Set<UInt>()
        return candidates.filter { seen.insert($0.rawValue).inserted }
    }

    private func normalize(_ value: String) -> String {
        var string = value
        if let nullIndex = string.firstIndex(of: "\0") {
            string = String(string[..<nullIndex])
        }
        return string
            .trimmingCharacters(in: .whitespaces)
            .precomposedStringWithCanonicalMapping
    }
}

public enum DicomTextSanitizer {
    public static func sanitizedForDisplay(_ value: String) -> String {
        var result = String.UnicodeScalarView()
        var lastInsertedSpace = false

        for scalar in value.unicodeScalars {
            if scalar.value == 0 ||
                (0x0001...0x001F).contains(scalar.value) ||
                (0x007F...0x009F).contains(scalar.value) {
                if !lastInsertedSpace {
                    result.append(" ")
                    lastInsertedSpace = true
                }
            } else {
                result.append(scalar)
                lastInsertedSpace = scalar == " "
            }
        }

        return String(result)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }
}

public extension DicomDataElement {
    var sanitizedStringValue: String? {
        stringValue.map(DicomTextSanitizer.sanitizedForDisplay)
    }

    var sanitizedStringValues: [String] {
        stringValues.map(DicomTextSanitizer.sanitizedForDisplay)
    }
}

public extension DicomDataSet {
    func sanitizedString(for tag: Int) -> String? {
        element(for: tag)?.sanitizedStringValue
    }

    func sanitizedString(for tag: DicomTag) -> String? {
        sanitizedString(for: tag.rawValue)
    }

    func sanitizedStrings(for tag: Int) -> [String] {
        element(for: tag)?.sanitizedStringValues ?? []
    }

    func sanitizedStrings(for tag: DicomTag) -> [String] {
        sanitizedStrings(for: tag.rawValue)
    }
}
