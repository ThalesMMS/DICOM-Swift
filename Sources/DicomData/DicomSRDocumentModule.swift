import Foundation

/// Attribute components of PS3.3 C.17.2 and C.17.6.2, not complete SR/KOS IODs.
/// Content semantics, external reference consistency, terminology and signatures are separate layers.
public enum DicomSRDocumentModule {
    public static let standardEdition = "2026c"

    public enum Kind: Sendable {
        case structuredReport, keyObjectSelection
    }

    /// Facts established by the caller from provenance and the content/reference graph.
    /// Absence of an attribute is not evidence that its external requirement is false.
    public struct Conditions: Sendable {
        public var includesOtherDocumentContent: DicomAttributeRule.Truth = .undetermined
        public var identicalDocumentsRequired: DicomAttributeRule.Truth = .undetermined
        public var requestedProcedureApplies: DicomAttributeRule.Truth = .undetermined
        public var currentProcedureEvidenceRequired: DicomAttributeRule.Truth = .undetermined
        public var pertinentOtherEvidenceRequired: DicomAttributeRule.Truth = .undetermined
        public var equivalentCDAKnown: DicomAttributeRule.Truth = .undetermined

        public init() {}
    }

    public static func rules(kind: Kind, conditions: Conditions = .init(),
                             versionRequirements: [String: DicomAttributeRule.Truth] = [:]) -> [DicomAttributeRule] {
        let code = DicomCodeSequenceMacro.rules(versionRequirements: versionRequirements)
        let hierarchy = DicomSRReferenceMacro.hierarchicalRules(codeRules: code)
        let common: [DicomAttributeRule] = [
            .init(tag: 0x00200013, requirement: .type1),
            .init(tag: 0x00080023, requirement: .type1),
            .init(tag: 0x00080033, requirement: .type1),
            .init(tag: 0x0040A370, requirement: .type1C, condition: .known(conditions.requestedProcedureApplies),
                  mayBePresentOtherwise: kind == .structuredReport,
                  itemRules: DicomSRReferenceMacro.requestRules(codeRules: code), constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0040A525, requirement: .type1C, condition: .known(conditions.identicalDocumentsRequired),
                  itemRules: hierarchy, constraints: [.itemCount(1...Int.max)])
        ]
        if kind == .keyObjectSelection {
            return common + [.init(tag: 0x0040A375, requirement: .type1,
                                   itemRules: hierarchy, constraints: [.itemCount(1...Int.max)])]
        }
        let verified = DicomAttributeRule.Condition.stringEquals(0x0040A493, "VERIFIED")
        return common + [
            .init(tag: 0x0040A491, requirement: .type1, constraints: [.strings(["PARTIAL", "COMPLETE"])]),
            .init(tag: 0x0040A493, requirement: .type1, constraints: [.strings(["UNVERIFIED", "VERIFIED"]),
                .requiredCondition(.any([.not(verified), .stringEquals(0x0040A491, "COMPLETE")]))]),
            .init(tag: 0x0040A496, requirement: .type3, constraints: [.strings(["PRELIMINARY", "FINAL"])]),
            .init(tag: 0x0040A073, requirement: .type1C, condition: verified,
                  itemRules: [
                    .init(tag: 0x0040A075, requirement: .type1),
                    .init(tag: 0x0040A027, requirement: .type1),
                    .init(tag: 0x0040A030, requirement: .type1),
                    .init(tag: 0x0040A088, requirement: .type2, itemRules: code, constraints: [.itemCount(0...1)])
                  ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0040A078, requirement: .type3,
                  itemRules: DicomSRObserverMacro.rules(codeRules: code), constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0040A07A, requirement: .type3,
                  itemRules: [.init(tag: 0x0040A080, requirement: .type1), .init(tag: 0x0040A082, requirement: .type2)]
                    + DicomSRObserverMacro.rules(codeRules: code), constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0040A07C, requirement: .type3, itemRules: [
                .init(tag: 0x00080080, requirement: .type2),
                .init(tag: 0x00080082, requirement: .type2, itemRules: code, constraints: [.itemCount(0...1)]),
                .init(tag: 0x00080220, requirement: .type3, itemRules: code, constraints: [.itemCount(1...1)])
            ], constraints: [.itemCount(1...1)]),
            .init(tag: 0x0040A360, requirement: .type1C, condition: .known(conditions.includesOtherDocumentContent),
                  itemRules: hierarchy, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0040A372, requirement: .type2, itemRules: code),
            .init(tag: 0x0040A375, requirement: .type1C, condition: .known(conditions.currentProcedureEvidenceRequired),
                  mayBePresentOtherwise: true, itemRules: hierarchy, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0040A385, requirement: .type1C, condition: .known(conditions.pertinentOtherEvidenceRequired),
                  itemRules: hierarchy, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0008114A, requirement: .type1C, condition: .known(conditions.equivalentCDAKnown),
                  mayBePresentOtherwise: true, itemRules: DicomSRReferenceMacro.sopRules + [
                    .init(tag: 0x0040A170, requirement: .type1, itemRules: code, constraints: [.itemCount(1...1)])
                  ], constraints: [.itemCount(1...Int.max)])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, kind: Kind, conditions: Conditions = .init(),
                                versionRequirements: [String: DicomAttributeRule.Truth] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet,
            rules: rules(kind: kind, conditions: conditions, versionRequirements: versionRequirements), limits: limits)
    }
}
