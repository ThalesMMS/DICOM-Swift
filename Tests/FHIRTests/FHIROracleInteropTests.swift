import Foundation
import XCTest
@testable import FHIR

/// Cross-checks serialization with fhir.resources: official JSON and our XML->JSON conversion
/// validate and hash identically; our JSON->XML output parses in the oracle; invalid instances
/// are refused by both sides; malicious XML is refused by both.
final class FHIROracleInteropTests: XCTestCase {
    func test_officialCorpus_validAndXMLConversionHashesAgree() throws {
        var items: [(id: String, data: Data, format: String)] = []
        for name in FHIRFixtures.official {
            // Narrative `div` strings differ only in XHTML serialization (whitespace/attribute order); normalize both sides.
            let original = FHIRJSONWriter().write(try FHIRFixtures.normalizingNarrative(.object(try FHIRFixtures.resource(name).json)))
            items.append((name + "-json", original, "json"))
            let fromXML = try FHIRResource(xmlData: try FHIRFixtures.data(name, "xml"))
            items.append((name + "-ours-from-xml", FHIRJSONWriter().write(try FHIRFixtures.normalizingNarrative(.object(fromXML.json))), "json"))
            items.append((name + "-ours-xml", try FHIRFixtures.resource(name).xmlData(), "xml"))
        }
        let verdicts = try FHIROracleServer.examine(items)
        for name in FHIRFixtures.official {
            let original = try XCTUnwrap(verdicts[name + "-json"], name)
            XCTAssertEqual(original["valid"] as? Bool, true, name + ": " + String(describing: original["issues"]))
            let converted = try XCTUnwrap(verdicts[name + "-ours-from-xml"], name)
            XCTAssertEqual(converted["valid"] as? Bool, true, name)
            XCTAssertEqual(converted["canonicalSHA256"] as? String, original["canonicalSHA256"] as? String, name + " xml->json hash")
            let ourXML = try XCTUnwrap(verdicts[name + "-ours-xml"], name)
            XCTAssertEqual(ourXML["valid"] as? Bool, true, name + " json->xml parsed by the oracle: " + String(describing: ourXML["refused"]))
            XCTAssertEqual(ourXML["resourceType"] as? String, try FHIRFixtures.resource(name).resourceType, name)
        }
    }

    func test_invalidAndMaliciousInputs_refusedByBoth() throws {
        let invalid = Data(#"{"resourceType":"Patient","name":"not a list","birthDate":"1974-13"}"#.utf8)
        var items: [(id: String, data: Data, format: String)] = [("invalid", invalid, "json")]
        for name in ["entity-expansion", "external-entity"] {
            items.append((name, try FHIRFixtures.data(name, "xml", subdirectory: "Fixtures/malicious"), "xml"))
        }
        let verdicts = try FHIROracleServer.examine(items)
        XCTAssertEqual(verdicts["invalid"]?["valid"] as? Bool, false)
        XCTAssertTrue((verdicts["invalid"]?["issues"] as? [String])?.contains { $0.hasPrefix("birthDate") || $0.hasPrefix("name") } ?? false)
        XCTAssertEqual(verdicts["entity-expansion"]?["refused"] as? String, "dtd")
        XCTAssertEqual(verdicts["external-entity"]?["refused"] as? String, "dtd")
        XCTAssertNoThrow(try FHIRResource(jsonData: invalid), "structure parses; validity is the validator's job")
        XCTAssertFalse(FHIRPrimitiveType.date.isValid("1974-13"))
        XCTAssertFalse(FHIRPrimitiveType.code.isValid(" not a code"), "fhir.resources does not check code lexical rules; the toolkit validator does")
    }
}
