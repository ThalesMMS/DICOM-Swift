import XCTest
import HL7v2
@testable import HL7MLLP

final class MLLPDestinationPolicyTests: XCTestCase {
    func test_unknownOrders_requireReconciliationUnderEveryPolicy() {
        for type in ["ORM", "ORU", "CUSTOM"] {
            var message = mllpMessage("ORDER")
            message["MSH"]?[9] = HL7Field(.text(type))
            for resend in [MLLPDestinationPolicy.Resend.never, .onlyIfUnsent, .idempotentOnly] {
                let policy = MLLPDestinationPolicy(idempotency: .nonIdempotent(orderTypes: ["CUSTOM"]), resend: resend)
                XCTAssertEqual(MLLPOutbound.decision(for: message, policy: policy, attempts: 1),
                               .requiresReconciliation("ORDER"))
                XCTAssertFalse(MLLPOutbound.decision(for: message, policy: policy, attempts: 1).description.contains("ORDER"))
            }
        }
    }
    func test_idempotentAllowlist_unsentEvidenceAndAttemptLimit() {
        for type in ["ADT", "ACK", "QBP"] {
            var message = mllpMessage()
            message["MSH"]?[9] = HL7Field(.text(type))
            XCTAssertEqual(MLLPOutbound.decision(for: message, policy: .init(resend: .idempotentOnly), attempts: 1), .resend)
            XCTAssertEqual(MLLPOutbound.decision(for: message, policy: .init(resend: .idempotentOnly), attempts: 3), .stop)
            XCTAssertEqual(MLLPOutbound.decision(for: message, policy: .init(resend: .onlyIfUnsent), attempts: 1), .stop)
            XCTAssertEqual(MLLPOutbound.decision(for: message, policy: .init(resend: .onlyIfUnsent), attempts: 1,
                                                definitelyUnsent: true), .resend)
            XCTAssertEqual(MLLPOutbound.decision(for: message, policy: .init(), attempts: 1, definitelyUnsent: true), .stop)
        }
    }
}
