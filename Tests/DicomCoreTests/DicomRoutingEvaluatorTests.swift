import XCTest
@testable import DicomCore

final class DicomRoutingEvaluatorTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_000)

    static func subject(phi: Bool = true, references: [String] = []) -> DicomRoutingSubject {
        .init(sopInstanceUID: "2.25.1", sopClassUID: "2.25.2", studyInstanceUID: "2.25.3",
              seriesInstanceUID: "2.25.4", modality: "CT", institutionName: "Hospital",
              studyDescription: "Chest CT", bodyPartExamined: "CHEST", stationName: "SCANNER",
              callingAETitle: "SENDER", calledAETitle: "RECEIVER", priority: .stat,
              isDerived: false, phiAuthorized: phi, transferSyntaxUID: "1.2.840.10008.1.2.1",
              contentReferences: references)
    }

    static func rule(_ id: String = "a", destination: String = "pacs", enabled: Bool = true,
                     criteria: [DicomRoutingCriterion] = [.modality(in: ["CT"])],
                     representation: DicomRepresentationPolicy = .originalOnly,
                     requiresPHI: Bool = true, priority: DicomRoutingPriority = .routine) -> DicomRoutingRule {
        .init(id: id, name: id, enabled: enabled, criteria: criteria, destinationID: destination,
              representation: representation, priority: priority, requiresPHIAuthorization: requiresPHI,
              createdAt: now, updatedAt: now)
    }

    static func destination(enabled: Bool = true, lossy: Bool = true,
                            syntaxes: [String]? = nil) -> DicomRoutingDestination {
        .init(id: "pacs", kind: .dimseStore, displayName: "Configured PACS", enabled: enabled,
              acceptsLossy: lossy, acceptedTransferSyntaxUIDs: syntaxes)
    }

    static let allCriteria: [DicomRoutingCriterion] = [
        .modality(in: ["MR", "CT"]), .sopClassUID(in: ["2.25.2"]),
        .callingAETitle(in: ["SENDER"]), .calledAETitle(in: ["RECEIVER"]),
        .institutionName(matches: "HOSPITAL"), .studyDescription(contains: "Chest"),
        .bodyPartExamined(in: ["CHEST"]), .stationName(in: ["SCANNER"]),
        .priority(is: .stat), .isDerived(false), .hasPHIAuthorization(true),
        .transferSyntax(in: ["1.2.840.10008.1.2.1"])
    ]

    func test_allCriteriaMatch_routesWithEveryCriterionRecorded() {
        let evaluator = DicomRoutingEvaluator(rules: [Self.rule(criteria: Self.allCriteria)],
            destinations: DicomRoutingDestinationCatalog(destinations: [Self.destination()]))
        let plan = evaluator.evaluate(Self.subject(), now: Self.now)
        XCTAssertEqual(plan.routed.count, 1)
        XCTAssertEqual(plan.decisions[0].criteriaEvaluated.count, 12)
        XCTAssertTrue(plan.decisions[0].criteriaEvaluated.allSatisfy(\.matched))
        XCTAssertEqual(plan.decisions[0].reasons, [.matched])
    }

    func test_failingCriterion_skipsAndStillEvaluatesEveryCriterion() {
        let criteria = [DicomRoutingCriterion.modality(in: ["MR"])] + Self.allCriteria
        let evaluator = DicomRoutingEvaluator(rules: [Self.rule(criteria: criteria)],
            destinations: DicomRoutingDestinationCatalog(destinations: [Self.destination()]))
        let decision = evaluator.evaluate(Self.subject(), now: Self.now).decisions[0]
        XCTAssertEqual(decision.outcome, .skipped)
        XCTAssertEqual(decision.reasons, [.criterionNotMet])
        XCTAssertEqual(decision.criteriaEvaluated.count, 13)
        XCTAssertFalse(decision.criteriaEvaluated[0].matched)
        XCTAssertEqual(decision.criteriaEvaluated[0].description, criteria[0].description)
        XCTAssertTrue(decision.criteriaEvaluated.dropFirst().allSatisfy(\.matched))
    }

    func test_eachCriterionMismatch_isReported() {
        let failures: [DicomRoutingCriterion] = [
            .modality(in: ["MR"]), .sopClassUID(in: ["wrong"]), .callingAETitle(in: ["wrong"]),
            .calledAETitle(in: ["wrong"]), .institutionName(matches: "Hosp"),
            .studyDescription(contains: "chest"), .bodyPartExamined(in: ["HEAD"]),
            .stationName(in: ["wrong"]), .priority(is: .routine), .isDerived(true),
            .hasPHIAuthorization(false), .transferSyntax(in: ["wrong"])
        ]
        for criterion in failures {
            let evaluator = DicomRoutingEvaluator(rules: [Self.rule(criteria: [criterion])],
                destinations: DicomRoutingDestinationCatalog(destinations: [Self.destination()]))
            let decision = evaluator.evaluate(Self.subject(), now: Self.now).decisions[0]
            XCTAssertEqual(decision.outcome, .skipped, criterion.description)
            XCTAssertEqual(decision.criteriaEvaluated, [.init(description: criterion.description, matched: false)])
        }
    }

    func test_contentReferences_neverSupplyDestinations() {
        let subject = Self.subject(references: ["EVIL_AE", "https://untrusted.example/stow", "pacs"])
        let catalog = DicomRoutingDestinationCatalog(destinations: [Self.destination()])
        let empty = DicomRoutingEvaluator(rules: [], destinations: catalog).evaluate(subject, now: Self.now)
        XCTAssertTrue(empty.routed.isEmpty)
        XCTAssertEqual(empty.reasons, [.contentReferenceIgnored])
        for id in ["EVIL_AE", "https://untrusted.example/stow"] {
            let plan = DicomRoutingEvaluator(rules: [Self.rule(destination: id)], destinations: catalog)
                .evaluate(subject, now: Self.now)
            XCTAssertTrue(plan.routed.isEmpty)
            XCTAssertNil(plan.decisions[0].destinationID)
            XCTAssertEqual(plan.decisions[0].reasons, [.destinationUnknown, .contentReferenceIgnored])
        }
        let evaluator = DicomRoutingEvaluator(rules: [Self.rule()], destinations: catalog)
        let plan = evaluator.evaluate(subject, now: Self.now)
        XCTAssertEqual(plan.routed.map(\.destinationID), ["pacs"])
        XCTAssertEqual(plan.decisions[0].reasons, [.matched, .contentReferenceIgnored])
    }

    func test_refusalMatrix_returnsSpecificReasons() {
        let cases: [(DicomRoutingRule, DicomRoutingDestination, DicomRoutingSubject,
                     DicomRoutingDecision.Reason)] = [
            (Self.rule(destination: "unknown"), Self.destination(), Self.subject(), .destinationUnknown),
            (Self.rule(), Self.destination(enabled: false), Self.subject(), .destinationDisabled),
            (Self.rule(), Self.destination(), Self.subject(phi: false), .phiNotAuthorized),
            (Self.rule(representation: .lossyDerivedAllowed(authorization: "approved")),
             Self.destination(lossy: false), Self.subject(), .lossyNotAcceptedByDestination),
            (Self.rule(representation: .lossyDerivedAllowed(authorization: " ")),
             Self.destination(), Self.subject(), .representationIneligible),
            (Self.rule(), Self.destination(syntaxes: ["other"]), Self.subject(), .transferSyntaxNotAccepted),
            (Self.rule(), Self.destination(syntaxes: []), Self.subject(), .transferSyntaxNotAccepted)
        ]
        for (rule, destination, subject, reason) in cases {
            let plan = DicomRoutingEvaluator(rules: [rule],
                destinations: DicomRoutingDestinationCatalog(destinations: [destination]))
                .evaluate(subject, now: Self.now)
            XCTAssertTrue(plan.routed.isEmpty)
            XCTAssertEqual(plan.decisions[0].outcome, .refused)
            XCTAssertEqual(plan.decisions[0].reasons, [reason])
        }
    }

    func test_disabledRule_skipsBeforeCriteria() {
        let plan = DicomRoutingEvaluator(rules: [Self.rule(enabled: false)],
            destinations: DicomRoutingDestinationCatalog(destinations: []))
            .evaluate(Self.subject(phi: false), now: Self.now)
        XCTAssertEqual(plan.decisions[0].outcome, .skipped)
        XCTAssertEqual(plan.decisions[0].reasons, [.ruleDisabled])
        XCTAssertTrue(plan.decisions[0].criteriaEvaluated.isEmpty)
    }

    func test_declaredEligibility_defersRepresentationSelection() {
        for policy: DicomRepresentationPolicy in [.losslessEquivalents, .lossyDerivedAllowed(authorization: "ok")] {
            let plan = DicomRoutingEvaluator(rules: [Self.rule(representation: policy, requiresPHI: false)],
                destinations: DicomRoutingDestinationCatalog(destinations: [Self.destination(syntaxes: ["other"])]))
                .evaluate(Self.subject(phi: false), now: Self.now)
            XCTAssertEqual(plan.routed.count, 1)
        }
    }

    func test_duplicateRoute_andShuffledRules_areDeterministicAcrossTenRuns() {
        let rules = [Self.rule("b"), Self.rule("a"), Self.rule("c", destination: "unknown")]
        let catalog = DicomRoutingDestinationCatalog(destinations: [Self.destination()])
        let expected = DicomRoutingEvaluator(rules: rules, destinations: catalog)
            .evaluate(Self.subject(), now: Self.now)
        XCTAssertEqual(expected.decisions.map(\.ruleID), ["a", "b", "c"])
        XCTAssertEqual(expected.routed.map(\.ruleID), ["a"])
        XCTAssertEqual(expected.decisions[1].outcome, .skipped)
        XCTAssertEqual(expected.decisions[1].reasons, [.duplicateRoute])
        for _ in 0..<10 {
            let actual = DicomRoutingEvaluator(rules: rules.shuffled(), destinations: catalog)
                .evaluate(Self.subject(), now: Self.now)
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(actual.routed, expected.routed)
        }
    }

    func test_refusedRule_doesNotReserveDestination() {
        let evaluator = DicomRoutingEvaluator(rules: [Self.rule("a"), Self.rule("b", requiresPHI: false)],
            destinations: DicomRoutingDestinationCatalog(destinations: [Self.destination()]))
        XCTAssertEqual(evaluator.evaluate(Self.subject(phi: false), now: Self.now).routed.map(\.ruleID), ["b"])
    }

    func test_duplicateDestination_prefersStatRegardlessOfRuleIDAndInputOrder() throws {
        let other = DicomRoutingDestination(id: "other", kind: .stowRS, displayName: "Other", acceptsLossy: false)
        let catalog = DicomRoutingDestinationCatalog(destinations: [Self.destination(), other])
        for (routineID, statID) in [("a", "b"), ("b", "a")] {
            let rules = [Self.rule(routineID), Self.rule(statID, priority: .stat),
                Self.rule("z", destination: other.id)]
            for input in [rules, Array(rules.reversed())] {
                let plan = DicomRoutingEvaluator(rules: input, destinations: catalog)
                    .evaluate(Self.subject(), now: Self.now)
                XCTAssertEqual(plan.routed.count, 2)
                let route = try XCTUnwrap(plan.routed.first { $0.destinationID == "pacs" })
                XCTAssertEqual(route.ruleID, statID)
                XCTAssertEqual(route.priority, .stat)
                XCTAssertEqual(plan.routed.first { $0.destinationID == other.id }?.priority, .routine)
                let duplicate = try XCTUnwrap(plan.decisions.first { $0.ruleID == routineID })
                XCTAssertEqual(duplicate.outcome, .skipped)
                XCTAssertEqual(duplicate.reasons, [.duplicateRoute])
            }
        }
    }

    func test_ineligibleStatRule_doesNotSuppressRoutineRoute() {
        let catalog = DicomRoutingDestinationCatalog(destinations: [Self.destination()])
        let statRules = [Self.rule("a", enabled: false, priority: .stat),
            Self.rule("a", criteria: [.modality(in: ["MR"])], priority: .stat),
            Self.rule("a", priority: .stat)]
        for stat in statRules {
            let plan = DicomRoutingEvaluator(rules: [stat, Self.rule("b", requiresPHI: false)],
                destinations: catalog).evaluate(Self.subject(phi: false), now: Self.now)
            XCTAssertEqual(plan.routed.map(\.ruleID), ["b"])
            XCTAssertEqual(plan.routed.first?.priority, .routine)
        }
    }

    func test_dryRunAndLive_differOnlyInFlag() throws {
        let evaluator = DicomRoutingEvaluator(rules: [Self.rule("a"), Self.rule("b"),
            Self.rule("c", destination: "unknown"), Self.rule("d", enabled: false)],
            destinations: DicomRoutingDestinationCatalog(destinations: [Self.destination()]))
        let subject = Self.subject(references: ["UNTRUSTED"])
        let dry = evaluator.evaluate(subject, now: Self.now)
        let live = evaluator.evaluate(subject, dryRun: false, now: Self.now)
        XCTAssertEqual(dry.subject, live.subject)
        XCTAssertEqual(dry.reasons, live.reasons)
        XCTAssertEqual(dry.decisions.count, live.decisions.count)
        for (a, b) in zip(dry.decisions, live.decisions) {
            XCTAssertTrue(a.dryRun)
            XCTAssertFalse(b.dryRun)
            XCTAssertEqual(a, .init(ruleID: b.ruleID, destinationID: b.destinationID, outcome: b.outcome,
                reasons: b.reasons, criteriaEvaluated: b.criteriaEvaluated, dryRun: true, evaluatedAt: b.evaluatedAt,
                priority: b.priority))
        }
    }

    func test_legacyDecisionWithoutPriority_remainsDecodable() throws {
        let legacy = Data("""
            {"ruleID":"legacy","destinationID":"pacs","outcome":"route","reasons":["matched"],
             "criteriaEvaluated":[],"dryRun":false,"evaluatedAt":0}
            """.utf8)
        let decision = try JSONDecoder().decode(DicomRoutingDecision.self, from: legacy)
        XCTAssertEqual(decision.ruleID, "legacy")
        XCTAssertEqual(decision.outcome, .route)
        XCTAssertEqual(decision.evaluatedAt, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertNil(decision.priority)
    }
}
