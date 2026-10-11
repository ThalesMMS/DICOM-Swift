import Foundation
import XCTest
@testable import DicomData

/// Issue #3038: the ISO 2022 names of the local corpus whose readers disagreed, rebuilt from the bytes of
/// PS3.5 Annex H and I. The expected characters come from the repertoires' tables, never from another decoder:
/// JIS X 0201 katakana 0xA1...0xDF is U+FF61...U+FF9F, JIS X 0201 roman is ASCII except 0x5C (YEN SIGN) and
/// 0x7E (OVERLINE), JIS X 0208 row 4 cell c is hiragana U+3040 + c, and the kanji and Hangul are the ones the
/// Annex examples print next to their bytes.
final class DicomISO2022CorpusNameTests: XCTestCase {
    private static let jisX0201AndJISX0208 = ["ISO 2022 IR 13", "ISO 2022 IR 87"]

    /// PS3.5 H.3.2 (corpus `chrH32.dcm`, SHA-256 de42af715ac11d70…): half-width katakana in G1 for the alphabetic
    /// group, then JIS X 0208 kanji and hiragana, each returning to JIS X 0201 roman (ESC ( J) before `^` and `=`.
    private static let annexH32Name: [UInt8] = [
        0xD4, 0xCF, 0xC0, 0xDE, 0x5E, 0xC0, 0xDB, 0xB3, 0x3D,
        0x1B, 0x24, 0x42, 0x3B, 0x33, 0x45, 0x44, 0x1B, 0x28, 0x4A, 0x5E,
        0x1B, 0x24, 0x42, 0x42, 0x40, 0x4F, 0x3A, 0x1B, 0x28, 0x4A, 0x3D,
        0x1B, 0x24, 0x42, 0x24, 0x64, 0x24, 0x5E, 0x24, 0x40, 0x1B, 0x28, 0x4A, 0x5E,
        0x1B, 0x24, 0x42, 0x24, 0x3F, 0x24, 0x6D, 0x24, 0x26, 0x1B, 0x28, 0x4A
    ]

    private static var annexH32Expected: String {
        katakana([0xD4, 0xCF, 0xC0, 0xDE]) + "^" + katakana([0xC0, 0xDB, 0xB3]) + "="
            + "\u{5C71}\u{7530}" + "^" + "\u{592A}\u{90CE}" + "="
            + hiragana([0x64, 0x5E, 0x40]) + "^" + hiragana([0x3F, 0x6D, 0x26])
    }

    func test_alphabeticKatakanaName_decodesToTheJISX0201AndJISX0208Characters() throws {
        XCTAssertEqual(Self.annexH32Expected, "ﾔﾏﾀﾞ^ﾀﾛｳ=山田^太郎=やまだ^たろう")
        let charset = DicomSpecificCharacterSet(definedTerms: Self.jisX0201AndJISX0208)
        XCTAssertEqual(try charset.decodeValidated(Data(Self.annexH32Name), vr: .PN), Self.annexH32Expected)
        let wire = Self.element(0x0008_0005, "CS", Array("ISO 2022 IR 13\\ISO 2022 IR 87".utf8))
            + Self.element(0x0010_0010, "PN", Self.annexH32Name)
        XCTAssertEqual(try DicomDataSetParser.dataSet(from: wire)[.patientName]?.stringValue, Self.annexH32Expected)
        XCTAssertEqual(try DicomDataSetParser.read(from: wire).dataSet[.patientName]?.stringValue, Self.annexH32Expected)
        // Without the return to roman before `^`, the kanji designation would leak into the next component.
        var unreset = Self.annexH32Name
        unreset.removeSubrange(16 ..< 19)
        XCTAssertThrowsError(try charset.decodeValidated(Data(unreset), vr: .PN))
    }

