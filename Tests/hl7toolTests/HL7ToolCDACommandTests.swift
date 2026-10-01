import ArgumentParser
import Darwin
import Foundation
import HL7v3CDA
import XCTest
@testable import hl7tool

final class HL7ToolCDACommandTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl7tool-cda-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func capture(_ action: () throws -> Void) throws -> Data {
        let file = try temporaryDirectory().appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        defer {
            fflush(stdout); dup2(saved, STDOUT_FILENO); close(saved)
            try? handle.close()
        }
        try action()
        fflush(stdout)
        return try Data(contentsOf: file)
    }
    private func run(_ args: [String]) throws -> Data {
        var command = try HL7Tool.parseAsRoot(args)
        return try capture { try command.run() }
    }
    private func fixture(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HL7v3CDATests/Fixtures/" + relative).path
    }
    private func exitCode(_ args: [String]) -> Int32? {
        do { _ = try run(args); return 0 } catch let code as ExitCode { return code.rawValue } catch { return nil }
    }

    func test_parseValidateAndRender_verdictsAndOutputs() throws {
        let json = try run(["cda", "parse", fixture("ccd-minimal.xml"), "--json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["root"] as? String, "ClinicalDocument")
        XCTAssertEqual((object["templateIds"] as? [String])?.first, "2.16.840.1.113883.10.20.22.1.1")
        let xml = try run(["cda", "parse", fixture("ccd-minimal.xml")])
        XCTAssertNoThrow(try CDADocumentParser().parse(xml))
        XCTAssertEqual(exitCode(["cda", "validate", fixture("templates/ccd-valid.xml")]), 0)
        XCTAssertEqual(exitCode(["cda", "validate", fixture("templates/ccd-wrong-code.xml")]), 2)
        XCTAssertEqual(exitCode(["cda", "validate", fixture("malicious/billion-laughs.xml")]), nil, "parse failure is a thrown error, never exit 0")
        let text = String(decoding: try run(["cda", "render", fixture("discharge-summary-structured.xml"), "--text"]), as: UTF8.self)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let html = String(decoding: try run(["cda", "render", fixture("discharge-summary-structured.xml"), "--html"]), as: UTF8.self)
        XCTAssertTrue(html.contains("<section>"))
        XCTAssertNil(exitCode(["cda", "render", fixture("discharge-summary-structured.xml")]), "exactly one of --text/--html")
    }

    func test_diffMergeVersion_produceDocuments() throws {
        let dir = try temporaryDirectory()
        let appendix = dir.appendingPathComponent("appendix.xml")
        try run(["cda", "version", "appendix", fixture("ccd-minimal.xml")]).write(to: appendix)
        let versioned = try CDADocumentParser().parse(appendix)
        XCTAssertEqual(versioned.versionNumber?.value, "2")
        let diff = String(decoding: try run(["cda", "diff", fixture("ccd-minimal.xml"), appendix.path]), as: UTF8.self)
        XCTAssertTrue(diff.contains("versionNumber") || diff.contains("relatedDocument"), diff)
        let merged = try run(["cda", "merge", fixture("ccd-minimal.xml"), appendix.path, "--policy", "preferIncoming"])
        XCTAssertNoThrow(try CDADocumentParser().parse(merged))
        XCTAssertNil(exitCode(["cda", "merge", fixture("ccd-minimal.xml"), appendix.path, "--policy", "bogus"]))
        XCTAssertNil(exitCode(["cda", "version", "bogus", fixture("ccd-minimal.xml")]))
    }

    func test_transform_encapsulate_extract_roundTrip() throws {
        let dir = try temporaryDirectory()
        let adt = dir.appendingPathComponent("adt.hl7")
        try run(["build", "adt-a01"]).write(to: adt)
        let cda = dir.appendingPathComponent("adt.xml")
        try run(["cda", "transform", "v2-to-cda", adt.path, "--profile", "adt"]).write(to: cda)
        let document = try CDADocumentParser().parse(cda)
        XCTAssertNotNil(document.recordTargets.first?.patientRole)
        XCTAssertNil(exitCode(["cda", "transform", "v2-to-cda", adt.path, "--profile", "bogus"]))
        let back = try run(["cda", "transform", "cda-to-v2", cda.path, "--profile", "adt"])
        XCTAssertTrue(String(decoding: back, as: UTF8.self).hasPrefix("MSH|"))
        let patientJSON = dir.appendingPathComponent("patient.json")
        try Data(#"{"patientName":"Synthetic^Patient","patientID":"SYN-CLI"}"#.utf8).write(to: patientJSON)
        let dcm = dir.appendingPathComponent("out.dcm")
        XCTAssertNil(exitCode(["cda", "encapsulate", fixture("ccd-minimal.xml"), "--patient-json", patientJSON.path, "-o", dcm.path]),
                     "identity mismatch with the CDA recordTarget is refused by default")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dcm.path))
        _ = try run(["cda", "encapsulate", fixture("ccd-minimal.xml"), "--patient-json", patientJSON.path, "-o", dcm.path, "--allow-mismatch"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dcm.path))
        let extracted = dir.appendingPathComponent("extracted.xml")
        _ = try run(["cda", "extract", dcm.path, "-o", extracted.path])
        XCTAssertEqual(try CDADocumentSerializer().serialize(try CDADocumentParser().parse(extracted)),
                       try CDADocumentSerializer().serialize(try CDADocumentParser().parse(URL(fileURLWithPath: fixture("ccd-minimal.xml")))))
    }
}
