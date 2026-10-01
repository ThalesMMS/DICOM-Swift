import Foundation

public enum DicomRoutingRuleError: Error, Equatable, Sendable {
    case emptyID, emptyDestination, emptyCriteria, invalidCriterionValue, destinationLooksLikeContentReference
}

public enum DicomRoutingRuleValidator {
    public static func validate(_ rule: DicomRoutingRule) throws {
        guard !rule.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DicomRoutingRuleError.emptyID
        }
        guard !rule.destinationID.isEmpty else { throw DicomRoutingRuleError.emptyDestination }
        guard !rule.destinationID.contains("://"), !rule.destinationID.contains(where: { $0.isWhitespace }) else {
            throw DicomRoutingRuleError.destinationLooksLikeContentReference
        }
        guard !rule.criteria.isEmpty else { throw DicomRoutingRuleError.emptyCriteria }
        guard rule.criteria.allSatisfy(\.hasValidValue) else { throw DicomRoutingRuleError.invalidCriterionValue }
    }
}
