import XCTest
import HL7v2
@testable import HL7MLLP

func mllpMessage(_ id: String = UUID().uuidString.prefix(16).description,
                 version: HL7Version = .v2_5_1) -> HL7Message {
    var pid = HL7Segment(name: "PID")
    pid[3] = HL7Field(repetitions: [HL7ExtendedID(id: "SYNTHETIC", identifierType: "MR").hl7Value])
    pid[5] = HL7Field(repetitions: [HL7PersonName(family: "Example", given: "Test").hl7Value])
    var pv1 = HL7Segment(name: "PV1"); pv1[2] = HL7Field(.text("I"))
    var builder = HL7MessageBuilder(version: version)
    builder.msh(messageType: "ADT^A01", controlID: id)
    builder.adt(event: .A01, pid: pid, pv1: pv1)
    return builder.message
}

final class MLLPAckTests: XCTestCase {
    func test_modeTable_originalAndEnhancedCodes() throws {
        let outcomes: [MLLPProcessingOutcome] = [.accepted, .rejectedStructure([]),
            .rejectedApplication(code: "app", text: "rejected"), .error(text: "error"), .uncertain(reason: "unknown")]
        for commit in [false, true] {
            for mode in HL7AckMode.allCases {
                let policy = MLLPAckPolicy(mode: mode, commitAck: commit)
                for (i, outcome) in outcomes.enumerated() {
                    let expected: HL7AckCode = commit && mode != .original
                        ? (i == 0 ? .CA : i == 1 ? .CR : .CE)
                        : (i == 0 ? .AA : i == 1 ? .AR : .AE)
                    let suppressed = mode == .never || (mode == .errors && i == 0) || (mode == .successful && i != 0)
                    XCTAssertEqual(policy.shouldAcknowledge(outcome: outcome), suppressed ? nil : expected)
                }
            }
        }
    }
    func test_msh15And16_absentNeverErrorsSuccessAlways() {
        for commit in [false, true] {
            var message = mllpMessage()
            XCTAssertEqual(HL7AckMode(message: message, commitAck: commit), .original)
            for mode in [HL7AckMode.never, .errors, .successful, .always] {
                message["MSH"]?[commit ? 15 : 16] = HL7Field(.text(mode.rawValue))
                XCTAssertEqual(HL7AckMode(message: message, commitAck: commit), mode)
                XCTAssertEqual(HL7AckMode(message: message, commitAck: !commit), .never)
            }
        }
    }
    func test_builder_mirrorsControlIDVersionAndERR() throws {
        for version in HL7SchemaRegistry.shared.versions {
            let message = mllpMessage("CONTROL", version: version)
            let finding = HL7ValidationFinding(code: .requiredMissing, path: .init(segment: "PID", field: 3))
            for commit in [false, true] {
                let ack = try XCTUnwrap(MLLPAckBuilder.ack(for: message, outcome: .rejectedStructure([finding]),
                    policy: .init(mode: .always, commitAck: commit)))
                XCTAssertEqual(ack.version, version)
                XCTAssertEqual(ack["MSA"]?[2][1][1][1].text, message.controlID)
                XCTAssertEqual(ack["MSA"]?[1][1][1][1].text, commit ? "CR" : "AR")
                XCTAssertNotNil(ack["ERR"])
                let parsed = try HL7Parser().parse(HL7Serializer().serialize(ack))
                XCTAssertEqual(parsed.version, version)
            }
        }
    }
    func test_uncertain_neverSuccessfulAndDoesNotEchoReason() throws {
        for commit in [false, true] {
            let ack = try XCTUnwrap(MLLPAckBuilder.ack(for: mllpMessage(),
                outcome: .uncertain(reason: "PRIVATE"), policy: .init(mode: .always, commitAck: commit)))
            XCTAssertEqual(ack["MSA"]?[1][1][1][1].text, commit ? "CE" : "AE")
            XCTAssertFalse(String(decoding: try HL7Serializer().serialize(ack), as: UTF8.self).contains("PRIVATE"))
        }
    }
}
