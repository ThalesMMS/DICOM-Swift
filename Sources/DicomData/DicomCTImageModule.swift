import Foundation

/// PS3.3 C.8.2.1 CT Image Module. Included terminology/anatomy/algorithm constraints and the
/// cross-item multi-energy acquisition constraints are explicitly unqualified below.
/// This component is not a complete CT IOD validator.
public enum DicomCTImageModule {
    public static let standardEdition = "2026c"
    public static let standardSection = "C.8.2.1"

    public static func rules(for dataSet: DicomDataSet,
                             rescaleUnitsAreHU: DicomAttributeRule.Truth = .undetermined) -> [DicomAttributeRule] {
        rules(for: dataSet, rescaleUnitsAreHU: rescaleUnitsAreHU,
              weighting: proportionalWeighting(in: dataSet, maximumItems: DicomAttributeValidator.Limits().maximumRuleEvaluations))
    }

    private static func rules(for dataSet: DicomDataSet, rescaleUnitsAreHU: DicomAttributeRule.Truth,
                              weighting: DicomAttributeRule.Truth) -> [DicomAttributeRule] {
        let codeRules = DicomCodeSequenceMacro.standardRules()
        let sourceRules: [DicomAttributeRule] = [0x00180060, 0x00189330, 0x00180090, 0x00181190, 0x00181160, 0x00187050]
            .map { .init(tag: $0, requirement: .type1) }
            + [.init(tag: 0x00189353, requirement: .type1C, condition: .known(weighting), mayBePresentOtherwise: true)]
        return [
            .init(tag: 0x00080008, requirement: .type1),
            .init(tag: 0x00189361, requirement: .type3, constraints: [.strings(["YES", "NO"])]),
            .init(tag: 0x00280002, requirement: .type1, constraints: [.integerRange(1...1)]),
            .init(tag: 0x00280004, requirement: .type1, constraints: [.strings(["MONOCHROME1", "MONOCHROME2"])]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.integerRange(16...16)]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.integerRange(12...16)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00281052, requirement: .type1),
            .init(tag: 0x00281053, requirement: .type1),
            .init(tag: 0x00281054, requirement: .type1C,
                  condition: .known(rescaleTypeRequired(in: dataSet, fallback: rescaleUnitsAreHU)),
                  mayBePresentOtherwise: true,
                  constraints: originalImageRequiresHU(dataSet) ? [.strings(["HU"])] : []),
            .init(tag: 0x00180060, requirement: .type2),
            .init(tag: 0x00200012, requirement: .type2),
            .init(tag: 0x00181140, requirement: .type3, constraints: [.strings(["CW", "CC"])]),
            .init(tag: 0x00189391, requirement: .type3, constraints: [.strings(["YES", "NO"])]),
            .init(tag: 0x00181272, requirement: .type1C, condition: .present(0x00181271),
                  itemRules: codeRules, constraints: [.itemCount(1...1)]),
            .init(tag: 0x00189346, requirement: .type3, itemRules: codeRules, constraints: [.itemCount(1...1)]),
            .init(tag: 0x00189353, requirement: .type1C, condition: .known(weighting), mayBePresentOtherwise: true),
            .init(tag: 0x00189360, requirement: .type3, itemRules: sourceRules, constraints: [.itemCount(1...Int.max),
                      .forbiddenWhen(.all([.present(0x00189361), .stringEquals(0x00189361, "YES")]))]),
            .init(tag: 0x00189392, requirement: .type3, itemRules: DicomCommonMacros.algorithmIdentification(),
                  constraints: [.itemCount(1...Int.max)])
        ] + DicomCommonMacros.viewCode() + DicomCommonMacros.treatmentImagingRelations()
    }

    public static func validate(_ dataSet: DicomDataSet, rescaleUnitsAreHU: DicomAttributeRule.Truth = .undetermined,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        // Reserve the whole sequence before inspecting it, even if a matching code occurs early.
        let conditionWork: Int
        if case .sequence(let items) = dataSet[0x00089215]?.value { conditionWork = items.count } else { conditionWork = 0 }
        guard conditionWork <= limits.maximumRuleEvaluations, conditionWork == 0 || limits.maximumDepth > 0 else {
            return .init(diagnostics: [.init(code: .evaluationLimitReached, severity: .limitation,
                                            layer: .attributes, path: [.tag(0x00089215)])])
        }
        let weighting = proportionalWeighting(in: dataSet, maximumItems: limits.maximumRuleEvaluations)
        let remaining = DicomAttributeValidator.Limits(maximumDepth: limits.maximumDepth,
            maximumRuleEvaluations: limits.maximumRuleEvaluations - conditionWork, maximumDiagnostics: limits.maximumDiagnostics)
        let attributes = DicomAttributeValidator.evaluate(dataSet,
            rules: rules(for: dataSet, rescaleUnitsAreHU: rescaleUnitsAreHU, weighting: weighting), limits: remaining)
        // Anatomy is composed by General Image; multi-energy content by DicomMultiEnergyCTModule.
        return attributes.report
    }

    private static func rescaleTypeRequired(in dataSet: DicomDataSet,
                                            fallback: DicomAttributeRule.Truth) -> DicomAttributeRule.Truth {
        if text(dataSet, tag: 0x00189361, vr: .CS) == "YES" { return .satisfied }
        if let units = text(dataSet, tag: 0x00281054, vr: .LO) { return units == "HU" ? .unsatisfied : .satisfied }
        if originalImageRequiresHU(dataSet) { return .unsatisfied }
        switch fallback {
        case .satisfied: return .unsatisfied
        case .unsatisfied: return .satisfied
        case .undetermined: return .undetermined
        }
    }

    private static func originalImageRequiresHU(_ dataSet: DicomDataSet) -> Bool {
        guard let element = dataSet[0x00080008], element.vr == .CS,
              case .strings(let values) = element.value, values.count >= 3 else { return false }
        let origin = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let imageType = values[2].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let singleEnergy = !dataSet.contains(0x00189361) || text(dataSet, tag: 0x00189361, vr: .CS) == "NO"
        return origin == "ORIGINAL" && !imageType.isEmpty && imageType != "LOCALIZER" && singleEnergy
    }

    private static func proportionalWeighting(in dataSet: DicomDataSet, maximumItems: Int) -> DicomAttributeRule.Truth {
        guard let sequence = dataSet[0x00089215] else { return .unsatisfied }
        guard sequence.vr == .SQ, case .sequence(let items) = sequence.value, items.count <= maximumItems else { return .undetermined }
        var unknown = false
        for item in items {
            guard let scheme = text(item.dataSet, tag: 0x00080102, vr: .SH),
                  let code = text(item.dataSet, tag: 0x00080100, vr: .SH) else {
                unknown = true
                continue
            }
            if scheme == "DCM" && code == "113097" { return .satisfied }
        }
        return unknown ? .undetermined : .unsatisfied
    }

    private static func text(_ dataSet: DicomDataSet, tag: Int, vr: DicomVR) -> String? {
        guard let element = dataSet[tag], element.vr == vr, case .strings(let values) = element.value,
              values.count == 1 else { return nil }
        let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return value.isEmpty ? nil : value
    }
}
