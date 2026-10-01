import Foundation

public struct DicomRoutingEvaluator: Sendable {
    private let rules: [DicomRoutingRule]
    private let destinations: any DicomRoutingDestinationResolving

    public init(rules: [DicomRoutingRule], destinations: any DicomRoutingDestinationResolving) {
        // Highest priority wins duplicate destinations. Rule ID breaks ties, then input order for equal IDs.
        self.rules = rules.enumerated().sorted {
            if $0.element.priority != $1.element.priority { return $0.element.priority == .stat }
            return $0.element.id == $1.element.id ? $0.offset < $1.offset : $0.element.id < $1.element.id
        }.map(\.element)
        self.destinations = destinations
    }

    public func evaluate(_ subject: DicomRoutingSubject, dryRun: Bool = true,
                         now: Date = Date()) -> DicomRoutingPlan {
        var routedDestinations: Set<String> = []
        let decisions = rules.map { rule -> DicomRoutingDecision in
            var criteria: [DicomRoutingDecision.CriterionResult] = []
            func decision(_ outcome: DicomRoutingDecision.Outcome, _ reason: DicomRoutingDecision.Reason,
                          destinationID: String? = nil) -> DicomRoutingDecision {
                .init(ruleID: rule.id, destinationID: destinationID, outcome: outcome,
                      reasons: [reason] + (subject.contentReferences.isEmpty ? [] : [.contentReferenceIgnored]),
                      criteriaEvaluated: criteria, dryRun: dryRun, evaluatedAt: now, priority: rule.priority)
            }
            guard rule.enabled else { return decision(.skipped, .ruleDisabled) }
            criteria = rule.criteria.map { .init(description: $0.description, matched: $0.matches(subject)) }
            guard !criteria.isEmpty, rule.criteria.allSatisfy(\.hasValidValue),
                  criteria.allSatisfy(\.matched) else { return decision(.skipped, .criterionNotMet) }
            // Even an unvalidated rule cannot resolve a content URL or whitespace-bearing reference.
            guard (try? DicomRoutingRuleValidator.validate(rule)) != nil,
                  let destination = destinations.destination(id: rule.destinationID),
                  destination.id == rule.destinationID else { return decision(.refused, .destinationUnknown) }
            guard destination.enabled else {
                return decision(.refused, .destinationDisabled, destinationID: destination.id)
            }
            guard !rule.requiresPHIAuthorization || subject.phiAuthorized else {
                return decision(.refused, .phiNotAuthorized, destinationID: destination.id)
            }
            if case .lossyDerivedAllowed = rule.representation {
                guard rule.representation.allowsLossy else {
                    return decision(.refused, .representationIneligible, destinationID: destination.id)
                }
                guard destination.acceptsLossy else {
                    return decision(.refused, .lossyNotAcceptedByDestination, destinationID: destination.id)
                }
            }
            if rule.representation == .originalOnly, let accepted = destination.acceptedTransferSyntaxUIDs,
               !accepted.contains(subject.transferSyntaxUID) {
                return decision(.refused, .transferSyntaxNotAccepted, destinationID: destination.id)
            }
            guard routedDestinations.insert(destination.id).inserted else {
                return decision(.skipped, .duplicateRoute, destinationID: destination.id)
            }
            return decision(.route, .matched, destinationID: destination.id)
        }
        return .init(subject: subject, decisions: decisions)
    }
    public func evaluate(_ subject: DicomRoutingSubject, dryRun: Bool = true, now: Date = Date(),
                         authorizer: (any DicomAuthorizing)?, principal: DicomPrincipal? = nil,
                         audit: DicomAuditRecorder? = nil) async throws -> DicomRoutingPlan {
        let plan = evaluate(subject, dryRun: dryRun, now: now)
        let access = DicomEnforcement(principal: principal, authorizer: authorizer, audit: audit,
                                      context: .init(protocol: .local))
        var decisions: [DicomRoutingDecision] = []
        for decision in plan.decisions {
            if decision.outcome == .route,
               try await !access.check(.route, .init(kind: .study, id: subject.studyInstanceUID), filtering: true) {
                decisions.append(.init(ruleID: decision.ruleID, destinationID: decision.destinationID,
                    outcome: .refused, reasons: [.phiNotAuthorized], criteriaEvaluated: decision.criteriaEvaluated,
                    dryRun: dryRun, evaluatedAt: now))
            } else { decisions.append(decision) }
        }
        return .init(subject: subject, decisions: decisions)
    }

}
