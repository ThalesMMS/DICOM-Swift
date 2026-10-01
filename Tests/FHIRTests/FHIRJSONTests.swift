import Foundation
import XCTest
@testable import FHIR

final class FHIRJSONTests: XCTestCase {
    func test_negativeDateYears_preserveSignAndFourDigits() throws {
        for text in ["-0001", "-0012-03", "-0123-04-05", "-1234-06-07", "0001-01-01"] {
            let date = try XCTUnwrap(FHIRDate(text))
            XCTAssertEqual(date.description, text)
            XCTAssertEqual(FHIRDate(date.description), date)
        }
    }

    func test_numbers_keepLexicalFormAndTyping() throws {
        let json = try FHIRJSONParser().parse(Data(#"{"a":1.0,"b":1.50,"c":1E-3,"d":-0,"e":12345678901234567890,"f":0.1234567890123456789}"#.utf8))
        XCTAssertEqual(json["a"]?.number?.lexical, "1.0")
        XCTAssertEqual(json["b"]?.number?.lexical, "1.50")
        XCTAssertEqual(json["c"]?.number?.lexical, "1E-3")
        XCTAssertEqual(json["d"]?.number?.lexical, "-0")
        XCTAssertEqual(json["e"]?.number?.lexical, "12345678901234567890")
        XCTAssertEqual(json["f"]?.number?.decimalValue, Decimal(string: "0.1234567890123456789"))
        XCTAssertEqual(String(decoding: FHIRJSONWriter().write(json), as: UTF8.self),
                       #"{"a":1.0,"b":1.50,"c":1E-3,"d":-0,"e":12345678901234567890,"f":0.1234567890123456789}"#)
        for bad in ["01", "1.", ".5", "+1", "NaN", "Infinity", "0x10"] {
            XCTAssertThrowsError(try FHIRJSONParser().parse(Data("{\"n\":\(bad)}".utf8)), bad)
        }
    }

    func test_strings_escapesSurrogatesAndControlCharacters() throws {
        let json = try FHIRJSONParser().parse(Data(#"{"s":"a\"b\\c\/\né😀A"}"#.utf8))
        XCTAssertEqual(json["s"]?.string, "a\"b\\c/\né😀A")
        let written = String(decoding: FHIRJSONWriter().write(json), as: UTF8.self)
        XCTAssertEqual(written, #"{"s":"a\"b\\c/\né😀A"}"#)
        XCTAssertEqual(String(decoding: FHIRJSONWriter(asciiOnly: true).write(json), as: UTF8.self), #"{"s":"a\"b\\c/\n\u00E9\uD83D\uDE00A"}"#)
        XCTAssertThrowsError(try FHIRJSONParser().parse(Data("{\"s\":\"tab\there\"}".utf8)))
        XCTAssertThrowsError(try FHIRJSONParser().parse(Data(#"{"s":"\ud83d"}"#.utf8)), "lone high surrogate")
        XCTAssertThrowsError(try FHIRJSONParser().parse(Data(#"{"s":"\ude00"}"#.utf8)), "lone low surrogate")
        XCTAssertThrowsError(try FHIRJSONParser().parse(Data([0x7B, 0x22, 0x73, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D])), "invalid UTF-8")
    }

    func test_objects_rejectDuplicateKeysAndKeepOrder() throws {
        XCTAssertThrowsError(try FHIRJSONParser().parse(Data(#"{"a":1,"a":2}"#.utf8))) {
            XCTAssertEqual($0 as? FHIRJSONError, .duplicateKey("a"))
        }
        let object = try FHIRJSONParser().parseObject(Data(#"{"z":1,"a":[true,null,{}],"m":{"k":"v"}}"#.utf8))
        XCTAssertEqual(object.keys, ["z", "a", "m"])
        XCTAssertEqual(String(decoding: FHIRJSONWriter().write(object), as: UTF8.self), #"{"z":1,"a":[true,null,{}],"m":{"k":"v"}}"#)
        XCTAssertEqual(String(decoding: FHIRJSONWriter(pretty: true).write(.object(object)), as: UTF8.self),
                       "{\n  \"z\": 1,\n  \"a\": [\n    true,\n    null,\n    {}\n  ],\n  \"m\": {\n    \"k\": \"v\"\n  }\n}\n")
        var mutable = object
        mutable["a"] = nil
        mutable["b"] = .bool(false)
        XCTAssertEqual(mutable.keys, ["z", "m", "b"])
        mutable.moveToFront(["b", "missing"])
        XCTAssertEqual(mutable.keys, ["b", "z", "m"])
    }

    func test_syntaxErrors_reportOffsetsNotContent() {
        for (text, offset) in [("{", 1), ("[1,]", 3), ("{\"a\" 1}", 5), ("tru", 0), ("{\"a\":1} x", 8), ("\"unterminated", 13)] {
            XCTAssertThrowsError(try FHIRJSONParser().parse(Data(text.utf8)), text) { error in
                guard case FHIRJSONError.syntax(let reported) = error else { return XCTFail("wrong error \(error) for \(text)") }
                XCTAssertEqual(reported, offset, text)
            }
        }
    }

    func test_limits_boundDepthNodesStringsAndBytes() throws {
        var limits = FHIRLimits()
        limits.maxDepth = 8
        XCTAssertThrowsError(try FHIRJSONParser(limits: limits).parse(Data((String(repeating: "[", count: 9) + String(repeating: "]", count: 9)).utf8))) {
            XCTAssertEqual($0 as? FHIRJSONError, .depthLimit)
        }
        XCTAssertNoThrow(try FHIRJSONParser(limits: limits).parse(Data((String(repeating: "[", count: 8) + String(repeating: "]", count: 8)).utf8)))
        limits = FHIRLimits(); limits.maxNodes = 5
        XCTAssertThrowsError(try FHIRJSONParser(limits: limits).parse(Data("[1,2,3,4,5]".utf8))) { XCTAssertEqual($0 as? FHIRJSONError, .nodeLimit) }
        limits = FHIRLimits(); limits.maxStringBytes = 4
        XCTAssertThrowsError(try FHIRJSONParser(limits: limits).parse(Data("[\"abcde\"]".utf8))) { XCTAssertEqual($0 as? FHIRJSONError, .stringLimit) }
        limits = FHIRLimits(); limits.maxBytes = 3
        XCTAssertThrowsError(try FHIRJSONParser(limits: limits).parse(Data("[1,2]".utf8))) { XCTAssertEqual($0 as? FHIRJSONError, .byteLimit) }
        let deep = try FHIRFixtures.data("deep-nesting", subdirectory: "Fixtures/malicious")
        XCTAssertEqual(deep.filter { $0 == UInt8(ascii: "[") }.count, 129)
        XCTAssertThrowsError(try FHIRResource(jsonData: deep), "nested arrays beyond maxDepth") {
            XCTAssertEqual($0 as? FHIRJSONError, .depthLimit)
        }
        limits = FHIRLimits(); limits.maxBundleEntries = 1
        XCTAssertThrowsError(try FHIRResource(jsonData: try FHIRFixtures.data("bundle-transaction"), limits: limits)) {
            XCTAssertEqual($0 as? FHIRJSONError, .bundleEntryLimit)
        }
    }
}

final class FHIRPrimitiveTests: XCTestCase {
    func test_dates_partialPrecisionAndValidation() {
        XCTAssertEqual(FHIRDate("1974")?.precision, .year)
        XCTAssertEqual(FHIRDate("1974-12")?.precision, .month)
        XCTAssertEqual(FHIRDate("1974-12-25")?.precision, .day)
        XCTAssertEqual(FHIRDate("1974-12-25")?.description, "1974-12-25")
        XCTAssertNil(FHIRDate("1974-13"))
        XCTAssertNil(FHIRDate("1974-02-30"))
        XCTAssertNotNil(FHIRDate("2024-02-29"))
        XCTAssertNil(FHIRDate("2023-02-29"))
        XCTAssertNil(FHIRDate("1974-1-5"))
        XCTAssertEqual(FHIRDate("1974-12")!.compare(FHIRDate("1974-12-25")!), .indeterminate)
        XCTAssertEqual(FHIRDate("1974-12-24")!.compare(FHIRDate("1974-12-25")!), .less)
    }

    func test_dateTimes_requireZoneWithTimeAndKeepFractions() {
        XCTAssertEqual(FHIRDateTime("2015-02-07T13:28:17.239+02:00")?.time?.fraction, "239")
        XCTAssertEqual(FHIRDateTime("2015-02-07T13:28:17.239+02:00")?.description, "2015-02-07T13:28:17.239+02:00")
        XCTAssertEqual(FHIRDateTime("2015-02-07T13:28:17Z")?.timeZone?.offsetMinutes, 0)
        XCTAssertEqual(FHIRDateTime("2015-02-07T13:28:17-03:30")?.timeZone?.offsetMinutes, -210)
        XCTAssertNil(FHIRDateTime("2015-02-07T13:28:17"), "time without zone")
        XCTAssertNil(FHIRDateTime("2015-02-07T13:28"), "minutes without seconds")
        XCTAssertNil(FHIRDateTime("2015-02T13:28:17Z"), "time needs a full date")
        XCTAssertEqual(FHIRDateTime("2015-02")?.precision, .month)
        let a = FHIRDateTime("2015-02-07T13:28:17+02:00")!, b = FHIRDateTime("2015-02-07T11:28:17Z")!
        XCTAssertEqual(a.compare(b), .equal)
        XCTAssertEqual(a.compare(FHIRDateTime("2015-02-07T11:28:17.5Z")!), .indeterminate, "precision differs")
        XCTAssertEqual(FHIRDateTime("2015-02-07")!.compare(FHIRDateTime("2015-02-08")!), .less)
        XCTAssertTrue(FHIRPrimitiveType.instant.isValid("2015-02-07T13:28:17.239+02:00"))
        XCTAssertFalse(FHIRPrimitiveType.instant.isValid("2015-02-07"))
        XCTAssertEqual(FHIRTime("13:28:17.5")?.description, "13:28:17.5")
        XCTAssertNil(FHIRTime("24:00:00"))
    }

    func test_primitiveRules_idCodeIntegersAndBase64() {
        XCTAssertTrue(FHIRPrimitiveType.id.isValid("a-B.9"))
        XCTAssertFalse(FHIRPrimitiveType.id.isValid(String(repeating: "a", count: 65)))
        XCTAssertFalse(FHIRPrimitiveType.id.isValid("with space"))
        XCTAssertTrue(FHIRPrimitiveType.code.isValid("a b"))
        XCTAssertFalse(FHIRPrimitiveType.code.isValid(" a"))
        XCTAssertFalse(FHIRPrimitiveType.code.isValid("a  b"))
        XCTAssertTrue(FHIRPrimitiveType.integer.isValid("-2147483648"))
        XCTAssertFalse(FHIRPrimitiveType.integer.isValid("2147483648"))
        XCTAssertFalse(FHIRPrimitiveType.positiveInt.isValid("0"))
        XCTAssertTrue(FHIRPrimitiveType.unsignedInt.isValid("0"))
        XCTAssertFalse(FHIRPrimitiveType.unsignedInt.isValid("01"))
        XCTAssertTrue(FHIRPrimitiveType.decimal.isValid("1.50"))
        XCTAssertFalse(FHIRPrimitiveType.decimal.isValid("1."))
        XCTAssertTrue(FHIRPrimitiveType.base64Binary.isValid("QUJD"))
        XCTAssertFalse(FHIRPrimitiveType.base64Binary.isValid("QUJ"))
        XCTAssertTrue(FHIRPrimitiveType.oid.isValid("urn:oid:1.2.840.10008"))
        XCTAssertFalse(FHIRPrimitiveType.oid.isValid("1.2.840"))
        XCTAssertEqual(FHIRPrimitiveType.boolean.jsonKind, .bool)
        XCTAssertEqual(FHIRPrimitiveType.decimal.jsonKind, .number)
        XCTAssertEqual(FHIRPrimitiveType.dateTime.jsonKind, .string)
    }
}
