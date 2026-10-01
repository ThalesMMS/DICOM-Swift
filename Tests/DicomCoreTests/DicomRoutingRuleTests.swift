import XCTest
@testable import DicomCore

final class DicomRoutingRuleTests: XCTestCase {
    typealias Fixture = DicomRoutingEvaluatorTests

    func test_ruleDefaults_andValidRule() throws {
        let rule = Fixture.rule()
        XCTAssertTrue(rule.enabled)
        XCTAssertTrue(rule.requiresPHIAuthorization)
        XCTAssertEqual(rule.priority, .routine)
        try DicomRoutingRuleValidator.validate(rule)
    }

    func test_invalidRules_throwTypedErrors() {
        let cases: [(DicomRoutingRule, DicomRoutingRuleError)] = [
            (Fixture.rule(" "), .emptyID),
            (Fixture.rule(destination: ""), .emptyDestination),
            (Fixture.rule(criteria: []), .emptyCriteria),
            (Fixture.rule(destination: "https://untrusted.example"), .destinationLooksLikeContentReference),
            (Fixture.rule(destination: "AE TITLE"), .destinationLooksLikeContentReference),
            (Fixture.rule(destination: "pacs\n"), .destinationLooksLikeContentReference)
        ]
        for (rule, expected) in cases {
            XCTAssertThrowsError(try DicomRoutingRuleValidator.validate(rule)) {
                XCTAssertEqual($0 as? DicomRoutingRuleError, expected)
            }
        }
    }

    func test_emptyCriterionValues_areRejected() {
        let criteria: [DicomRoutingCriterion] = [
            .modality(in: []), .sopClassUID(in: [""]), .callingAETitle(in: [" "]),
            .calledAETitle(in: []), .bodyPartExamined(in: []), .stationName(in: []),
            .transferSyntax(in: []), .institutionName(matches: " "), .studyDescription(contains: "")
        ]
        for criterion in criteria {
            XCTAssertThrowsError(try DicomRoutingRuleValidator.validate(Fixture.rule(criteria: [criterion]))) {
                XCTAssertEqual($0 as? DicomRoutingRuleError, .invalidCriterionValue)
            }
        }
    }

    func test_rulesRoundTrip_haveStableBytesIncludingSetsAndPolicies() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for policy: DicomRepresentationPolicy in [.originalOnly, .losslessEquivalents,
                                                 .lossyDerivedAllowed(authorization: "approved")] {
            let rule = Fixture.rule(criteria: Fixture.allCriteria, representation: policy)
            let bytes = try encoder.encode(rule)
            let decoded = try JSONDecoder().decode(DicomRoutingRule.self, from: bytes)
            XCTAssertEqual(decoded, rule)
            XCTAssertEqual(try encoder.encode(decoded), bytes)
            XCTAssertEqual(try encoder.encode(rule), bytes)
        }
        let a = Fixture.rule(criteria: [.modality(in: Set(["CT", "MR", "US"]))])
        let b = Fixture.rule(criteria: [.modality(in: Set(["US", "MR", "CT"]))])
        XCTAssertEqual(try encoder.encode(a), try encoder.encode(b))
    }

    func test_decisionsRoundTrip_haveStableBytesForEveryReasonAndOutcome() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reasons: [DicomRoutingDecision.Reason] = [
            .ruleDisabled, .criterionNotMet, .destinationUnknown, .destinationDisabled,
            .phiNotAuthorized, .representationIneligible, .lossyNotAcceptedByDestination,
            .transferSyntaxNotAccepted, .duplicateRoute, .contentReferenceIgnored, .matched
        ]
        for outcome: DicomRoutingDecision.Outcome in [.route, .skipped, .refused] {
            let value = DicomRoutingDecision(ruleID: "a", destinationID: outcome == .route ? "pacs" : nil,
                outcome: outcome, reasons: reasons,
                criteriaEvaluated: [.init(description: "modality", matched: true)],
                dryRun: true, evaluatedAt: Fixture.now)
            let bytes = try encoder.encode(value)
            XCTAssertEqual(try encoder.encode(value), bytes)
            let decoded = try JSONDecoder().decode(DicomRoutingDecision.self, from: bytes)
            XCTAssertEqual(decoded, value)
            XCTAssertEqual(try encoder.encode(decoded), bytes)
        }
    }
}
