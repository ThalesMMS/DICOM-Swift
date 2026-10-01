import Foundation

public struct DicomRoutingDecision: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable { case route, skipped, refused }
    public enum Reason: String, Codable, Equatable, Sendable {
        case ruleDisabled, criterionNotMet, destinationUnknown, destinationDisabled
        case phiNotAuthorized, representationIneligible, lossyNotAcceptedByDestination
        case transferSyntaxNotAccepted, duplicateRoute, contentReferenceIgnored, matched
    }
    public struct CriterionResult: Codable, Equatable, Sendable {
        public let description: String
        public let matched: Bool

        public init(description: String, matched: Bool) {
            self.description = description
            self.matched = matched
        }
    }

    public let ruleID: String
    public let destinationID: String?
    public let outcome: Outcome
    public let reasons: [Reason]
    public let criteriaEvaluated: [CriterionResult]
    public let dryRun: Bool
    public let evaluatedAt: Date
    /// Nil preserves compatibility with decisions persisted before rule priority was recorded.
    public let priority: DicomRoutingPriority?

    public init(ruleID: String, destinationID: String?, outcome: Outcome, reasons: [Reason],
                criteriaEvaluated: [CriterionResult], dryRun: Bool, evaluatedAt: Date,
                priority: DicomRoutingPriority? = nil) {
        self.ruleID = ruleID
        self.destinationID = destinationID
        self.outcome = outcome
        self.reasons = reasons
        self.criteriaEvaluated = criteriaEvaluated
        self.dryRun = dryRun
        self.evaluatedAt = evaluatedAt
        self.priority = priority
    }
}

public struct DicomRoutingPlan: Equatable, Sendable {
    public let subject: DicomRoutingSubject
    public let decisions: [DicomRoutingDecision]
    public var routed: [DicomRoutingDecision] { decisions.filter { $0.outcome == .route } }
    /// Also exposes the ignored-reference evidence when there are no rules.
    public var reasons: [DicomRoutingDecision.Reason] {
        subject.contentReferences.isEmpty ? [] : [.contentReferenceIgnored]
    }

    public init(subject: DicomRoutingSubject, decisions: [DicomRoutingDecision]) {
        self.subject = subject
        self.decisions = decisions
    }
}
