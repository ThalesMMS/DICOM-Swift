import XCTest
@testable import DicomCore

final class DicomDeliveryRetryPolicyTests: XCTestCase {
    func test_classifiedBudgets() {
        let policy = DicomDeliveryRetryPolicy()
        let now = Date()
        for errorClass: DicomDeliveryErrorClass in [.permanent, .rejectedByDestination, .signatureRejected, .cancelled] {
            XCTAssertNil(policy.nextAttempt(after: 1, class: errorClass, now: now))
        }
        XCTAssertNotNil(policy.nextAttempt(after: 7, class: .transient, now: now))
        XCTAssertNil(policy.nextAttempt(after: 8, class: .transient, now: now))
        XCTAssertNotNil(policy.nextAttempt(after: 4, class: .uncertain, now: now))
        XCTAssertNil(policy.nextAttempt(after: 5, class: .uncertain, now: now))
    }
    func test_exponentialJitterBoundsAndRetryAfter() {
        let now = Date(timeIntervalSince1970: 1000)
        let upper = DicomDeliveryRetryPolicy(maxAttempts: [.transient: 99], random: { 1 })
        let lower = DicomDeliveryRetryPolicy(random: { 0 })
        XCTAssertEqual(upper.nextAttempt(after: 1, class: .transient, now: now), now.addingTimeInterval(2))
        XCTAssertEqual(upper.nextAttempt(after: 3, class: .transient, now: now), now.addingTimeInterval(8))
        XCTAssertEqual(upper.nextAttempt(after: 50, class: .transient, now: now), now.addingTimeInterval(900))
        XCTAssertEqual(lower.nextAttempt(after: 1, class: .transient, now: now), now)
        XCTAssertEqual(lower.nextAttempt(after: 1, class: .transient, retryAfter: 1200, now: now),
                       now.addingTimeInterval(1200))
    }
}
