import ArgumentParser
import Foundation
import HL7v2
import HL7MLLP
import XCTest
@testable import hl7tool

@MainActor
final class HL7ToolMLLPCommandTests: XCTestCase {
    private func fixture(_ directory: URL, invalid: Bool = false) throws -> String {
        var builder = HL7MessageBuilder(version: .v2_5_1)
        var pid = HL7Segment(name: "PID"); pid[3] = HL7Field(.text("SYNTHETIC")); pid[5] = HL7Field(.text("Example"))
        var pv1 = HL7Segment(name: "PV1"); pv1[2] = HL7Field(.text("I"))
        builder.msh(messageType: "ADT^A01", controlID: "CLI-SYNTHETIC")
        builder.adt(event: .A01, pid: pid, pv1: pv1)
        var message = builder.message
        if invalid { message["PID"]?[3] = HL7Field(.empty) }
        let file = directory.appendingPathComponent("message.hl7")
        try HL7Serializer().serialize(message).write(to: file)
        return file.path
    }
    private func exchange(invalid: Bool, duplicate: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try fixture(directory, invalid: invalid)
        let args = ["mllp", "listen", "--port", "0", "--reject-invalid", "--ledger", directory.path]
        let command = try XCTUnwrap(HL7Tool.parseAsRoot(args) as? MLLPListenCommand)
        let output = MLLPCLIOutput()
        let listener = try command.makeListener(output: output)
        let port = try await listener.start()
        var send = try XCTUnwrap(HL7Tool.parseAsRoot(["mllp", "send", "--host", "127.0.0.1", "--port", String(port),
            "--ack-timeout", "2", file] + (duplicate ? [file] : [])) as? MLLPSendCommand)
        do {
            try await send.run()
            XCTAssertFalse(invalid)
        } catch {
            XCTAssertTrue(invalid)
            XCTAssertEqual(HL7Tool.exitCode(for: error), ExitCode(2))
        }
        for _ in 0..<100 {
            if await output.received >= (duplicate ? 2 : 1) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let received = await output.received
        XCTAssertEqual(received, duplicate ? 2 : 1)
        await listener.stop()
        if duplicate {
            let rows = try String(contentsOf: directory.appendingPathComponent("inbound.jsonl"), encoding: .utf8)
            // begin, atomic outcome+ACK, sent, replay sent; no second processing reservation.
            XCTAssertEqual(rows.split(separator: "\n").count, 4)
        }
    }
    func test_sendListen_loopbackRoundTrip() async throws { try await exchange(invalid: false, duplicate: false) }
    func test_invalidMessage_sendExitsTwo() async throws { try await exchange(invalid: true, duplicate: false) }
    func test_ledgerReplay_cliProcessesOnce() async throws { try await exchange(invalid: false, duplicate: true) }
}