    /// Corpus `J2K_pixelrep_mismatch.dcm` (2df92c523d36639e…, three copies): the same declaration with values
    /// that stay in the JIS X 0201 roman G0. Letters and digits are ASCII; 0x5C separates values outside
    /// LT/ST/UT and is YEN SIGN inside them; 0x7E is OVERLINE.
    func test_romajiValues_keepTheirLettersAndTheYenAndOverlineOfJISX0201() throws {
        let charset = DicomSpecificCharacterSet(definedTerms: Self.jisX0201AndJISX0208)
        XCTAssertEqual(try charset.decodeValidated(Data("SYN0201^ROMAJI".utf8), vr: .PN), "SYN0201^ROMAJI")
        let wire = Self.element(0x0008_0005, "CS", Array("ISO 2022 IR 13\\ISO 2022 IR 87".utf8))
            + Self.element(0x0008_103E, "LO", Array("Lv2".utf8))
            + Self.element(0x0010_0010, "PN", Array("SYN0201^ROMAJI".utf8))
            + Self.element(0x0010_1001, "PN", Array("SYN^A\\SYN^B".utf8))
            + Self.element(0x0010_4000, "LT", [0x41, 0x5C, 0x42, 0x7E])
        for dataSet in [try DicomDataSetParser.dataSet(from: wire), try DicomDataSetParser.read(from: wire).dataSet] {
            XCTAssertEqual(dataSet[.patientName]?.stringValue, "SYN0201^ROMAJI")
            XCTAssertEqual(dataSet.element(for: 0x0008_103E)?.stringValue, "Lv2")
            XCTAssertEqual(dataSet.element(for: 0x0010_1001)?.stringValues, ["SYN^A", "SYN^B"])
            XCTAssertEqual(dataSet.element(for: 0x0010_4000)?.stringValue, "A\u{00A5}B\u{203E}")
        }
    }

    /// Corpus `chrSQEncoding.dcm` (b124a74bcf2f258e…): a UTF-8 data set whose sequence item declares
    /// JIS X 0201 and JIS X 0208 for its own name. The item's characters follow its declaration; the parent's do not.
    func test_itemDeclaringJISX0201_decodesItsNameByItsOwnDeclaration() throws {
        let item = Self.element(0x0008_0005, "CS", Array("ISO 2022 IR 13\\ISO 2022 IR 87".utf8))
            + Self.element(0x0010_0010, "PN", Self.annexH32Name)
        let wire = Self.element(0x0008_0005, "CS", Array("ISO_IR 192".utf8))
            + Self.element(0x0032_1032, "PN", Array("Doctor^Who^^MD".utf8))
            + Self.sequence(0x0032_1064, items: [item])
        for dataSet in [try DicomDataSetParser.dataSet(from: wire), try DicomDataSetParser.read(from: wire).dataSet] {
            XCTAssertEqual(dataSet.element(for: 0x0032_1032)?.stringValue, "Doctor^Who^^MD")
            let child = dataSet.element(for: 0x0032_1064)?.sequenceItems.first?.dataSet
            XCTAssertEqual(child?[.patientName]?.stringValue, Self.annexH32Expected)
        }
    }

    /// Corpus `chrKoreanMulti.dcm` (f07d6193310e593f…): a Hangul name written in the alphabetic group with the
    /// KS X 1001 designation of PS3.5 I.2 (here the I.2 phonetic group `홍^길동`). A validated read refuses the
    /// escape there; the compatibility read the import uses gives the KS X 1001 characters, not Latin-1 bytes.
    func test_hangulInTheAlphabeticGroup_compatibilityReadGivesTheKSX1001Characters() throws {
        let name: [UInt8] = [0x1B, 0x24, 0x29, 0x43, 0xC8, 0xAB, 0x5E, 0x1B, 0x24, 0x29, 0x43, 0xB1, 0xE6, 0xB5, 0xBF]
        let expected = "\u{D64D}^\u{AE38}\u{B3D9}"
        XCTAssertEqual(expected, "홍^길동")
        let charset = DicomSpecificCharacterSet(definedTerms: ["", "ISO 2022 IR 149"])
        XCTAssertThrowsError(try charset.decodeValidated(Data(name), vr: .PN))
        XCTAssertEqual(charset.decode(Data(name), vr: .PN), expected)
        let wire = Self.element(0x0008_0005, "CS", Array("\\ISO 2022 IR 149".utf8)) + Self.element(0x0010_0010, "PN", name)
        XCTAssertEqual(try DicomDataSetParser.dataSet(from: wire)[.patientName]?.stringValue, expected)
        // The same group written as PS3.5 I.2 writes it (ideographic and phonetic only) reads strictly as before.
        let annex: [UInt8] = Array("Hong^Gildong=".utf8) + [0x1B, 0x24, 0x29, 0x43, 0xFB, 0xF3, 0x5E,
                                                            0x1B, 0x24, 0x29, 0x43, 0xD1, 0xCE, 0xD4, 0xD7, 0x3D] + name
        XCTAssertEqual(try charset.decodeValidated(Data(annex), vr: .PN), "Hong^Gildong=\u{6D2A}^\u{5409}\u{6D1E}=" + expected)
    }

