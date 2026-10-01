import Foundation
import XCTest

final class FHIROracleExecutionTests: XCTestCase {
    func test_processExitNearDeadline_allowsBoundedOutputDrain() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try FHIROracleServer.interpreter())
        process.arguments = ["-c", """
        import os, time
        if os.fork() == 0:
            time.sleep(0.9)
            os.write(1, b'finished')
            os._exit(0)
        time.sleep(0.4)
        """]
        XCTAssertEqual(try FHIROracleExecution.run(process, request: Data(), timeout: 0.7), Data("finished".utf8))
    }

    func test_largeOutput_isDrainedWhileProcessRuns() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try FHIROracleServer.interpreter())
        process.arguments = ["-c", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read() * 4)"]
        let request = Data(repeating: 65, count: 128 * 1024)
        let data = try FHIROracleExecution.run(process, request: request)
        XCTAssertEqual(data, Data(repeating: 65, count: 512 * 1024))
    }

    func test_hungProcess_isTerminatedWithinDeadline() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try FHIROracleServer.interpreter())
        process.arguments = ["-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('partial', flush=True); time.sleep(60)"]
        let start = ContinuousClock.now
        XCTAssertThrowsError(try FHIROracleExecution.run(process, request: Data(), timeout: 0.5)) {
            XCTAssertEqual($0 as? FHIROracleExecution.Failure, .timedOut)
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(4))
        XCTAssertFalse(process.isRunning)
    }
}
