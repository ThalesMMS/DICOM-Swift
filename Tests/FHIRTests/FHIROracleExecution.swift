import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum FHIROracleExecution {
    enum Failure: Error, Equatable { case timedOut, exitStatus(Int32) }

    /// Drain stdout while the oracle runs, including when its output exceeds pipe capacity.
    static func run(_ process: Process, request: Data, timeout: TimeInterval = 30) throws -> Data {
        let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("fhir-request-\(UUID()).json")
        try request.write(to: inputURL)
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        let data = Mutex(Data())
        process.terminationHandler = { _ in exited.signal() }
        let deadline = DispatchTime.now() + timeout
        try process.run()
        DispatchQueue.global().async {
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            data.withLock { $0 = bytes }
            drained.signal()
        }
        guard exited.wait(timeout: deadline) == .success else {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + 1)
            }
            throw Failure.timedOut
        }
        guard drained.wait(timeout: .now() + timeout) == .success else { throw Failure.timedOut }
        guard process.terminationStatus == 0 else { throw Failure.exitStatus(process.terminationStatus) }
        return data.withLock { $0 }
    }
}
