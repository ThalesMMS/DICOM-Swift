import Foundation
import XCTest
import ArgumentParser
import DicomCore
@testable import dicomtool

final class AuditCommandTests: XCTestCase, @unchecked Sendable {
    func test_auditRegisteredAndEmitKindsProduceStructuralXML() throws {
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == AuditCommand.self })
        for kind in ["start", "stop", "login", "logout", "failure", "queryPerformed", "dicomInstancesAccessed",
                     "beginTransferringInstances", "instancesTransferred", "dataExport", "dataImport", "securityAlert",
                     "patientRecord", "configurationChanged"] {
            let command = try AuditCommand.Emit.parse(["--event", kind, "--study-uid", "1.2.3"])
            try DicomAuditMessageXML.validate(Data(DicomAuditMessageXML.serialize(command.makeEvent()).utf8))
        }
        let invalid = try AuditCommand.Emit.parse(["--event", "unknown"])
        XCTAssertThrowsError(try invalid.makeEvent())
    }
    func test_validateValidAndMalformedFiles_exitZeroOrTwo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("message.xml")
        let event = try AuditCommand.Emit.parse([]).makeEvent()
        try DicomAuditMessageXML.serialize(event).write(to: url, atomically: true, encoding: .utf8)
        var command = try AuditCommand.Validate.parse(["--file", url.path])
        XCTAssertNoThrow(try command.run())
        try "<AuditMessage/>".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try command.run()) { XCTAssertEqual(($0 as? ExitCode)?.rawValue, 2) }
    }
    func test_emitToPlainCollector() async throws {
        let receiver = DicomAuditSyslogReceiver()
        let port = try await receiver.start(); defer { receiver.stop() }
        var command = try AuditCommand.Emit.parse(["--syslog", "127.0.0.1:\(port)", "--study-uid", "1.2.3"])
        try await command.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while receiver.received.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(receiver.received.first?.event.participantObjects.first?.objectID, "1.2.3")
    }
    func test_invalidTLSOptionsRejected() async throws {
        var emit = try AuditCommand.Emit.parse(["--tls-ca", "/unused"])
        do { try await emit.run(); XCTFail("TLS CA without TLS") }
        catch {
            XCTAssertTrue(error is ValidationError)
            XCTAssertEqual(String(describing: error), "--tls-ca requires --tls")
        }
        var receive = try AuditCommand.Receive.parse(["--tls-certificate", "/unused", "--count", "1"])
        do { try await receive.run(); XCTFail("unpaired TLS identity") }
        catch {
            XCTAssertTrue(error is ValidationError)
            XCTAssertEqual(String(describing: error), "Positive --count and paired TLS certificate/key required")
        }
    }
}
