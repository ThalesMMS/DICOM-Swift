import Foundation
import XCTest
@testable import HL7v3CDA

/// Cross-checks the Swift CDA implementation against an independent libxml2/lxml oracle
/// (`Scripts/interop/cda_oracle.py`): XSD verdicts, structural inventory, exclusive C14N
/// round-trip hashes and refusal of malicious input. Oracle output carries only codes, OIDs,
/// counts and hashes; no oracle files are committed.
final class CDAOracleInteropTests: CDATestCase {
    struct OracleDocument: Decodable {
        var id: String
        var refused: String?
        var root: String?
        var templateIDs: [String]?
        var sectionCodes: [String]?
        var entryCount: Int?
        var narrativeIDCount: Int?
        var referenceCount: Int?
        var danglingReferenceCount: Int?
        var canonicalSHA256: String?
        var xsdValid: Bool?
    }
    struct OracleOutput: Decodable {
        var ready: Bool
        var dependencies: [String: String]
        var unavailable: [String]
        var documents: [OracleDocument]
    }

    static let templateNames: [String] = {
        guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json", subdirectory: "Fixtures/templates"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let templates = json["templates"] as? [[String: Any]] else { return [] }
        return templates.flatMap { [$0["valid"] as? String, $0["invalid"] as? String].compactMap { $0 } }
            .map { $0.replacingOccurrences(of: ".xml", with: "") }
    }()

