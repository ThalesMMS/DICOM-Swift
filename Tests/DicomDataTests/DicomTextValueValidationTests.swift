import Foundation
import XCTest
@testable import DicomData

final class DicomTextValueValidationTests: XCTestCase {
    func test_invalidLexicalValues_strictRejectsAndRecoveryRetainsExactBytes() throws {
        let cases: [(DicomVR, String)] = [
            (.AE, "                 "), (.AE, String(repeating: "A", count: 17)),
            (.AS, "10Y"), (.AS, "001Q"), (.CS, "lowercase"), (.CS, "A\tB"),
            (.SH, String(repeating: "A", count: 17)), (.LO, String(repeating: "A", count: 65)),
            (.LO, "A\0B"), (.UC, "A\nB"), (.ST, String(repeating: "A", count: 1025)),
            (.LT, String(repeating: "A", count: 10241)), (.UT, "A\u{7F}B"),
            (.DS, "1.2.3"), (.DS, "NaN"), (.DS, "1 2"), (.DS, "12345678901234567"),
            (.IS, "2147483648"), (.IS, "-2147483649"), (.IS, "1.0"), (.IS, "1234567890123"),
            (.DA, "20260229"), (.DA, "20261301"), (.DA, " 20260908"), (.DA, "2026.09.08"),
            (.TM, "2400"), (.TM, "126000"), (.TM, "12.123"), (.TM, "120001.1234567"),
            (.DT, "20260908120000-1260"), (.DT, "20260230"), (.DT, "2026090812.3"),
            (.UI, "1.02.3"), (.UI, "1..2"), (.UI, "1.2 "), (.UI, "1\0.2"),
            (.UR, "https://example.test/a b"), (.UR, "a\\b"), (.UR, "a%Q0"),
            (.PN, "A^B^C^D^E^F"), (.PN, "A=B=C=D"), (.PN, String(repeating: "A", count: 65))
        ]
        for (vr, value) in cases {
            let bytes = wire(vr: vr, value: value)
            XCTAssertThrowsError(try DicomDataSetParser.read(from: bytes), "\(vr.code): \(value.count)") { error in
                XCTAssertEqual((error as? DicomDataSetReadResult.Diagnostic)?.reason, .invalidTextValue)
            }
            let recovered = try DicomDataSetParser.read(from: bytes, mode: .recover)
            XCTAssertEqual(recovered.dataSet[0x77771001]?.vr, .UN, vr.code)
            XCTAssertEqual(recovered.dataSet[0x77771001]?.bytesValue, bytes.suffix(from: vr.uses32BitLength ? 12 : 8), vr.code)
            XCTAssertEqual(recovered.diagnostics.map(\.reason), [.invalidTextValue], vr.code)
        }
    }

    func test_validLexicalBoundaries_preservePrecisionAndEmptyComponents() throws {
        let cases: [(DicomVR, String)] = [
            (.AE, "NODE"), (.AS, "001Y"), (.CS, "SOME_VALUE 2"),
            (.SH, String(repeating: "A", count: 16)), (.LO, String(repeating: "A", count: 64)),
            (.DS, "+.12345678901E-2"), (.DS, "1E999"), (.DS, "1\\\\2"),
            (.IS, "-2147483648"), (.IS, "+2147483647"), (.IS, "000000000001"),
            (.DA, "20240229"), (.TM, "12"), (.TM, "120001.123456"), (.TM, "235960"),
            (.DT, "2024"), (.DT, "202402"), (.DT, "20240229125960.123456+1400"), (.DT, "2024-1200"),
            (.UI, "1.2.0.3"), (.UR, "../path?a=%20&b=c#d"),
            (.PN, "A^B^^D^E==C"), (.PN, String(repeating: "A", count: 64)),
            (.ST, " leading\ntext\twith\\slash"), (.UT, "line\r\nnext\u{0C}page")
        ]
        for (vr, value) in cases {
            let parsed = try DicomDataSetParser.read(from: wire(vr: vr, value: value))
            XCTAssertEqual(parsed.dataSet[0x77771001]?.vr, vr, vr.code)
            XCTAssertEqual(parsed.dataSet[0x77771001]?.stringValues.joined(separator: "\\"), value, vr.code)
        }
    }

