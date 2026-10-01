import ArgumentParser
import Darwin
import Foundation
import HL7v2
import XCTest
@testable import hl7tool

final class HL7ToolCommandTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl7tool-\(UUID())")
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
    private func admission(_ dir: URL) throws -> URL {
        let file = dir.appendingPathComponent("adt.hl7")
        try run(["build", "adt-a01"]).write(to: file)
        return file
    }
    func test_parseJSONAndSerialize_roundTripAndExitCodes() throws {
        let dir = try temporaryDirectory()
        let input = try admission(dir)
        let json = dir.appendingPathComponent("message.json")
        try run(["parse", input.path, "--json"]).write(to: json)
        XCTAssertEqual(try run(["serialize", json.path]), try Data(contentsOf: input))
        let description = String(decoding: try run(["parse", input.path]), as: UTF8.self)
        XCTAssertTrue(description.contains("PID[1]"))
        XCTAssertFalse(description.contains("SYNTHETIC"))
        let malformed = dir.appendingPathComponent("bad.hl7")
        try Data("bad".utf8).write(to: malformed)
        XCTAssertThrowsError(try run(["parse", malformed.path])) {
            XCTAssertNotEqual(HL7Tool.exitCode(for: $0), .success)
        }
        XCTAssertThrowsError(try run(["validate", malformed.path, "--version", "2.5.1"])) {
            XCTAssertEqual(HL7Tool.exitCode(for: $0), ExitCode(2))
        }
    }
    func test_allBuildKinds_validateSuccessfully() throws {
        let dir = try temporaryDirectory()
        let original = try admission(dir)
        for kind in ["ack", "adt-a01", "orm-o01", "oru-r01", "qbp-q22"] {
            let args = ["build", kind] + (kind == "ack" ? ["--original", original.path] : [])
            let wire = try run(args)
            let file = dir.appendingPathComponent(kind + ".hl7")
            try wire.write(to: file)
            XCTAssertNoThrow(try run(["validate", file.path, "--version", "2.5.1"]), kind)
        }
    }
    func test_validateProfileAndInvalidMessage_exitTwo() throws {
        let dir = try temporaryDirectory()
        let file = try admission(dir)
        let profile = dir.appendingPathComponent("profile.json")
        try JSONEncoder().encode(HL7Profile(id: "test", baseVersion: .v2_5_1)).write(to: profile)
        XCTAssertNoThrow(try run(["validate", file.path, "--profile", profile.path]))
        var message = try HL7Parser().parse(Data(contentsOf: file))
        message["PID"]?[3] = HL7Field(.empty)
        try HL7Serializer().serialize(message).write(to: file)
        XCTAssertThrowsError(try run(["validate", file.path, "--version", "2.5.1"])) {
            XCTAssertEqual(HL7Tool.exitCode(for: $0), ExitCode(2))
        }
        XCTAssertThrowsError(try run(["validate", file.path]))
        XCTAssertThrowsError(try run(["validate", file.path, "--version", "2.5.1", "--profile", profile.path]))
    }
    func test_diffAndInspect_doNotExposeValuesByDefault() throws {
        let dir = try temporaryDirectory()
        let a = try admission(dir)
        let b = dir.appendingPathComponent("b.hl7")
        try run(["build", "adt-a01", "--patient-id", "SECRET"]).write(to: b)
        let diff = String(decoding: try run(["diff", a.path, b.path]), as: UTF8.self)
        XCTAssertTrue(diff.contains("PID[1]-3[1].1.1 changed"))
        XCTAssertFalse(diff.contains("SECRET"))
        XCTAssertFalse(String(decoding: try run(["inspect", b.path]), as: UTF8.self).contains("SECRET"))
        XCTAssertTrue(String(decoding: try run(["inspect", b.path, "--values"]), as: UTF8.self).contains("SECRET"))
    }
    func test_batchSplitJoin_preservesCustomNestedEnvelopeBytes() throws {
        let dir = try temporaryDirectory()
        let member = try admission(dir)
        let batch = try run(["batch", "join", member.path, member.path, "--file-envelope"])
        XCTAssertEqual(try HL7BatchDocument.parse(batch).messages.count, 2)
        let file = dir.appendingPathComponent("batch.hl7")
        let custom = Data("FHS|^~\\&|CUSTOM\rBHS|^~\\&|CUSTOM\r".utf8)
            + (try Data(contentsOf: member)) + Data("BTS|1\rBHS|^~\\&\rBTS|0\rFTS|2\r".utf8)
        try custom.write(to: file)
        let output = dir.appendingPathComponent("split")
        _ = try run(["batch", "split", file.path, "--output", output.path])
        XCTAssertEqual(try run(["batch", "join", output.path]), custom)
    }
    func test_parseLenientAndCharsetOverride() throws {
        let dir = try temporaryDirectory()
        let original = try admission(dir)
        let bytes = try Data(contentsOf: original)
        let lf = dir.appendingPathComponent("lf.hl7")
        try Data(bytes.map { $0 == 13 ? 10 : $0 }).write(to: lf)
        XCTAssertNoThrow(try run(["parse", lf.path, "--lenient", "--charset", "UTF-8"]))
        XCTAssertThrowsError(try run(["parse", lf.path]))
        XCTAssertThrowsError(try run(["parse", original.path, "--charset", "invalid"]))
    }
}
