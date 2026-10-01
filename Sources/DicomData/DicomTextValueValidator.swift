import Foundation

/// PS3.5 6.2 lexical validation, before trimming can conceal malformed values.
/// Character counts exclude ISO 2022 escapes, already consumed by the charset decoder.
enum DicomTextValueValidator {
    static func validate(_ decoded: String, vr: DicomVR, characterSet: DicomSpecificCharacterSet,
                         purpose: DicomDataSetPurpose, includesPadding: Bool) throws {
        if let reason = failure(decoded, vr: vr, characterSet: characterSet, purpose: purpose, includesPadding: includesPadding) {
            throw reason
        }
    }

    /// `validate` without the throw: a data set of an old scanner fails this for dozens of values,
    /// and the reader calls it for every text value it parses.
    static func failure(_ decoded: String, vr: DicomVR, characterSet: DicomSpecificCharacterSet,
                        purpose: DicomDataSetPurpose, includesPadding: Bool) -> DicomDataSetReadResult.Diagnostic.Reason? {
        var text = decoded
        if includesPadding, text.last == (vr == .UI ? "\0" : " ") { text.removeLast() }
        if decoded.isEmpty { return nil }
        let formattedText = [DicomVR.LT, .ST, .UT].contains(vr)
        guard !text.unicodeScalars.contains(where: { scalar in
            let code = scalar.value
            return (code < 0x20 || (0x7F...0x9F).contains(code))
                && !(formattedText && [0x09, 0x0A, 0x0C, 0x0D].contains(code))
        }) else { return .invalidTextValue }
        let values = formattedText || vr == .UR ? [text] : text.components(separatedBy: "\\")
        if purpose == .query, vr == .UI, values.count > 1,
           values.contains(where: \.isEmpty), !values.allSatisfy(\.isEmpty) {
            return .invalidTextValue
        }
        for value in values {
            guard valid(value, vr: vr, characterSet: characterSet, purpose: purpose) else { return .invalidTextValue }
        }
        if vr == .AE, decoded.allSatisfy({ $0 == " " }) { return .invalidTextValue }
        return nil
    }

    private static func valid(_ value: String, vr: DicomVR, characterSet: DicomSpecificCharacterSet,
                              purpose: DicomDataSetPurpose) -> Bool {
        if value.isEmpty { return true }
        let count = value.unicodeScalars.count
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let query = purpose == .query
        if query, value == "\"\"", [.CS, .DA, .DT, .TM, .UR].contains(vr) { return true }
        switch vr {
        case .AE: return count <= 16 && !trimmed.isEmpty
        case .AS: return matches(value, "[0-9]{3}[DWMY]")
        case .CS: return count <= 16 && matches(value, query ? "[A-Z0-9 _*?]*" : "[A-Z0-9 _]*")
        case .SH: return count <= 16
        case .LO: return count <= 64
        case .ST: return count <= 1024
        case .LT: return count <= 10240
        case .PN: return validPersonName(value, characterSet: characterSet)
        case .DS:
            return count <= 16 && (trimmed.isEmpty || matches(trimmed, "[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([Ee][+-]?[0-9]+)?"))
        case .IS:
            return count <= 12 && (trimmed.isEmpty || (matches(trimmed, "[+-]?[0-9]+") && Int32(trimmed) != nil))
        case .DA, .TM, .DT: return DicomTemporalValueValidator.valid(value, vr: vr, query: query)
        case .UI:
            return count <= 64 && matches(value, "(0|[1-9][0-9]*)(\\.(0|[1-9][0-9]*))*")
        case .UR:
            var uri = value
            while uri.last == " " { uri.removeLast() }
            return matches(uri, "([A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=-]|%[0-9A-Fa-f]{2})+")
        default: return true
        }
    }

    private static func validPersonName(_ value: String, characterSet: DicomSpecificCharacterSet) -> Bool {
        let groups = value.components(separatedBy: "=")
        guard groups.count <= 3 else { return false }
        for (index, group) in groups.enumerated() {
            let delimiterLength = index < groups.count - 1 ? 1 : 0
            guard group.unicodeScalars.count + delimiterLength <= 64,
                  group.filter({ $0 == "^" }).count <= 4 else { return false }
        }
        let firstTerm = characterSet.definedTerms.first?.uppercased() ?? ""
        guard ["ISO_IR 192", "GBK", "GB18030"].contains(firstTerm) else { return true }
        return groups[0].unicodeScalars.allSatisfy {
            (0x20...0x1FFF).contains($0.value) || [0x3001, 0x3002, 0x300C, 0x300D].contains($0.value)
                || (0x3099...0x309C).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: "\\A(?:" + pattern + ")\\z", options: .regularExpression) != nil
    }
}
