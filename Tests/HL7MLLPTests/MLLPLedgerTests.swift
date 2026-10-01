import Foundation
import XCTest
import HL7v2
import DicomCore
@testable import HL7MLLP

@MainActor
final class MLLPLedgerTests: XCTestCase {
    func test_sharedJournal_observesAppendsAndReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try MLLPJSONLLedger(directory: directory)
        let second = try MLLPJSONLLedger(directory: directory)
        let message = mllpMessage()
        let key = MLLPMessageKey(message: message, raw: try HL7Serializer().serialize(message))
        _ = try await first.begin(key: key)
        try await second.recordOutcome(key: key, outcome: .accepted, ackBytes: Data())
        let replay = try await first.begin(key: key)
        XCTAssertEqual(replay, .duplicateAlreadyAcked(ack: Data(), outcome: .accepted))
        let journal = directory.appendingPathComponent("inbound.jsonl")
        let original = try Data(contentsOf: journal)
        let rewritten = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "accepted", with: "corruptd")
        try Data(rewritten.utf8).write(to: journal)
        do { _ = try await first.begin(key: key); XCTFail("Same-size corrupt rewrite was hidden") }
        catch MLLPLedgerError.corruptJournal {}
        try Data().write(to: journal, options: .atomic)
        let replaced = try await first.begin(key: key)
        XCTAssertEqual(replaced, .process)
    }

    func test_cachedJournal_truncatesTornAppendBeforeNextRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try MLLPJSONLLedger(directory: directory)
        let message = mllpMessage()
        let key = MLLPMessageKey(message: message, raw: try HL7Serializer().serialize(message))
        _ = try await ledger.begin(key: key)
        let journal = directory.appendingPathComponent("inbound.jsonl")
        let handle = try FileHandle(forWritingTo: journal)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"torn\":".utf8))
        try handle.close()
        try await ledger.recordOutcome(key: key, outcome: .accepted, ackBytes: Data())
        let restarted = try MLLPJSONLLedger(directory: directory)
        let replay = try await restarted.begin(key: key)
        XCTAssertEqual(replay, .duplicateAlreadyAcked(ack: Data(), outcome: .accepted))
        XCTAssertEqual(try Data(contentsOf: journal).split(separator: 10).count, 2)
    }

    func test_processingAuditFailure_recordsUncertainOutcomeForRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try MLLPJSONLLedger(directory: directory)
        let processor = MLLPTestProcessor()
        let audit = MLLPAuditing(recorder: .init(sinks: [MLLPProcessedAuditFailure()], policy: .failClosed))
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure),
            processor: processor, audit: audit, ledger: ledger)
        let port = try await listener.start()
        let client = MLLPClient(host: "127.0.0.1", port: port)
        let message = mllpMessage()
        let result = try? await client.send(message, timeout: 0.5)
        XCTAssertNotEqual(result?.description, "acknowledged(AA)")
        await client.disconnect(); await listener.stop()
        let restarted = try MLLPJSONLLedger(directory: directory)
        let key = MLLPMessageKey(message: message, raw: try HL7Serializer().serialize(message))
        let recovery = try await restarted.recover()
        XCTAssertEqual(recovery, [key])
        let replay = try await restarted.begin(key: key)
        XCTAssertEqual(replay, .duplicateAlreadyAcked(ack: Data(), outcome: .uncertain(reason: "processingIncomplete")))
        let calls = await processor.calls
        XCTAssertEqual(calls, 1)
    }

    func test_suppressedAck_replaysStoredOutcomeBeforeAndAfterRestart() async throws {
        let outcomes: [MLLPProcessingOutcome] = [.accepted,
            .rejectedStructure([
                .init(code: .requiredMissing, path: .init(segment: "OBX", field: 5, component: 2, subcomponent: 1,
                    repetition: 3), severity: .warning, detail: "synthetic finding", segmentOccurrence: 2),
                .init(code: .structureUnknown, path: .init())
            ]),
            .rejectedApplication(code: "synthetic", text: "Rejected"), .error(text: "Failure"),
            .uncertain(reason: "Confirmation unavailable")]
        for restarted in [false, true] {
            for outcome in outcomes {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let message = mllpMessage()
                let payload = try HL7Serializer().serialize(message)
                let key = MLLPMessageKey(message: message, raw: payload)
                let ledger: any MLLPInboundLedger
                if restarted {
                    let original = try MLLPJSONLLedger(directory: directory)
                    _ = try await original.begin(key: key)
                    try await original.recordOutcome(key: key, outcome: outcome, ackBytes: Data())
                    ledger = try MLLPJSONLLedger(directory: directory)
                } else { ledger = MLLPInMemoryLedger() }
                let processor = MLLPTestProcessor(outcome)
                let observations = MLLPReplayObservations()
                let listener = MLLPListener(configuration: .init(ackPolicy: .init(mode: .never),
                    exposure: mllpLocalExposure), processor: processor, ledger: ledger,
                    observer: { _, result, code in await observations.record(result, code: code) })
                let port = try await listener.start()
                let raw = try await mllpRaw(port)
                let wire = try MLLPFramer.frame(payload)
                try await raw.send(frame: wire)
                try await raw.send(frame: wire)
                await mllpEventually { await observations.events.count == 2 }
                let events = await observations.events
                XCTAssertEqual(events.map(\.0), [outcome, outcome], "restarted=\(restarted)")
                XCTAssertTrue(events.allSatisfy { $0.1 == nil })
                let calls = await processor.calls
                XCTAssertEqual(calls, restarted ? 0 : 1)
                await raw.cancel(); await listener.stop()
            }
        }
    }
    func test_duplicate_replaysExactACKWithoutProcessing() async throws {
        let processor = MLLPTestProcessor()
        let ledger = MLLPInMemoryLedger()
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: processor, ledger: ledger)
        let port = try await listener.start()
        let raw = try await mllpRaw(port)
        let wire = try MLLPFramer.frame(HL7Serializer().serialize(mllpMessage()))
        try await raw.send(frame: wire)
        let first = try await mllpNext(raw)
        try await raw.send(frame: wire)
        let second = try await mllpNext(raw)
        XCTAssertEqual(first.payload, second.payload)
        let calls = await processor.calls
        XCTAssertEqual(calls, 1)
        await raw.cancel(); await listener.stop()
    }
    func test_sameControlIDDifferentPayload_processesBoth() async throws {
        let processor = MLLPTestProcessor()
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: processor,
                                    ledger: MLLPInMemoryLedger())
        let port = try await listener.start()
        let raw = try await mllpRaw(port)
        var message = mllpMessage("SAME")
        for value in ["ONE", "TWO"] {
            message["PID"]?[3] = HL7Field(.text(value))
            try await raw.send(frame: MLLPFramer.frame(HL7Serializer().serialize(message)))
            _ = try await mllpNext(raw)
        }
        let calls = await processor.calls
        XCTAssertEqual(calls, 2)
        await raw.cancel(); await listener.stop()
    }
    func test_crashAfterRecord_recoveryAndReplaySurviveJSONLRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let message = mllpMessage()
        let payload = try HL7Serializer().serialize(message)
        let key = MLLPMessageKey(message: message, raw: payload)
        let ledger = try MLLPJSONLLedger(directory: directory)
        let decision = try await ledger.begin(key: key)
        XCTAssertEqual(decision, .process)
        let ack = try XCTUnwrap(MLLPAckBuilder.ack(for: message, outcome: .accepted, policy: .init()))
        let ackBytes = try MLLPFramer.frame(HL7Serializer().serialize(ack))
        try await ledger.recordOutcome(key: key, outcome: .accepted, ackBytes: ackBytes)
        let restarted = try MLLPJSONLLedger(directory: directory)
        let uncertain = try await restarted.recover()
        XCTAssertEqual(uncertain, [key])
        let processor = MLLPTestProcessor()
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: processor, ledger: restarted)
        let port = try await listener.start()
        let raw = try await mllpRaw(port)
        try await raw.send(frame: MLLPFramer.frame(payload))
        let replay = try await mllpNext(raw)
        XCTAssertEqual(try MLLPFramer.frame(replay.payload), ackBytes)
        await mllpEventually { (try? await restarted.recover().isEmpty) == true }
        let calls = await processor.calls
        XCTAssertEqual(calls, 0)
        await raw.cancel(); await listener.stop()
        let again = try MLLPJSONLLedger(directory: directory)
        let final = try await again.begin(key: key)
        XCTAssertEqual(final, .duplicateAlreadyAcked(ack: ackBytes, outcome: .accepted))
    }
    func test_inProgress_andInvalidTransitions() async throws {
        let ledger = MLLPInMemoryLedger()
        let message = mllpMessage()
        let key = MLLPMessageKey(message: message, raw: try HL7Serializer().serialize(message))
        _ = try await ledger.begin(key: key)
        let second = try await ledger.begin(key: key)
        XCTAssertEqual(second, .duplicateInProgress)
        do { try await ledger.markAckSent(key: key); XCTFail("Missing outcome") } catch {}
        let processor = MLLPTestProcessor()
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: processor, ledger: ledger)
        let port = try await listener.start()
        let client = MLLPClient(host: "127.0.0.1", port: port)
        let result = try await client.send(message, timeout: 2)
        XCTAssertEqual(result.description, "negativeAck(AR)")
        let calls = await processor.calls
        XCTAssertEqual(calls, 0)
        await client.disconnect(); await listener.stop()
    }
}

private actor MLLPReplayObservations {
    var events: [(MLLPProcessingOutcome, String?)] = []
    func record(_ outcome: MLLPProcessingOutcome, code: String?) { events.append((outcome, code)) }
}

private struct MLLPProcessedAuditFailure: DicomAuditSink {
    func record(_ event: DicomAuditEvent) async throws {
        if event.eventIdentification.eventID.code == "110107" { throw DicomAuditError.sinkUnavailable }
    }
    func flush() async throws {}
}