    private func python() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CDA_ORACLE_PYTHON"] ?? environment["HL7V2_ORACLE_PYTHON"], !path.isEmpty { return path }
        if environment["CDA_REQUIRE_ORACLE"] == "1" || environment["HL7V2_REQUIRE_ORACLE"] == "1" {
            XCTFail("Required CDA oracle interpreter is absent; set CDA_ORACLE_PYTHON")
        }
        throw XCTSkip("CDA_ORACLE_PYTHON (or HL7V2_ORACLE_PYTHON) is not set")
    }

    private func script() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/interop/cda_oracle.py")
    }

    /// Runs the oracle on the given (id, bytes) pairs; content passes through temporary files that are removed afterwards.
    private func oracle(_ items: [(String, Data)], checks: [String] = ["xsd", "c14n"]) throws -> OracleOutput {
        let interpreter = try python()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cda-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var documents: [[String: String]] = []
        for (id, data) in items {
            let url = directory.appendingPathComponent(id + ".xml")
            try data.write(to: url)
            documents.append(["id": id, "path": url.path])
        }
        let request = try JSONSerialization.data(withJSONObject: ["documents": documents, "checks": checks])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [script().path, String(decoding: request, as: UTF8.self)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "oracle exit status")
        let decoded = try JSONDecoder().decode(OracleOutput.self, from: data)
        if !decoded.ready {
            let required = ProcessInfo.processInfo.environment["CDA_REQUIRE_ORACLE"] == "1" ||
                ProcessInfo.processInfo.environment["HL7V2_REQUIRE_ORACLE"] == "1"
            if required { XCTFail("CDA oracle unavailable: \(decoded.unavailable)") }
            throw XCTSkip("CDA oracle unavailable: \(decoded.unavailable)")
        }
        XCTAssertEqual(decoded.dependencies["lxml"], "6.1.3")
        return decoded
    }

    private func inventory(_ root: HL7v3CDA.XMLNode) -> (templates: [String], sections: [String], entries: Int, ids: Int, references: Int, dangling: Int) {
        let all = root.descendants()
        let templates = Set(all.filter { $0.name.localName == "templateId" }.compactMap { $0[attribute: "root"] }).sorted()
        let sections = Set(all.filter { $0.name.localName == "section" }.compactMap { $0.first("code")?[attribute: "code"] }.filter { !$0.isEmpty }).sorted()
        let entries = all.filter { $0.name.localName == "entry" }.count
        let ids = Set(all.compactMap { $0[attribute: "ID"] })
        let references = all.filter { $0.name.localName == "reference" }.compactMap { $0[attribute: "value"] }
        let dangling = references.filter { $0.hasPrefix("#") && !ids.contains(String($0.dropFirst())) }.count
        return (templates, sections, entries, ids.count, references.count, dangling)
    }

    private func corpus() throws -> [(String, Data)] {
        var items: [(String, Data)] = []
        for name in CDAFixtures.all { items.append((name, try CDAFixtures.data(name))) }
        for name in Self.templateNames + ["forbidden-null-flavor", "cardinality-violation", "unknown-template-id"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/templates"))
            items.append(("template-" + name, try Data(contentsOf: url)))
        }
        return items
    }

    func test_corpus_structuralInventoryAgreesWithLxml() throws {
        let items = try corpus()
        XCTAssertGreaterThan(items.count, 40)
        let output = try oracle(items, checks: ["xsd"])
        XCTAssertEqual(output.documents.count, items.count)
        for (item, verdict) in zip(items, output.documents) {
            XCTAssertNil(verdict.refused, item.0)
            let root = try SafeXMLParser().parse(item.1)
            let ours = inventory(root)
            XCTAssertEqual(verdict.root, "ClinicalDocument", item.0)
            XCTAssertEqual(verdict.templateIDs, ours.templates, item.0)
            XCTAssertEqual(verdict.sectionCodes, ours.sections, item.0)
            XCTAssertEqual(verdict.entryCount, ours.entries, item.0)
            XCTAssertEqual(verdict.narrativeIDCount, ours.ids, item.0)
            XCTAssertEqual(verdict.referenceCount, ours.references, item.0)
            XCTAssertEqual(verdict.danglingReferenceCount, ours.dangling, item.0)
            let document = try CDADocumentParser().parse(item.1)
            let danglingLinks = document.validateLinks().filter { $0.kind == .dangling }.count
            XCTAssertEqual(danglingLinks, ours.dangling, item.0)
        }
    }

    func test_corpus_xsdVerdictsMatchExpectationsAndXmllint() throws {
        let items = try corpus()
        let output = try oracle(items, checks: ["xsd"])
        var validCount = 0
        for (item, verdict) in zip(items, output.documents) {
            let xmllintValid = try CDAFixtures.xsdIsValid(item.1)
            XCTAssertEqual(verdict.xsdValid, xmllintValid, "lxml and xmllint disagree on " + item.0)
            if CDAFixtures.valid.contains(item.0) || item.0.hasSuffix("-valid") {
                XCTAssertTrue(xmllintValid, item.0)
                validCount += 1
            }
            if item.0 == "unknown-content" { XCTAssertFalse(xmllintValid, item.0) }
        }
        XCTAssertGreaterThan(validCount, 30)
    }

    func test_roundTrip_exclusiveCanonicalHashIsPreserved() throws {
        let items = try corpus()
        var pairs: [(String, Data)] = []
        for (name, data) in items {
            let document = try CDADocumentParser().parse(data)
            pairs.append((name + "-original", data))
            pairs.append((name + "-roundtrip", try CDADocumentSerializer().serialize(document)))
        }
        let output = try oracle(pairs, checks: ["c14n"])
        var hashes: [String: String] = [:]
        for verdict in output.documents { if let hash = verdict.canonicalSHA256 { hashes[verdict.id] = hash } }
        for (name, _) in items {
            XCTAssertNotNil(hashes[name + "-original"], name)
            XCTAssertEqual(hashes[name + "-original"], hashes[name + "-roundtrip"], name)
        }
    }

    func test_maliciousInputs_refusedByBothImplementations() throws {
        var items: [(String, Data)] = []
        for name in ["billion-laughs", "external-entity"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures/malicious"))
            items.append((name, try Data(contentsOf: url)))
        }
        let output = try oracle(items, checks: ["xsd"])
        XCTAssertEqual(output.documents.count, items.count)
        for (item, verdict) in zip(items, output.documents) {
            XCTAssertEqual(verdict.refused, "dtd", item.0)
            XCTAssertThrowsError(try SafeXMLParser().parse(item.1), item.0)
        }
    }

    func test_builderOutput_isSchemaValidPerLxml() throws {
        let builder = CDADocumentBuilder()
        builder.section(template: CDATemplateLibrary.problemsSection, code: "11450-4", title: "Problems") { section in
            section.narrative("Synthetic problem")
            section.problemObservation(code: try! CD(code: "75323-6", codeSystem: "2.16.840.1.113883.6.1"),
                                       value: .cd(try! CD(code: "386661006", codeSystem: "2.16.840.1.113883.6.96")),
                                       narrative: "Synthetic problem")
        }
        let data = try CDADocumentSerializer().serialize(try builder.build())
        let output = try oracle([("built", data)], checks: ["xsd"])
        XCTAssertEqual(output.documents.first?.xsdValid, true)
        XCTAssertEqual(output.documents.first?.danglingReferenceCount, 0)
    }
}
