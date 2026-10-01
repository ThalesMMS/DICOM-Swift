import Foundation
import XCTest
@testable import FHIR

/// Launches the independent Python FHIR server (`Scripts/interop/fhir_oracle.py`, role `server`)
/// on an ephemeral loopback port for the duration of a test.
final class FHIROracleServer: @unchecked Sendable {
    let process: Process
    let baseURL: URL
    private let directory: URL

    static func interpreter() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["FHIR_ORACLE_PYTHON"] ?? environment["HL7V2_ORACLE_PYTHON"], !path.isEmpty { return path }
        if environment["FHIR_REQUIRE_ORACLE"] == "1" || environment["HL7V2_REQUIRE_ORACLE"] == "1" {
            XCTFail("Required FHIR oracle interpreter is absent; set FHIR_ORACLE_PYTHON")
        }
        throw XCTSkip("FHIR_ORACLE_PYTHON (or HL7V2_ORACLE_PYTHON) is not set")
    }

    static func script() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/interop/fhir_oracle.py")
    }

    static func start(behaviors: [String: Any] = [:], lifetime: Int = 60) async throws -> FHIROracleServer {
        let interpreter = try interpreter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fhir-oracle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.json")
        let request: [String: Any] = ["role": "server", "ready_path": ready.path, "lifetime": lifetime, "behaviors": behaviors]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [script().path, String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: ready), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let base = object["base"] as? String, let url = URL(string: base) {
                return FHIROracleServer(process: process, baseURL: url, directory: directory)
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

    func client(format: FHIRWireFormat = .json, additionalHeaders: @escaping @Sendable () async throws -> [String: String] = { [:] }) -> FHIRClient {
        var configuration = FHIRClientConfiguration(baseURL: baseURL, policy: .init(timeout: 5, allowInsecureForHosts: ["127.0.0.1"]))
        configuration.format = format
        return FHIRClient(configuration: configuration, additionalHeaders: additionalHeaders)
    }

    static func examine(_ items: [(id: String, data: Data, format: String)]) throws -> [String: [String: Any]] {
        let interpreter = try interpreter()
        let documents = items.map { ["id": $0.id, "base64": $0.data.base64EncodedString(), "format": $0.format] }
        let request = try JSONSerialization.data(withJSONObject: ["documents": documents])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [script().path]
        let data = try FHIROracleExecution.run(process, request: request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        guard object["ready"] as? Bool == true else {
            if ProcessInfo.processInfo.environment["FHIR_REQUIRE_ORACLE"] == "1" || ProcessInfo.processInfo.environment["HL7V2_REQUIRE_ORACLE"] == "1" {
                XCTFail("FHIR oracle unavailable: \(object["unavailable"] ?? [])")
            }
            throw XCTSkip("FHIR oracle unavailable")
        }
        var results: [String: [String: Any]] = [:]
        for document in object["documents"] as? [[String: Any]] ?? [] { results[document["id"] as? String ?? ""] = document }
        return results
    }
}
