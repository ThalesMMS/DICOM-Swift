import Foundation
import XCTest
import HL7v2
@testable import HL7MLLP

@MainActor
final class MLLPOracleInteropTests: XCTestCase {
    private struct Peer {
        let process: Process
        let directory: URL
        var resultURL: URL { directory.appendingPathComponent("result.json") }
    }
    private func start(_ options: [String: Any]) async throws -> (Peer, UInt16) {
        guard let python = ProcessInfo.processInfo.environment["HL7V2_ORACLE_PYTHON"],
              FileManager.default.isExecutableFile(atPath: python) else {
            if ProcessInfo.processInfo.environment["HL7V2_REQUIRE_ORACLE"] == "1" {
                XCTFail("Required MLLP oracle unavailable")
                throw MLLPError.invalidConfiguration
            }
            throw XCTSkip("Set HL7V2_ORACLE_PYTHON to Python with python-hl7 and hl7apy")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.json")
        let input = directory.appendingPathComponent("input.json")
        var config = options
        config["ready_path"] = ready.path
        config["result_path"] = directory.appendingPathComponent("result.json").path
        config["lifetime"] = 10
        try JSONSerialization.data(withJSONObject: config).write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.arguments = [package.appendingPathComponent("Scripts/interop/mllp_oracle.py").path]
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        process.standardInput = handle
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: ready.path) {
                let info = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! [String: Any]
                return (Peer(process: process, directory: directory), (info["port"] as? NSNumber)?.uint16Value ?? 0)
            }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Oracle failed readiness/dependency gate")
        throw MLLPError.connectionFailed
    }
    private func finish(_ peer: Peer) async throws -> [String: Any] {
        for _ in 0..<1400 {
            if !peer.process.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !peer.process.isRunning else { peer.process.terminate(); throw MLLPError.connectionFailed }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: peer.resultURL)) as! [String: Any]
        XCTAssertEqual(peer.process.terminationStatus, 0, "Oracle failure: \(object["error"] ?? "unknown")")
        XCTAssertEqual(object["ok"] as? Bool, true)
        return object
    }
    func test_pythonServer_AA_AE_delay_duplicateAndReconnect() async throws {
        for options: [String: Any] in [[:], ["ack_code": "AE"], ["ack_delay": 0.15],
                                       ["duplicate_ack": true], ["drop_after": 1, "count": 2]] {
            var config = options; config["role"] = "server"
            let (peer, port) = try await start(config)
            let client = MLLPClient(host: "127.0.0.1", port: port)
            let count = options["count"] as? Int ?? 1
            var lengths: [Int] = []
            for _ in 0..<count {
                let message = mllpMessage()
                lengths.append(try HL7Serializer().serialize(message).count)
                let result = try await client.send(message, timeout: 2)
                XCTAssertEqual(result.description, options["ack_code"] as? String == "AE" ? "negativeAck(AE)" : "acknowledged(AA)")
                try await Task.sleep(for: .milliseconds(200))
            }
            if options["duplicate_ack"] as? Bool == true {
                let diagnostics = await client.diagnostics
                XCTAssertEqual(diagnostics.lateOrDuplicateACKs, 1)
            }
            let result = try await finish(peer)
            let received = result["received"] as! [[String: Any]]
            XCTAssertEqual(received.count, count)
            XCTAssertEqual(received.compactMap { $0["byte_length"] as? Int }, lengths)
            await client.disconnect()
        }
    }
    func test_hl7apyServer_basicExchange() async throws {
        let (peer, port) = try await start(["role": "server-hl7apy"])
        let client = MLLPClient(host: "127.0.0.1", port: port)
        let result = try await client.send(mllpMessage(), timeout: 3)
        XCTAssertEqual(result.description, "acknowledged(AA)")
        let report = try await finish(peer)
        XCTAssertEqual((report["received"] as? [Any])?.count, 1)
        await client.disconnect()
    }
    func test_pythonClient_fragmentedAndConcatenated_listenerParsesAll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (0..<3).map { index -> String in
            let path = directory.appendingPathComponent("\(index).hl7")
            try HL7Serializer().serialize(mllpMessage()).write(to: path)
            return path.path
        }
        for chunk in [7, 0] {
            let processor = MLLPTestProcessor()
            let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: processor)
            let port = try await listener.start()
            let (peer, _) = try await start(["role": "client", "port": port, "files": files, "chunk_bytes": chunk])
            let report = try await finish(peer)
            XCTAssertEqual(report["ack_codes"] as? [String], ["AA", "AA", "AA"])
            let calls = await processor.calls
            XCTAssertEqual(calls, 3)
            await listener.stop()
        }
    }
    func test_pythonClient_giantRefused_bufferBoundAndListenerSurvives() async throws {
        var limits = MLLPLimits(); limits.maxMessageBytes = 512; limits.maxBufferedBytes = 1024
        let processor = MLLPTestProcessor()
        let listener = MLLPListener(configuration: .init(limits: limits, exposure: mllpLocalExposure), processor: processor)
        let port = try await listener.start()
        let (peer, _) = try await start(["role": "client", "port": port, "giant_bytes": 8192, "chunk_bytes": 257])
        let report = try await finish(peer)
        XCTAssertEqual(report["closed"] as? Bool, true)
        await mllpEventually { await listener.connections == 0 }
        let peak = await listener.peakBufferedBytes
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThanOrEqual(peak, limits.maxBufferedBytes)
        let before = await processor.calls
        XCTAssertEqual(before, 0)
        let client = MLLPClient(host: "127.0.0.1", port: port)
        let result = try await client.send(mllpMessage(), timeout: 2)
        XCTAssertEqual(result.description, "acknowledged(AA)")
        await client.disconnect(); await listener.stop()
    }
}
