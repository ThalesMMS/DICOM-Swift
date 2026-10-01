import Foundation

/// One PS3.16 table row. INCLUDE bindings are local to that invocation.
public struct DicomSRTemplateRow: Equatable, Sendable {
    public enum ValueType: Equatable, Sendable {
        case value(String), include(String)
    }
    public enum Concept: Equatable, Sendable {
        case enumerated(DicomCodedConcept), definedTerm(DicomCodedConcept)
        case contextGroup(String), parameter(String), any
    }
    public enum VM: Equatable, Sendable { case one, oneOrMore }
    public indirect enum Condition: Equatable, Sendable {
        case xor([String]), iff(String), ifRowAbsent(String), ifRowValue(String, DicomCodedConcept)
        case ifRowsAnyPresent([String]), custom(String)
        case all([Condition]), any([Condition]), not(Condition), ifRowConcept(String, DicomCodedConcept)
    }
    public enum Requirement: Equatable, Sendable {
        case mandatory, mandatoryConditional(Condition), userOptional, userConditional(Condition)
    }
    public enum ValueSet: Equatable, Sendable {
        case none, units(DicomCodedConcept), unitsParameter(String), definedTerms([DicomCodedConcept])
        case contextGroup(String), parameter(String)
    }
    public let id: String
    public let nestingLevel: Int
    public let relationship: String?
    public let valueType: ValueType
    public let concept: Concept
    public let vm: VM
    public let requirement: Requirement
    public let valueSet: ValueSet
    public let bindings: [String: ValueSet]

    public init(id: String, nestingLevel: Int = 0, relationship: String? = nil, valueType: ValueType,
                concept: Concept = .any, vm: VM = .one, requirement: Requirement = .userOptional,
                valueSet: ValueSet = .none, bindings: [String: ValueSet] = [:]) {
        self.id = id
        self.nestingLevel = nestingLevel
        self.relationship = relationship
        self.valueType = valueType
        self.concept = concept
        self.vm = vm
        self.requirement = requirement
        self.valueSet = valueSet
        self.bindings = bindings
    }
}