    /// Corpus `CS_ISO_2022_IR_58.dcm` (f65b33d2869f0248…): a lone `ISO 2022 IR 58`, so GB 2312 sits in GR with no
    /// designation. Here the ideographic group of the PS3.5 Annex J name `Wang^XiaoDong=王^小东=`, whose GB 2312
    /// row-cell codes 45-85, 48-01 and 22-75 are the EUC bytes CD F5, D0 A1 and B6 AB. A validated read refuses the
    /// declaration; the compatibility read gives the GB 2312 characters instead of Latin-1 bytes.
    func test_gb2312UnderALoneIR58_compatibilityReadGivesTheGB2312Characters() throws {
        let name: [UInt8] = [0xCD, 0xF5, 0x5E, 0xD0, 0xA1, 0xB6, 0xAB]
        let expected = "\u{738B}^\u{5C0F}\u{4E1C}"
        XCTAssertEqual(expected, "王^小东")
        let charset = DicomSpecificCharacterSet("ISO 2022 IR 58")
        XCTAssertThrowsError(try charset.decodeValidated(Data(name), vr: .PN))
        XCTAssertEqual(charset.decode(Data(name), vr: .PN), expected)
        let wire = Self.element(0x0008_0005, "CS", Array("ISO 2022 IR 58".utf8)) + Self.element(0x0010_0010, "PN", name)
        XCTAssertEqual(try DicomDataSetParser.dataSet(from: wire)[.patientName]?.stringValue, expected)
    }

    // MARK: - Helpers

    private static func katakana(_ bytes: [UInt8]) -> String {
        String(String.UnicodeScalarView(bytes.compactMap { Unicode.Scalar(0xFF61 + UInt32($0) - 0xA1) }))
    }

    private static func hiragana(_ cells: [UInt8]) -> String {
        String(String.UnicodeScalarView(cells.compactMap { Unicode.Scalar(0x3040 + UInt32($0) - 0x20) }))
    }

    /// One Explicit VR Little Endian element with a 16-bit length, its value padded with a space to even length.
    private static func element(_ tag: Int, _ vr: String, _ value: [UInt8]) -> Data {
        let padded = value.count.isMultiple(of: 2) ? value : value + [0x20]
        var data = Data([UInt8(tag >> 16 & 0xFF), UInt8(tag >> 24 & 0xFF), UInt8(tag & 0xFF), UInt8(tag >> 8 & 0xFF)])
        data.append(contentsOf: Array(vr.utf8))
        data.append(contentsOf: [UInt8(padded.count & 0xFF), UInt8(padded.count >> 8 & 0xFF)])
        data.append(contentsOf: padded)
        return data
    }

    /// A defined-length sequence of defined-length items.
    private static func sequence(_ tag: Int, items: [Data]) -> Data {
        func length(_ count: Int) -> [UInt8] { (0 ..< 4).map { UInt8(count >> ($0 * 8) & 0xFF) } }
        let body = items.reduce(into: Data()) { body, item in
            body.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0] + length(item.count))
            body.append(item)
        }
        var data = Data([UInt8(tag >> 16 & 0xFF), UInt8(tag >> 24 & 0xFF), UInt8(tag & 0xFF), UInt8(tag >> 8 & 0xFF)])
        data.append(contentsOf: Array("SQ".utf8) + [0, 0] + length(body.count))
        data.append(body)
        return data
    }
}
