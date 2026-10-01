import Foundation
import XCTest
@testable import DicomCore

final class DicomRetentionPolicyTests: XCTestCase {
    func test_ancestorProtectionAndPrivacy_propagateToDescendants() {
        let now = Date()
        let graph = DicomProtectionGraph(parents: ["child": "parent", "derivative": "child"])
        let own: [String: DicomObjectProtection] = [
            "parent": .init(protected: true, retainUntil: now.addingTimeInterval(100), privacyFlags: [.vip]),
            "child": .init(privacyFlags: [.researchOnly]), "derivative": .init(privacyFlags: [.restricted])]
        let result = graph.effective(for: "derivative", own: own, now: now)
        XCTAssertTrue(result.protected)
        XCTAssertEqual(result.privacyFlags, [.vip, .researchOnly, .restricted])
        XCTAssertEqual(result.retainUntil, now.addingTimeInterval(100))
        XCTAssertTrue(graph.deletionBlockers(for: "derivative", own: own, now: now)
            .contains(.inheritedFrom("parent", .protected)))
    }
    func test_expiredRetention_doesNotBlockAndLegalHoldDoes() {
        let now = Date()
        let graph = DicomProtectionGraph(parents: [:])
        XCTAssertTrue(graph.deletionBlockers(for: "a", own: ["a": .init(retainUntil: now.addingTimeInterval(-1))],
            now: now).isEmpty)
        XCTAssertEqual(graph.deletionBlockers(for: "a", own: ["a": .init(legalHold: true)], now: now), [.legalHold])
    }
    func test_cycle_terminatesAndUnionsAllAncestors() {
        let graph = DicomProtectionGraph(parents: ["a": "b", "b": "a"])
        let result = graph.effective(for: "a", own: ["b": .init(legalHold: true)], now: Date())
        XCTAssertTrue(result.legalHold)
    }
}
