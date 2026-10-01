import Foundation
import XCTest

#if os(macOS)
/// Starts an unmodified independent peer; binding port zero avoids free-port races.
public final class PynetdicomPeer {
    public static var pythonPath: String? {
        let path = ProcessInfo.processInfo.environment["DICOM_SWIFT_PYNETDICOM_PYTHON"]
            ?? "/tmp/isis-2321-iod-oracle/bin/python"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    public let fixtureURL: URL
    public let port: UInt16
    private let process: Process
    private let directory: URL
    private let resultURL: URL

    public init(configuration: [String: Any] = [:]) throws {
        guard let python = Self.pythonPath else {
            throw XCTSkip("pynetdicom peer unavailable: set DICOM_SWIFT_PYNETDICOM_PYTHON to Python with pynetdicom 3.0.4.")
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-pynet-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ready = directory.appendingPathComponent("ready.json")
        resultURL = directory.appendingPathComponent("result.json")
        fixtureURL = directory.appendingPathComponent("rle.dcm")
        var config = configuration
        if configuration["generate_rle"] as? Bool == true { config["fixture_path"] = fixtureURL.path }
        config["ready_path"] = ready.path
        config["result_path"] = resultURL.path
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/interop/pynetdicom_peer.py")
        process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path, String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)]
        let log = directory.appendingPathComponent("peer.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        var selectedPort: UInt16?
        while process.isRunning && Date() < deadline {
            if let data = try? Data(contentsOf: ready),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json["port"] as? Int {
                selectedPort = UInt16(exactly: value)
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let selectedPort else {
            if let data = try? Data(contentsOf: ready),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let reason = json["unavailable"] as? String {
                if process.isRunning { process.terminate() }
                throw XCTSkip(reason)
            }
            if process.isRunning { process.terminate() }
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? "No readiness handshake"
            throw NSError(domain: "PynetdicomPeer", code: 1, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        port = selectedPort
    }

    public func stop() throws -> [String: Any] {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else {
            throw NSError(domain: "PynetdicomPeer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Peer teardown timed out"])
        }
        return try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any] ?? [:]
    }

    deinit {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
