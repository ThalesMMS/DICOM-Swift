import Foundation
import XCTest

#if os(macOS)
/// The DCMTK tools built by `Tools/Scripts/build_dcmtk.sh` (issue #2794): an
/// independent DIMSE peer and a GSPS/GSDF oracle. Absent, the tests skip;
/// with `DICOM_REQUIRE_DCMTK=1` they fail instead.
public struct DCMTKToolchain {
    public let binDirectory: URL
    public let dataDirectory: URL

    public static func required(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DCMTKToolchain {
        let manager = FileManager.default
        if let bin = environment["DCMTK_BIN_DIR"], let data = environment["DCMTK_DATA_DIR"],
           manager.isExecutableFile(atPath: URL(fileURLWithPath: bin).appendingPathComponent("storescu").path),
           manager.fileExists(atPath: URL(fileURLWithPath: data).appendingPathComponent("storescu.cfg").path) {
            return DCMTKToolchain(binDirectory: URL(fileURLWithPath: bin), dataDirectory: URL(fileURLWithPath: data))
        }
        let message = "DCMTK unavailable: run Tools/Scripts/build_dcmtk.sh and export DCMTK_BIN_DIR and DCMTK_DATA_DIR."
        if environment["DICOM_REQUIRE_DCMTK"] == "1" {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: message])
        }
        throw XCTSkip(message)
    }

    public func tool(_ name: String) -> URL {
        binDirectory.appendingPathComponent(name)
    }

    public func data(_ name: String) -> URL {
        dataDirectory.appendingPathComponent(name)
    }

    /// Runs a tool to the end; its output is returned for the failure message.
    @discardableResult
    public func run(_ name: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let process = try start(name, arguments)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.stop()
            throw DCMTKToolError(tool: name, status: nil, output: process.output)
        }
        guard process.terminationStatus == 0 else {
            throw DCMTKToolError(tool: name, status: process.terminationStatus, output: process.output)
        }
        return process.output
    }

    /// Starts a tool that keeps running, such as `dcmqrscp` or `storescp`.
    public func start(_ name: String, _ arguments: [String]) throws -> DCMTKProcess {
        try DCMTKProcess(executable: tool(name), arguments: arguments)
    }

    /// Waits until a DCMTK server accepts connections on the loopback port.
    public static func waitUntilListening(port: UInt16, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(descriptor)
            if connected { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// A loopback port nothing listens on now; DCMTK servers take no port 0.
    public static func freePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return UInt16(bigEndian: address.sin_port)
    }
}

public struct DCMTKToolError: Error, CustomStringConvertible {
    public let tool: String
    /// Nil when the tool was stopped at its time limit.
    public let status: Int32?
    public let output: String

    public var description: String {
        "\(tool) \(status.map { "exited with \($0)" } ?? "timed out"):\n\(output)"
    }
}
#endif
