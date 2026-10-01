import Foundation

/// PS3.3 Tables 8.8-1a/1b/1. Checks coded-entry representation and conditions,
/// not terminology membership, code meaning equivalence, or IOD-specific context groups.
public enum DicomCodeSequenceMacro {
    public static let standardEdition = "2026c"

    /// PS3.16 Section 8 coding schemes whose code values stay unique across versions, so a
    /// Coding Scheme Version is not needed to identify the code. Unlisted and private
    /// schemes remain undetermined rather than presumed version-independent.
    public static let versionIndependentSchemes: [String: DicomAttributeRule.Truth] = Dictionary(uniqueKeysWithValues:
        ["DCM", "SCT", "SRT", "LN", "UCUM", "NCIt", "RADLEX", "FMA", "MDC", "UMLS",
         "ISO639_1", "ISO639_2", "ISO3166_1", "RFC3066", "IETF4646"].map { ($0, DicomAttributeRule.Truth.unsatisfied) })

    /// Code macro rules that resolve the version requirement for the standard schemes above.
    public static func standardRules() -> [DicomAttributeRule] { rules(versionRequirements: versionIndependentSchemes) }

    /// The map states whether each designator needs a version to resolve ambiguity.
    /// Unlisted schemes remain undetermined; no private scheme is presumed version-independent.
    public static func rules(versionRequirements: [String: DicomAttributeRule.Truth] = [:]) -> [DicomAttributeRule] {
        let entry = basicRules(versionRequirements: versionRequirements) + enhancedRules
        return entry + [.init(tag: 0x00080121, requirement: .type3, itemRules: entry,
                              constraints: [.itemCount(1...Int.max)])]
    }

    public static func validate(_ dataSet: DicomDataSet,
                                versionRequirements: [String: DicomAttributeRule.Truth] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(versionRequirements: versionRequirements), limits: limits)
    }

    private static func basicRules(versionRequirements: [String: DicomAttributeRule.Truth]) -> [DicomAttributeRule] {
        let keys = versionRequirements.keys.sorted()
        let knownScheme = DicomAttributeRule.Condition.any(keys.map { .stringEquals(0x00080102, $0) } + [.known(.unsatisfied)])
        let requirements: [DicomAttributeRule.Condition] = keys.map {
            .all([.stringEquals(0x00080102, $0), .known(versionRequirements[$0] ?? .undetermined)])
        }
        let needsVersion = DicomAttributeRule.Condition.any(requirements + [.all([.not(knownScheme), .undetermined])])
        return [
            .init(tag: 0x00080100, requirement: .type1C, condition: .present(0x00080100),
                  constraints: [.codeValueEncoding(.shortCode)]),
            .init(tag: 0x00080119, requirement: .type1C, condition: .present(0x00080119),
                  constraints: [.codeValueEncoding(.longCode)]),
            .init(tag: 0x00080120, requirement: .type1C, condition: .present(0x00080120),
                  constraints: [.codeValueEncoding(.urn)]),
            .init(tag: 0x00080104, requirement: .type1,
                  constraints: [.exactlyOnePresent([0x00080100, 0x00080119, 0x00080120])]),
            .init(tag: 0x00080102, requirement: .type1C,
                  condition: .any([.present(0x00080100), .present(0x00080119)]), mayBePresentOtherwise: true),
            .init(tag: 0x00080103, requirement: .type1C,
                  condition: .all([.present(0x00080102), needsVersion]), mayBePresentOtherwise: true,
                  constraints: [.forbiddenWhen(.not(.present(0x00080102)))])
        ]
    }

    private static var enhancedRules: [DicomAttributeRule] {
        let extensionUsed = DicomAttributeRule.Condition.all([.present(0x0008010B), .stringEquals(0x0008010B, "Y")])
        return [
            .init(tag: 0x00080105, requirement: .type1C, condition: .present(0x0008010F)),
            .init(tag: 0x00080106, requirement: .type1C, condition: .present(0x0008010F)),
            .init(tag: 0x0008010B, requirement: .type3, constraints: [.strings(["Y", "N"])]),
            .init(tag: 0x00080107, requirement: .type1C, condition: extensionUsed),
            .init(tag: 0x0008010D, requirement: .type1C, condition: extensionUsed)
        ]
    }
}
