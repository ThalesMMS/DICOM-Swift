import Foundation
import XCTest
@testable import DicomCore

private actor RecoveringAuditSink: DicomAuditSink {
    var fails = true
    var events: [DicomAuditEvent] = []
    func recover() { fails = false }
    func record(_ event: DicomAuditEvent) throws {
        if fails { throw DicomAuditError.sinkUnavailable }; events.append(event)
    }
    func flush() throws { if fails { throw DicomAuditError.sinkUnavailable } }
}
private struct FailingAuditFileSystem: DicomAuditFileSystem {
    func read(_ url: URL) throws -> Data { throw DicomAuditError.fileSystemFailure }
    func append(_ data: Data, to url: URL, maxBytes: Int64) throws { throw DicomAuditError.fileSystemFailure }
    func replace(_ url: URL, with data: Data) throws { throw DicomAuditError.fileSystemFailure }
}
final class DicomAuditRecorderTests: XCTestCase, @unchecked Sendable {
    func event() -> DicomAuditEvent { DicomAuditMessages.dicomInstancesAccessed(principal: nil,
        context: .init(protocol: .local, at: Date(timeIntervalSince1970: 0)), resources: [.init(kind: .study, id: "1.2.3")]) }
    func test_failClosedThrows_andBestEffortCounts() async throws {
        let sink = RecoveringAuditSink()
        let closed = DicomAuditRecorder(sinks: [sink], policy: .failClosed)
        do { try await closed.record(event()); XCTFail("must abort") }
        catch { XCTAssertEqual(error as? DicomAuditError, .sinkUnavailable) }
        let best = DicomAuditRecorder(sinks: [sink], policy: .bestEffort)
        try await best.record(event())
        let stats = await best.stats(); XCTAssertEqual(stats.dropped, 1); XCTAssertEqual(stats.sinkFailures, 1)
        let empty = DicomAuditRecorder(sinks: [], policy: .failClosed)
        do { try await empty.record(event()); XCTFail("no sink") } catch { XCTAssertEqual(error as? DicomAuditError, .sinkUnavailable) }
    }
    func test_spoolPersistsAndDrainsAfterRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RecoveringAuditSink()
        let recorder = DicomAuditRecorder(sinks: [sink], policy: .spool(directory: directory, maxBytes: 100000))
        try await recorder.record(event()); try await recorder.record(event())
        let url = directory.appendingPathComponent("audit.jsonl")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.split(separator: 10).count, 2)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        await sink.recover()
        // A fresh recorder can recover the durable journal after restart.
        let restarted = DicomAuditRecorder(sinks: [sink], policy: .spool(directory: directory, maxBytes: 100000))
        try await restarted.drainSpool()
        XCTAssertTrue(try Data(contentsOf: url).isEmpty)
        let events = await sink.events; XCTAssertEqual(events, [event(), event()])
        let stats = await restarted.stats(); XCTAssertEqual(stats.drained, 2)
    }
    func test_spoolFullAndFilesystemFailure_propagate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (fs, maximum, expected) in [(DicomAuditLocalFileSystem() as any DicomAuditFileSystem, Int64(1), DicomAuditError.spoolFull),
                                       (FailingAuditFileSystem() as any DicomAuditFileSystem, Int64(100000), .fileSystemFailure)] {
            let recorder = DicomAuditRecorder(sinks: [RecoveringAuditSink()], policy: .spool(directory: directory, maxBytes: maximum), fileSystem: fs)
            do { try await recorder.record(event()); XCTFail("durability failure") }
            catch { XCTAssertEqual(error as? DicomAuditError, expected) }
        }
    }
    func test_fileSinkWritesCanonicalDurableJSONLine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let sink = DicomFileAuditSink(url: url)
        try await sink.record(event()); try await sink.flush()
        XCTAssertEqual(try Data(contentsOf: url), try DicomAuditMessageJSON.encode(event()) + Data([10]))
    }
}
