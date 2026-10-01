import Foundation
import XCTest
import HL7v2
import DicomCore
@testable import HL7MLLP

@MainActor
final class MLLPNoContentLeakTests: XCTestCase {
    func test_descriptions_neverIncludePayload() async throws {
        let sentinel = "SECRET_PATIENT_SENTINEL"
        let payload = Data(sentinel.utf8)
        let bad = Data([11]) + payload + Data([11])
        var strict = MLLPDeframer()
        var descriptions: [String] = []
        do { _ = try strict.feed(bad); XCTFail("Expected invalid framing") }
        catch { descriptions += [String(describing: error), String(reflecting: error), error.localizedDescription] }
        var limits = MLLPLimits()
        limits.recovery = .resynchronize
        let accumulator = MLLPAccumulator(limits: limits)
        _ = try await accumulator.feed(Data([99]) + bad + payload + Data([28, 13]))
        let frame = await accumulator.next()
        descriptions += [String(describing: frame!), String(reflecting: frame!), String(describing: frame!.diagnostics)]
        let stats = await accumulator.stats
        descriptions += [String(describing: stats), String(reflecting: stats)]
        await accumulator.close()
        let report = await accumulator.finishReport
        descriptions += [String(describing: report), String(reflecting: report)]
        for reason in [MLLPLossReason.messageLimit, .bufferLimit, .invalidTrailer, .incompleteBlock,
                       .unsafePayload, .junkLimit, .pendingFramesLimit, .closed, .invalidLimits] {
            descriptions.append(String(describing: MLLPFramingError(reason: reason, byteOffset: 2, droppedBytes: 3)))
        }
        for description in descriptions {
            XCTAssertFalse(description.contains(sentinel))
            XCTAssertFalse(description.contains(payload.map { String(format: "%02x", $0) }.joined()))
        }
    }
}

extension MLLPNoContentLeakTests {
    func test_auditMetricsResultsAndErrors_doNotIncludeClinicalContent() async throws {
        let sentinel = "SECRET_PATIENT_SENTINEL"
        var message = mllpMessage(sentinel)
        message["MSH"]?[9] = HL7Field(.text(sentinel))
        let sink = DicomInMemoryAuditSink()
        let audit = MLLPAuditing(recorder: .init(sinks: [sink], policy: .failClosed))
        for activity in [MLLPAuditing.Activity.start, .stop, .accept, .refuse, .deny, .processed, .exposure] {
            try await audit.record(activity, message: message, outcome: .rejectedApplication(code: sentinel, text: sentinel))
        }
        for event in await sink.events {
            let json = try DicomAuditMessageJSON.encode(event)
            XCTAssertFalse(String(decoding: json, as: UTF8.self).contains(sentinel))
            for object in event.participantObjects {
                for detail in object.objectDetail {
                    XCTAssertFalse(String(decoding: detail.value, as: UTF8.self).contains(sentinel))
                }
            }
        }
        let result = MLLPSendResult.negativeAck(.AE, sentinel)
        let outcome = MLLPProcessingOutcome.error(text: sentinel)
        let descriptions = [String(describing: result), String(reflecting: result),
            String(describing: outcome), String(reflecting: outcome),
            String(describing: MLLPConnectionMetrics()), String(describing: MLLPClientDiagnostics()),
            String(describing: MLLPError.invalidMessage), String(reflecting: MLLPError.connectionFailed)]
        for text in descriptions { XCTAssertFalse(text.contains(sentinel)) }
    }
}
