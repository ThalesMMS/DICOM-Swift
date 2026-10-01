import Foundation
import XCTest
@testable import HL7v3CDA

typealias Node = HL7v3CDA.XMLNode

enum CDAFixtures {
    static let valid = ["ccd-minimal", "discharge-summary", "discharge-summary-structured", "nullflavors",
                        "sdtc-extensions", "narrative-links", "entry-variants", "datatypes", "header-participants"]
    static let all = valid + ["unknown-content"]
    static func url(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
    }
    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func document(_ name: String = "ccd-minimal") throws -> ClinicalDocument { try CDADocumentParser().parse(url(name)) }
    static func sections(_ doc: ClinicalDocument) throws -> [Section] {
        guard case .structured(let body) = doc.body else { throw CDAError.invalidDocument }
        return body.sections
    }

    /// xmllint verdict without assertions; skips (or fails under CDA_REQUIRE_XSD=1) when the schema is absent.
    static func xsdIsValid(_ data: Data) throws -> Bool {
        let directory = ProcessInfo.processInfo.environment["CDA_XSD_DIR"] ??
            "/System/Library/Frameworks/HealthKit.framework/Versions/A/Resources/cda_validation"
        let schema = URL(fileURLWithPath: directory).appendingPathComponent("CDA_SDTC.xsd")
        guard FileManager.default.fileExists(atPath: schema.path) else {
            if ProcessInfo.processInfo.environment["CDA_REQUIRE_XSD"] == "1" { throw CDAError.invalidDocument }
            throw XCTSkip("Local CDA XSD oracle is absent; set CDA_XSD_DIR or require it with CDA_REQUIRE_XSD=1")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xml")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        process.arguments = ["--nonet", "--noout", "--schema", schema.path, temp.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// The schema is independently installed by macOS; never copied into this package.
    static func validateXSD(_ data: Data, expectValid: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        let directory = ProcessInfo.processInfo.environment["CDA_XSD_DIR"] ??
            "/System/Library/Frameworks/HealthKit.framework/Versions/A/Resources/cda_validation"
        let schema = URL(fileURLWithPath: directory).appendingPathComponent("CDA_SDTC.xsd")
        guard FileManager.default.fileExists(atPath: schema.path) else {
            if ProcessInfo.processInfo.environment["CDA_REQUIRE_XSD"] == "1" {
                XCTFail("Required local CDA XSD oracle is absent", file: file, line: line)
                return
            }
            throw XCTSkip("Local CDA XSD oracle is absent; set CDA_XSD_DIR or require it with CDA_REQUIRE_XSD=1")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xml")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xmllint")
        process.arguments = ["--nonet", "--noout", "--schema", schema.path, temp.path]
        // xmllint can include content in errors. Discard it; assert only the exit status.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, expectValid ? 0 : 3, "CDA XSD oracle exit status", file: file, line: line)
    }
}
