import Foundation

/// Designations from PS3.3 C.12-3/C.12-4. Foundation supplies character mapping
/// only; DICOM invocation, delimiters and escape validation are handled separately.
enum DicomISO2022Repertoire: Int, CaseIterable {
    case ascii = 6, katakana = 13, romaji = 14, kanji = 87, supplementaryKanji = 159
    case latin1 = 100, latin2 = 101, latin3 = 109, latin4 = 110, cyrillic = 144
    case arabic = 127, greek = 126, hebrew = 138, latin5 = 148, thai = 166, latin9 = 203
    case korean = 149, chinese = 58

    var isG0: Bool { [.ascii, .romaji, .kanji, .supplementaryKanji].contains(self) }
    var width: Int { [.kanji, .supplementaryKanji, .korean, .chinese].contains(self) ? 2 : 1 }
    var escape: [UInt8] {
        switch self {
        case .ascii: [0x1B, 0x28, 0x42]
        case .romaji: [0x1B, 0x28, 0x4A]
        case .katakana: [0x1B, 0x29, 0x49]
        case .kanji: [0x1B, 0x24, 0x42]
        case .supplementaryKanji: [0x1B, 0x24, 0x28, 0x44]
        case .korean: [0x1B, 0x24, 0x29, 0x43]
        case .chinese: [0x1B, 0x24, 0x29, 0x41]
        case .latin1: [0x1B, 0x2D, 0x41]
        case .latin2: [0x1B, 0x2D, 0x42]
        case .latin3: [0x1B, 0x2D, 0x43]
        case .latin4: [0x1B, 0x2D, 0x44]
        case .cyrillic: [0x1B, 0x2D, 0x4C]
        case .arabic: [0x1B, 0x2D, 0x47]
        case .greek: [0x1B, 0x2D, 0x46]
        case .hebrew: [0x1B, 0x2D, 0x48]
        case .latin5: [0x1B, 0x2D, 0x4D]
        case .thai: [0x1B, 0x2D, 0x54]
        case .latin9: [0x1B, 0x2D, 0x62]
        }
    }

    private var encoding: String.Encoding {
        switch self {
        case .ascii, .romaji: .ascii
        case .katakana: .shiftJIS
        case .kanji: .japaneseEUC
        case .supplementaryKanji: Self.encoding(.ISO_2022_JP_2)
        case .korean: Self.encoding(.EUC_KR)
        case .chinese: Self.encoding(.EUC_CN)
        case .latin1: .isoLatin1
        case .latin2: .isoLatin2
        case .latin3: Self.encoding(.isoLatin3)
        case .latin4: Self.encoding(.isoLatin4)
        case .cyrillic: Self.encoding(.isoLatinCyrillic)
        case .arabic: Self.encoding(.isoLatinArabic)
        case .greek: Self.encoding(.isoLatinGreek)
        case .hebrew: Self.encoding(.isoLatinHebrew)
        case .latin5: Self.encoding(.isoLatin5)
        case .thai: Self.encoding(.isoLatinThai)
        case .latin9: Self.encoding(.isoLatin9)
        }
    }

    func decode(_ bytes: [UInt8]) -> String? {
        guard bytes.count == width else { return nil }
        let range: ClosedRange<UInt8> = isG0 ? 0x21...0x7E : (width == 2 ? 0xA1...0xFE : 0xA0...0xFF)
        guard bytes.allSatisfy(range.contains) else { return nil }
        if self == .romaji, bytes == [0x5C] { return "¥" }
        if self == .romaji, bytes == [0x7E] { return "‾" }
        if self == .katakana, !(0xA1...0xDF).contains(bytes[0]) { return nil }
        var mapped = bytes
        if self == .kanji { mapped = bytes.map { $0 | 0x80 } }
        if self == .supplementaryKanji { mapped = escape + bytes + Self.ascii.escape }
        return String(data: Data(mapped), encoding: encoding)
    }

    func encode(_ scalar: Unicode.Scalar) -> [UInt8]? {
        if self == .romaji, scalar == "¥" { return [0x5C] }
        if self == .romaji, scalar == "‾" { return [0x7E] }
        guard let data = String(scalar).data(using: encoding, allowLossyConversion: false) else { return nil }
        var bytes = Array(data)
        if self == .supplementaryKanji {
            guard bytes.count == 9, bytes.starts(with: escape), bytes.suffix(3).elementsEqual(Self.ascii.escape) else { return nil }
            bytes = Array(bytes[4..<6])
        }
        if self == .kanji {
            guard bytes.count == 2, bytes.allSatisfy({ (0xA1...0xFE).contains($0) }) else { return nil }
            bytes = bytes.map { $0 & 0x7F }
        }
        guard decode(bytes) == String(scalar) else { return nil }
        return bytes
    }

    private static func encoding(_ value: CFStringEncodings) -> String.Encoding {
        .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
    }
}
