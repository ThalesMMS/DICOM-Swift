import Foundation
import XCTest
import DicomCore

final class DicomAuditSyslogLoopbackTests: XCTestCase, @unchecked Sendable {
    func event() -> DicomAuditEvent {
        DicomAuditMessages.dicomInstancesAccessed(principal: nil,
            context: .init(protocol: .local, at: Date(timeIntervalSince1970: 0)),
            resources: [.init(kind: .study, id: "1.2.3")], source: .init(auditSourceID: "Ω-audit"))
    }
    func waitForMessage(_ receiver: DicomAuditSyslogReceiver) async throws -> DicomAuditSyslogMessage {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while receiver.received.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return try XCTUnwrap(receiver.received.first)
    }
    func test_plainLoopback_octetCountingAndParse() async throws {
        let receiver = DicomAuditSyslogReceiver()
        let port = try await receiver.start(); defer { receiver.stop() }
        let sink = try DicomAuditSyslogSink(host: "127.0.0.1", port: port)
        try await sink.record(event())
        let message = try await waitForMessage(receiver)
        XCTAssertEqual(message.event, event()); XCTAssertEqual(message.messageID, "DICOM")
        XCTAssertEqual(message.priority, 86)
    }
    func test_fragmentedAndCoalescedFrames_countUTF8Octets() throws {
        let message = try DicomAuditSyslogFraming.message(event())
        let framed = DicomAuditSyslogFraming.frame(message)
        XCTAssertTrue(String(decoding: framed, as: UTF8.self).hasPrefix("\(message.count) "))
        var buffer = Data(); var messages: [Data] = []
        for byte in framed { buffer.append(byte); messages += try DicomAuditSyslogFraming.extract(from: &buffer) }
        XCTAssertEqual(messages, [message]); XCTAssertTrue(buffer.isEmpty)
        buffer = framed + framed
        XCTAssertEqual(try DicomAuditSyslogFraming.extract(from: &buffer), [message, message])
        for bad in ["0 ", "01 a", "-1 a", "999999999999999 x", "4294967295 x"] {
            var bytes = Data(bad.utf8); XCTAssertThrowsError(try DicomAuditSyslogFraming.extract(from: &bytes))
        }
    }
    func test_tlsLoopback_existingSyntheticPEMAndTrustedCA() async throws {
        let fixture = try material()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let receiver = DicomAuditSyslogReceiver(tls: .init(mode: .enabled,
            material: .init(certificatePath: fixture.certificate.path, privateKeyPath: fixture.key.path)))
        let port = try await receiver.start(); defer { receiver.stop() }
        let sink = try DicomAuditSyslogSink(host: "127.0.0.1", port: port,
            tls: .init(mode: .enabled, serverName: "localhost", material: .init(trustStorePath: fixture.ca.path)))
        try await sink.record(event())
        let received = try await waitForMessage(receiver)
        XCTAssertEqual(received.event, event())
    }
    func test_tlsWrongCAAndPlainClient_cannotDeliverAuditEvent() async throws {
        let fixture = try material()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let receiver = DicomAuditSyslogReceiver(tls: .init(mode: .enabled,
            material: .init(certificatePath: fixture.certificate.path, privateKeyPath: fixture.key.path)))
        let port = try await receiver.start(); defer { receiver.stop() }
        let wrong = try DicomAuditSyslogSink(host: "127.0.0.1", port: port,
            tls: .init(mode: .enabled, serverName: "localhost", material: .init(trustStorePath: fixture.wrongCA.path)),
            timeout: 1, maximumAttempts: 1)
        do { try await wrong.record(event()); XCTFail("untrusted CA") } catch {}
        // TCP write completion alone cannot attest receiver acceptance; no XML may appear on a TLS listener.
        let plain = try DicomAuditSyslogSink(host: "127.0.0.1", port: port, timeout: 1, maximumAttempts: 1)
        try? await plain.record(event())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(receiver.received.isEmpty)
    }
    func test_unavailableCollector_returnsWithinBound() async throws {
        let receiver = DicomAuditSyslogReceiver()
        let port = try await receiver.start(); receiver.stop()
        let sink = try DicomAuditSyslogSink(host: "127.0.0.1", port: port, timeout: 0.3, maximumAttempts: 2)
        let start = ContinuousClock.now
        do { try await sink.record(event()); XCTFail("collector unavailable") } catch {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func test_receivedUntrustedXML_minimizesBeforeJSONOutput() throws {
        let clean = String(decoding: try DicomAuditSyslogFraming.message(event()), as: UTF8.self)
        let dirty = clean.replacingOccurrences(of: "<ParticipantObjectName/>",
            with: "<ParticipantObjectName>Patient Name</ParticipantObjectName><ParticipantObjectDetail type=\"error\" value=\"" + Data("token=super-secret".utf8).base64EncodedString() + "\"/>")
        let message = try DicomAuditSyslogFraming.parse(Data(dirty.utf8))
        let json = String(decoding: try DicomWebhookCanonicalJSON.encode(message), as: UTF8.self)
        XCTAssertFalse(json.contains("Patient Name")); XCTAssertFalse(json.contains("super-secret"))
        XCTAssertEqual(String(decoding: message.event.participantObjects[0].objectDetail[0].value, as: UTF8.self), "[redacted]")
    }
    private func material() throws -> (directory: URL, ca: URL, certificate: URL, key: URL, wrongCA: URL) {
        // Reuse the existing synthetic PEM fixture without changing another target or committing key copies.
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DicomCoreTests/DicomTLSTestMaterial.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ name: String) throws -> URL {
            let start = try XCTUnwrap(source.range(of: "private let \(name) = \"\"\"\n"))
            let end = try XCTUnwrap(source.range(of: "\n\"\"\"", range: start.upperBound..<source.endIndex))
            let url = directory.appendingPathComponent(name + ".pem")
            try String(source[start.upperBound..<end.lowerBound]).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        return try (directory, write("caCertificatePEM"), write("serverCertificatePEM"), write("serverPrivateKeyPEM"), write("wrongCACertificatePEM"))
    }
}
