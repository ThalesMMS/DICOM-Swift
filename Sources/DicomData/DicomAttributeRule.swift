import Foundation

/// One attribute requirement, optionally containing rules for each sequence item.
/// Rules describe a tested subset; evaluating them is not a full IOD conformance claim.
public struct DicomAttributeRule: Sendable {
    public enum Requirement: String, Sendable, Codable {
        case type1 = "1", type1C = "1C", type2 = "2", type2C = "2C", type3 = "3"
    }

    public enum Truth: Sendable {
        case satisfied, unsatisfied, undetermined
    }

    public enum CodeEncoding: Sendable {
        case shortCode, longCode, urn
    }

    public enum Constraint: Sendable {
        /// Enumerated values, not extensible Defined Terms. Every populated component must match.
        case strings(Set<String>)
        case forbiddenStringCombination(Set<String>)
        case integerRange(ClosedRange<Int>)
        case integers(Set<Int>)
        case integerEqualsAttribute(Int, offset: Int)
        case integerLessThanOrEqualAttribute(Int)
        case itemCount(ClosedRange<Int>)
        /// IOD-specific value cardinality, which may be narrower than the data dictionary VM.
        case valueCount(ClosedRange<Int>)
        /// Values form complete pairs, such as waveform multiplex-group/channel selectors.
        case evenValueCount
        /// Dataset-wide choice; diagnostics identify the containing item rather than the anchor attribute.
        case exactlyOnePresent(Set<Int>)
        case forbiddenWhen(Condition)
        /// A cross-attribute relationship that must hold; unknown evidence remains a limitation.
        case requiredCondition(Condition)
        case codeValueEncoding(CodeEncoding)
        /// SR C.17-5 text permits CR LF line separators but no other formatting controls.
        case unformattedText
        /// C.18.8 DCMR template identifiers are digits without leading zeroes or a TID prefix.
        case dicomTemplateIdentifier
        /// C.18.7 representation value/cardinality checks, charged per component to the work budget.
        case temporalCoordinateValues
        /// Person identification sequence cardinality versus the accompanying PN values; identity/order remain unqualified.
        case personIdentificationNames(Int, whenMultipleItems: Bool)
        /// C.18.6/C.18.9 dimension/cardinality and value domains, charged per component.
        case spatialCoordinateValues(DicomSpatialCoordinatesMacro.Kind)
    }

    /// A condition evaluates the containing item. Missing or unusable comparison values
    /// are undetermined; `present` explicitly tests existence instead. Evaluation is
    /// bounded to 64 nesting levels and 4,096 condition nodes; exhaustion is undetermined.
    public indirect enum Condition: Sendable {
        case present(Int)
        case stringEquals(Int, String)
        case integerGreaterThan(Int, Int)
        case all([Condition]), any([Condition]), not(Condition)
        /// Explicit external evidence or a SOP-specific predicate evaluated by the module.
        case known(Truth)
        case undetermined

        public func evaluate(in dataSet: DicomDataSet) -> Truth {
            var remaining = 4096
            return evaluate(in: dataSet, depth: 0, remaining: &remaining)
        }

        private func evaluate(in dataSet: DicomDataSet, depth: Int, remaining: inout Int) -> Truth {
            guard depth < 64, remaining > 0 else { return .undetermined }
            remaining -= 1
            switch self {
            case .present(let tag):
                return dataSet.contains(tag) ? .satisfied : .unsatisfied
            case .stringEquals(let tag, let expected):
                guard !expected.isEmpty, let element = dataSet[tag], element.vr != .UN,
                      case .strings(let values) = element.value,
                      !values.isEmpty else {
                    return .undetermined
                }
                let trimmed = values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
                if trimmed.contains(expected) { return .satisfied }
                return trimmed.contains("") ? .undetermined : .unsatisfied
            case .integerGreaterThan(let tag, let threshold):
                guard let element = dataSet[tag], [.US, .SS, .UL, .SL, .UV, .SV, .IS].contains(element.vr),
                      element.vm.count == 1, let value = element.intValue else {
                    return .undetermined
                }
                return value > threshold ? .satisfied : .unsatisfied
            case .all(let conditions):
                guard !conditions.isEmpty else { return .undetermined }
                var unknown = false
                for condition in conditions {
                    guard remaining > 0 else { return .undetermined }
                    let result = condition.evaluate(in: dataSet, depth: depth + 1, remaining: &remaining)
                    if result == .unsatisfied { return .unsatisfied }
                    unknown = unknown || result == .undetermined
                }
                return unknown ? .undetermined : .satisfied
            case .any(let conditions):
                guard !conditions.isEmpty else { return .undetermined }
                var unknown = false
                for condition in conditions {
                    guard remaining > 0 else { return .undetermined }
                    let result = condition.evaluate(in: dataSet, depth: depth + 1, remaining: &remaining)
                    if result == .satisfied { return .satisfied }
                    unknown = unknown || result == .undetermined
                }
                return unknown ? .undetermined : .unsatisfied
            case .not(let condition):
                switch condition.evaluate(in: dataSet, depth: depth + 1, remaining: &remaining) {
                case .satisfied: return .unsatisfied
                case .unsatisfied: return .satisfied
                case .undetermined: return .undetermined
                }
            case .undetermined:
                return .undetermined
            case .known(let truth):
                return truth
            }
        }
    }

    public let tag: Int
    public let requirement: Requirement
    public let condition: Condition?
    public let mayBePresentOtherwise: Bool
    public let itemRules: [Self]
    public let constraints: [Constraint]

    public init(tag: Int, requirement: Requirement, condition: Condition? = nil,
                mayBePresentOtherwise: Bool = false, itemRules: [Self] = []) {
        self.init(tag: tag, requirement: requirement, condition: condition,
                  mayBePresentOtherwise: mayBePresentOtherwise, itemRules: itemRules, constraints: [])
    }

    public init(tag: Int, requirement: Requirement, condition: Condition? = nil,
                mayBePresentOtherwise: Bool = false, itemRules: [Self] = [], constraints: [Constraint]) {
        self.tag = tag
        self.requirement = requirement
        self.condition = condition
        self.mayBePresentOtherwise = mayBePresentOtherwise
        self.itemRules = itemRules
        self.constraints = constraints
    }
}
