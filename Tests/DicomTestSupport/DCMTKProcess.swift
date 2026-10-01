import Foundation

#if os(macOS)
/// A DCMTK tool running in the background, its output kept in a log file.
public final class DCMTKProcess {
    private let process = Process()
    private let log: URL

    init(executable: URL, arguments: [String]) throws {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("isis-dcmtk-\(UUID()).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
    }

    public var isRunning: Bool { process.isRunning }
    public var terminationStatus: Int32 { process.terminationStatus }
    public var output: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

    /// Waits until the log says the tool is ready, or it exits.
    public func waitForOutput(containing text: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if output.contains(text) { return true }
            if !process.isRunning { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    public func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: log)
    }
}
#endif
