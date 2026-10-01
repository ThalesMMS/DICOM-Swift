import ArgumentParser
import Darwin
import DicomCore
import DicomTestSupport
import FHIR
import Foundation
import XCTest
@testable import hl7tool

final class HL7ToolFHIRCommandTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hl7tool-fhir-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func capture(stderr includeStderr: Bool = false, _ action: () async throws -> Void) async throws -> Data {
        let file = try temporaryDirectory().appendingPathComponent("stdout")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        fflush(stderr)
        let savedError = includeStderr ? dup(STDERR_FILENO) : -1
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        if includeStderr { dup2(handle.fileDescriptor, STDERR_FILENO) }
        defer {
            fflush(stdout); dup2(saved, STDOUT_FILENO); close(saved)
            if includeStderr { fflush(stderr); dup2(savedError, STDERR_FILENO); close(savedError) }
            try? handle.close()
        }
        try await action()
        fflush(stdout)
        fflush(stderr)
        return try Data(contentsOf: file)
    }
    private func run(_ args: [String]) async throws -> Data {
        var command = try HL7Tool.parseAsRoot(args)
        return try await capture {
            if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() }
        }
    }
    private func exitCode(_ args: [String]) async -> Int32? {
        await exitResult(args).code
    }
    private func exitResult(_ args: [String]) async -> (code: Int32?, diagnostics: String) {
        var code: Int32? = 0
        do {
            let output = try await capture(stderr: true) {
                do {
                    var command = try HL7Tool.parseAsRoot(args)
                    if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() }
                } catch let exit as ExitCode { code = exit.rawValue } catch { code = nil }
            }
            return (code, String(decoding: output, as: UTF8.self))
        } catch { return (nil, String(describing: error)) }
    }
    private func fixture(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FHIRTests/Fixtures/" + relative).path
    }

    func test_parseValidateAndPath() async throws {
        let xml = try await run(["fhir", "parse", fixture("official/patient-example.json"), "--xml"])
        XCTAssertTrue(String(decoding: xml, as: UTF8.self).hasPrefix("<Patient xmlns=\"http://hl7.org/fhir\""))
        let dir = try temporaryDirectory()
        let xmlFile = dir.appendingPathComponent("patient.xml")
        try xml.write(to: xmlFile)
        let json = try await run(["fhir", "parse", xmlFile.path, "--pretty"])
        XCTAssertEqual(try FHIRResource(jsonData: json).id, "example")
        let verdict = await exitCode(["fhir", "validate", fixture("official/observation-example.json")])
        XCTAssertEqual(verdict, 0)
        let broken = dir.appendingPathComponent("broken.json")
        try Data(#"{"resourceType":"Observation","id":"x","code":{"text":"t"}}"#.utf8).write(to: broken)
        let failing = await exitCode(["fhir", "validate", broken.path])
        XCTAssertEqual(failing, 2, "missing status is an error")
        let unknownElement = dir.appendingPathComponent("unknown.json")
        try Data(#"{"resourceType":"Patient","id":"x","bogus":"1"}"#.utf8).write(to: unknownElement)
        let strict = await exitCode(["fhir", "validate", unknownElement.path])
        XCTAssertEqual(strict, 2)
        let lenient = await exitCode(["fhir", "validate", unknownElement.path, "--lenient"])
        XCTAssertEqual(lenient, 0)
        let path = try await run(["fhir", "path", "name.where(use = 'official').family", fixture("official/patient-example.json")])
        XCTAssertEqual(String(decoding: path, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), #"["Chalmers"]"#)
        let unsupported = await exitCode(["fhir", "path", "managingOrganization.resolve()", fixture("official/patient-example.json")])
        XCTAssertNil(unsupported, "unsupported FHIRPath functions fail loudly")
    }

    func test_imagingStudyFromDICOMFiles_andClientAgainstLoopback() async throws {
        let dir = try temporaryDirectory()
        var files: [String] = []
        for index in 1...2 {
            let url = dir.appendingPathComponent("ct\(index).dcm")
            try DicomStructuralFixtures.ctSlice(index: index).write(to: url)
            files.append(url.path)
        }
        let output = try await run(["fhir", "imagingstudy"] + files + ["--patient", "Patient/m1", "--with-patient"])
        let bundle = try XCTUnwrap(FHIRResource(jsonData: output).as(FHIRBundle.self))
        XCTAssertEqual(bundle.entries.map { $0.resource?.resourceType }, ["Patient", "ImagingStudy"])
        let study = try XCTUnwrap(bundle.resources(of: FHIRImagingStudy.self).first)
        XCTAssertEqual(study.numberOfInstances, 2)
        XCTAssertEqual(study.subject?.reference, "Patient/m1")

        let refused = await exitResult(["fhir", "client", "get", "http://127.0.0.1:1/r4", "Patient/1"])
        XCTAssertEqual(refused.code, 2, "plain http without --intranet-lab is refused by policy")
        XCTAssertTrue(refused.diagnostics.contains("failure invalidRequest"), refused.diagnostics)
        let publicHost = await exitCode(["fhir", "client", "get", "http://example.test/r4", "Patient/1", "--intranet-lab", "example.test"])
        XCTAssertNil(publicHost, "--intranet-lab only accepts loopback or private hosts")
        let server = try await FHIROracleServerProxy.start()
        defer { server.stop() }
        let created = try await FHIRClient(baseURL: server.baseURL, policy: .init(timeout: 5, allowInsecureForHosts: ["127.0.0.1"]))
            .create(study.resource)
        let id = try XCTUnwrap(created.value??.id)
        let fetched = try await run(["fhir", "client", "get", server.baseURL.absoluteString, "ImagingStudy/" + id, "--intranet-lab", "127.0.0.1"])
        XCTAssertEqual(try FHIRResource(jsonData: fetched).as(FHIRImagingStudy.self)?.numberOfInstances, 2)
        let searched = try await run(["fhir", "client", "search", server.baseURL.absoluteString, "ImagingStudy", "--param", "_id=" + id, "--intranet-lab", "127.0.0.1"])
        XCTAssertEqual(try FHIRResource(jsonData: searched).as(FHIRBundle.self)?.entries.count, 1)
        let missing = await exitCode(["fhir", "client", "get", server.baseURL.absoluteString, "Patient/nope", "--intranet-lab", "127.0.0.1"])
        XCTAssertEqual(missing, 2)
    }

    func test_intranetLab_acceptsOnlyLoopbackAndPrivateIPv4Addresses() async {
        for host in ["127.0.0.2", "127.255.255.254", "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1"] {
            let result = await exitResult(["fhir", "client", "get", "http://example.test", "Patient/1", "--intranet-lab", host])
            XCTAssertEqual(result.code, 2, host)
            XCTAssertTrue(result.diagnostics.contains("invalidRequest"), "\(host): \(result.diagnostics)")
        }
        for host in ["localhost", "10.example.test", "192.168.example.test", "10.0.0.256", "172.15.255.255", "172.32.0.0", "8.8.8.8", "::1"] {
            let code = await exitCode(["fhir", "client", "get", "http://example.test", "Patient/1", "--intranet-lab", host])
            XCTAssertNil(code, host)
        }
    }
}

/// Minimal launcher for the Python FHIR oracle server (mirrors FHIRTests' harness).
final class FHIROracleServerProxy {
    let process: Process
    let baseURL: URL
    private let directory: URL

    static func start() async throws -> FHIROracleServerProxy {
        let environment = ProcessInfo.processInfo.environment
        guard let interpreter = environment["FHIR_ORACLE_PYTHON"] ?? environment["HL7V2_ORACLE_PYTHON"], !interpreter.isEmpty else {
            if environment["FHIR_REQUIRE_ORACLE"] == "1" || environment["HL7V2_REQUIRE_ORACLE"] == "1" { XCTFail("Required FHIR oracle interpreter is absent") }
            throw XCTSkip("FHIR_ORACLE_PYTHON (or HL7V2_ORACLE_PYTHON) is not set")
        }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/interop/fhir_oracle.py")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fhir-oracle-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [script.path, "{\"role\":\"server\",\"ready_path\":\"\(ready.path)\",\"lifetime\":60}"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: ready), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let base = object["base"] as? String, let url = URL(string: base) {
                return FHIROracleServerProxy(process: process, baseURL: url, directory: directory)
            }
            guard process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw XCTSkip("FHIR oracle server did not become ready")
    }

    private init(process: Process, baseURL: URL, directory: URL) {
        self.process = process
        self.baseURL = baseURL
        self.directory = directory
    }

    func stop() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}