    func test_personName_countsScalarsAndRestrictsOnlyAlphabeticGroupForUnicode() throws {
        let charset = wire(tag: 0x00080005, vr: .CS, value: "ISO_IR 192")
        for name in ["漢字", "A=漢字=かな=FOUR", String(repeating: "e\u{301}", count: 33),
                     String(repeating: "A", count: 64) + "=漢"] {
            XCTAssertThrowsError(try DicomDataSetParser.read(from: charset + wire(vr: .PN, value: name)))
        }
        for name in ["NAME=漢字=かな", "=漢字", "カタカナ=漢字", String(repeating: "e\u{301}", count: 32)] {
            XCTAssertEqual(try DicomDataSetParser.read(from: charset + wire(vr: .PN, value: name))
                .dataSet[0x77771001]?.stringValues, [name])
        }
        // Length counts characters, not UTF-8 bytes or grapheme clusters.
        XCTAssertNoThrow(try DicomDataSetParser.read(from: charset + wire(vr: .SH, value: String(repeating: "é", count: 16))))
        XCTAssertThrowsError(try DicomDataSetParser.read(from: charset + wire(vr: .SH, value: String(repeating: "e\u{301}", count: 9))))
    }

    func test_queryMatching_requiresExplicitPurposeAndStillRejectsMalformedEndpoints() throws {
        let cases: [(DicomVR, String)] = [
            (.DA, "20240101-20241231"), (.DA, "-20241231"), (.DA, "20240101-"),
            (.TM, "1200-1300"), (.DT, "20240101-0500-20241231+0300"),
            (.DT, "20240101-0500-"), (.CS, "CT*"), (.CS, "C?"),
            (.CS, "\"\""), (.DA, "\"\""), (.TM, "\"\""), (.DT, "\"\""), (.UR, "\"\"")
        ]
        for (vr, value) in cases {
            let bytes = wire(vr: vr, value: value)
            XCTAssertThrowsError(try DicomDataSetParser.read(from: bytes), vr.code)
            XCTAssertNoThrow(try DicomDataSetParser.read(from: bytes, purpose: .query), vr.code)
        }
        for (vr, value) in [(DicomVR.DA, "20240230-20241231"), (.TM, "2500-2600"), (.DT, "2024-9999-2025")] {
            XCTAssertThrowsError(try DicomDataSetParser.read(from: wire(vr: vr, value: value), purpose: .query))
        }
    }

    func test_emptyMultiplicityAndQueryUIDLists_followDatasetPurpose() throws {
        let emptyPN = wire(tag: 0x00100010, vr: .PN, value: "\\\\")
        XCTAssertEqual(try DicomDataSetParser.read(from: emptyPN).dataSet[.patientName]?.stringValues, ["", "", ""])
        let uidList = wire(tag: 0x0020000D, vr: .UI, value: "1.2.3\\1.2.4")
        XCTAssertThrowsError(try DicomDataSetParser.read(from: uidList))
        XCTAssertEqual(try DicomDataSetParser.read(from: uidList, purpose: .query).dataSet[.studyInstanceUID]?.stringValues,
            ["1.2.3", "1.2.4"])
        XCTAssertThrowsError(try DicomDataSetParser.read(from: wire(tag: 0x0020000D, vr: .UI, value: "1.2.3\\"), purpose: .query))
    }

    private func wire(tag: UInt32 = 0x77771001, vr: DicomVR, value: String) -> Data {
        var bytes = Data(value.utf8)
        if !bytes.count.isMultiple(of: 2) { bytes.append(vr == .UI ? 0 : 0x20) }
        var result = Data([UInt8(truncatingIfNeeded: tag >> 16), UInt8(truncatingIfNeeded: tag >> 24),
            UInt8(truncatingIfNeeded: tag), UInt8(truncatingIfNeeded: tag >> 8)])
        result.append(contentsOf: vr.code.utf8)
        if vr.uses32BitLength { result.append(contentsOf: [0, 0]) }
        let lengthBytes = vr.uses32BitLength ? 4 : 2
        for index in 0..<lengthBytes { result.append(UInt8(truncatingIfNeeded: bytes.count >> (8 * index))) }
        result.append(bytes)
        return result
    }
}
