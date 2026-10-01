import XCTest
@testable import DicomCore

@MainActor
final class DicomCompletenessTrackerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)
    func test_quietPeriod_resetsOnReceivedAndFiresOnce() async {
        let tracker = DicomCompletenessTracker(rule: .init(quietPeriod: 10))
        await tracker.observeReceived(studyUID: "study", at: start)
        await tracker.observeReceived(studyUID: "study", at: start.addingTimeInterval(5))
        let early = await tracker.dueCompletions(now: start.addingTimeInterval(10))
        let due = await tracker.dueCompletions(now: start.addingTimeInterval(15))
        let repeated = await tracker.dueCompletions(now: start.addingTimeInterval(30))
        XCTAssertTrue(early.isEmpty)
        XCTAssertEqual(due.first?.objectCount, 2)
        XCTAssertTrue(repeated.isEmpty)
    }
    func test_expectedCount_firesAtThreshold() async {
        let tracker = DicomCompletenessTracker(rule: .init(expectedObjectCount: 2))
        await tracker.observeReceived(studyUID: "study", at: start)
        let early = await tracker.dueCompletions(now: start)
        await tracker.observeReceived(studyUID: "study", at: start)
        let due = await tracker.dueCompletions(now: start)
        XCTAssertTrue(early.isEmpty)
        XCTAssertEqual(due.count, 1)
    }
    func test_explicitEnd_appliesToStudyAndSeries() async {
        let tracker = DicomCompletenessTracker(rule: .init(requireExplicitEnd: true))
        await tracker.observeReceived(studyUID: "study", seriesUID: "series", at: start)
        let early = await tracker.dueCompletions(now: start)
        await tracker.markEnd(studyUID: "study", at: start)
        let due = await tracker.dueCompletions(now: start)
        XCTAssertTrue(early.isEmpty)
        XCTAssertEqual(due.count, 2)
    }
    func test_lateArrival_createsGenerationTwoAndNewEventID() async throws {
        let tracker = DicomCompletenessTracker(rule: .init(requireExplicitEnd: true))
        await tracker.observeReceived(studyUID: "study", at: start)
        await tracker.markEnd(studyUID: "study", at: start)
        let first = await tracker.dueCompletions(now: start)
        await tracker.observeReceived(studyUID: "study", at: start.addingTimeInterval(1))
        let beforeEnd = await tracker.dueCompletions(now: start.addingTimeInterval(1))
        await tracker.markEnd(studyUID: "study", at: start.addingTimeInterval(1))
        let second = await tracker.dueCompletions(now: start.addingTimeInterval(1))
        XCTAssertTrue(beforeEnd.isEmpty)
        XCTAssertEqual(first.first?.sourceRef, "study#1")
        XCTAssertEqual(second.first?.sourceRef, "study#2")
        XCTAssertNotEqual(try first.first?.lifecycleEvent().eventID, try second.first?.lifecycleEvent().eventID)
    }
    func test_combinedRules_supportAllAndAnyWhileEmptyRuleNeverFires() async {
        for matching in [DicomCompletenessRule.Matching.all, .any] {
            let tracker = DicomCompletenessTracker(rule: .init(quietPeriod: 10, expectedObjectCount: 1, matching: matching))
            await tracker.observeReceived(studyUID: "study", at: start)
            let due = await tracker.dueCompletions(now: start)
            XCTAssertEqual(due.count, matching == .all ? 0 : 1)
        }
        let empty = DicomCompletenessTracker(rule: .init())
        await empty.observeReceived(studyUID: "study", at: start)
        await empty.markEnd(studyUID: "study", at: start)
        let due = await empty.dueCompletions(now: start.addingTimeInterval(100))
        XCTAssertTrue(due.isEmpty)
    }
}
