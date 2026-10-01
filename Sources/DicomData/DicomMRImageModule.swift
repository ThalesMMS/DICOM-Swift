import Foundation

/// PS3.3 C.8.3.1 MR Image Module requirements and enumerated values.
/// This component does not qualify the complete MR IOD or the optional included macros.
public enum DicomMRImageModule {
    public static let standardEdition = "2026c"
    public static let standardSection = "C.8.3.1"

    /// External gating evidence is used only when Scan Options does not establish the condition.
    /// Missing/empty options and unrecognized Defined Terms do not imply absence of gating.
    public static func rules(for dataSet: DicomDataSet,
                             heartGating: DicomAttributeRule.Truth = .undetermined) -> [DicomAttributeRule] {
        rules(gating: gating(in: dataSet, fallback: heartGating,
            maximumValues: DicomAttributeValidator.Limits().maximumRuleEvaluations))
    }

    private static func rules(gating: DicomAttributeRule.Truth) -> [DicomAttributeRule] {
        [
            .init(tag: 0x00080008, requirement: .type1),
            .init(tag: 0x00280002, requirement: .type1, constraints: [.integerRange(1...1)]),
            .init(tag: 0x00280004, requirement: .type1, constraints: [.strings(["MONOCHROME1", "MONOCHROME2"])]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.integerRange(16...16)]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.integerRange(1...16)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00180020, requirement: .type1,
                  constraints: [.strings(["SE", "IR", "GR", "EP", "RM"]), .forbiddenStringCombination(["SE", "GR"])]),
            // Defined Terms are extensible; an unknown variant is not an invalid enumerated value.
            .init(tag: 0x00180021, requirement: .type1),
            .init(tag: 0x00180022, requirement: .type2),
            .init(tag: 0x00180023, requirement: .type2, constraints: [.strings(["2D", "3D"])]),
            .init(tag: 0x00180080, requirement: .type2C,
                  condition: .any([.stringEquals(0x00180021, "SK"), .not(.stringEquals(0x00180020, "EP"))]),
                  mayBePresentOtherwise: true),
            .init(tag: 0x00180081, requirement: .type2),
            .init(tag: 0x00180091, requirement: .type2),
            .init(tag: 0x00180082, requirement: .type2C, condition: .stringEquals(0x00180020, "IR")),
            .init(tag: 0x00181060, requirement: .type2C, condition: .known(gating)),
            .init(tag: 0x00180025, requirement: .type3, constraints: [.strings(["Y", "N"])]),
            .init(tag: 0x00181080, requirement: .type3, constraints: [.strings(["Y", "N"])]),
            .init(tag: 0x00181312, requirement: .type3, constraints: [.strings(["ROW", "COL"])]),
            .init(tag: 0x00181315, requirement: .type3, constraints: [.strings(["Y", "N"])])
        ] + DicomCommonMacros.viewCode() + DicomCommonMacros.treatmentImagingRelations()
    }

    public static func validate(_ dataSet: DicomDataSet, heartGating: DicomAttributeRule.Truth = .undetermined,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let conditionWork: Int
        if case .strings(let values) = dataSet[0x00180022]?.value { conditionWork = values.count } else { conditionWork = 0 }
        guard conditionWork <= limits.maximumRuleEvaluations else {
            return .init(diagnostics: [.init(code: .evaluationLimitReached, severity: .limitation,
                                            layer: .attributes, path: [.tag(0x00180022)])])
        }
        let condition = gating(in: dataSet, fallback: heartGating, maximumValues: limits.maximumRuleEvaluations)
        let remaining = DicomAttributeValidator.Limits(maximumDepth: limits.maximumDepth,
            maximumRuleEvaluations: limits.maximumRuleEvaluations - conditionWork, maximumDiagnostics: limits.maximumDiagnostics)
        return DicomAttributeValidator.validate(dataSet, rules: rules(gating: condition), limits: remaining)
    }

    private static func gating(in dataSet: DicomDataSet, fallback: DicomAttributeRule.Truth, maximumValues: Int) -> DicomAttributeRule.Truth {
        guard let element = dataSet[0x00180022], element.vr == .CS,
              case .strings(let values) = element.value, !values.isEmpty else { return fallback }
        guard values.count <= maximumValues else { return .undetermined }
        let terms = Set(values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) })
        if !terms.isDisjoint(with: ["CG", "PPG"]) { return .satisfied }
        let nonCardiacTerms: Set<String> = ["PER", "RG", "FC", "PFF", "PFP", "SP", "FS"]
        return terms.isSubset(of: nonCardiacTerms) ? .unsatisfied : fallback
    }
}
