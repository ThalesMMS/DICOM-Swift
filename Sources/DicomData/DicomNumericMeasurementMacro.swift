import Foundation

/// Attribute requirements of PS3.3 C.18.1. Source precision and terminology require external evidence.
public enum DicomNumericMeasurementMacro {
    public static let standardEdition = "2026c"
    public static let standardSection = "C.18.1"

    public struct PrecisionRequirements: Sendable {
        public let floatingPoint: DicomAttributeRule.Truth
        public let rational: DicomAttributeRule.Truth

        public init(floatingPoint: DicomAttributeRule.Truth = .undetermined,
                    rational: DicomAttributeRule.Truth = .undetermined) {
            self.floatingPoint = floatingPoint
            self.rational = rational
        }
    }

    public static func rules(for dataSet: DicomDataSet,
                             floatingPointRequired: DicomAttributeRule.Truth = .undetermined,
                             rationalRepresentationRequired: DicomAttributeRule.Truth = .undetermined,
                             versionRequirements: [String: DicomAttributeRule.Truth] = [:]) -> [DicomAttributeRule] {
        let code = DicomCodeSequenceMacro.rules(versionRequirements: versionRequirements)
        let measurement: [DicomAttributeRule] = [
            .init(tag: 0x0040A30A, requirement: .type1, constraints: [.valueCount(1...1)]),
            .init(tag: 0x0040A161, requirement: .type1C, condition: .known(floatingPointRequired),
                  mayBePresentOtherwise: true, constraints: [.valueCount(1...1)]),
            .init(tag: 0x0040A162, requirement: .type1C, condition: .known(rationalRepresentationRequired),
                  mayBePresentOtherwise: true, constraints: [.valueCount(1...1)]),
            .init(tag: 0x0040A163, requirement: .type1C, condition: .present(0x0040A162),
                  constraints: [.valueCount(1...1), .integerRange(1...Int.max)]),
            .init(tag: 0x004008EA, requirement: .type1, itemRules: code, constraints: [.itemCount(1...1)])
        ]
        return [
            .init(tag: 0x0040A300, requirement: .type2, itemRules: measurement, constraints: [.itemCount(0...1)]),
            .init(tag: 0x0040A301, requirement: .type1C, condition: .known(qualifierRequired(in: dataSet)),
                  itemRules: code, constraints: [.itemCount(1...1)])
        ]
    }

    /// Adds at most two scope limitations beyond the evaluator's ordinary and terminal diagnostic budgets.
    public static func validate(_ dataSet: DicomDataSet,
                                floatingPointRequired: DicomAttributeRule.Truth = .undetermined,
                                rationalRepresentationRequired: DicomAttributeRule.Truth = .undetermined,
                                versionRequirements: [String: DicomAttributeRule.Truth] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let report = DicomAttributeValidator.validate(dataSet,
            rules: rules(for: dataSet, floatingPointRequired: floatingPointRequired,
                         rationalRepresentationRequired: rationalRepresentationRequired,
                         versionRequirements: versionRequirements), limits: limits)
        // Attribute shape cannot prove Defined Context Group membership or equivalence of alternate representations.
        let unqualified = [0x0040A300, 0x0040A301].filter(dataSet.contains).map {
            DicomValidationReport.Diagnostic(code: .moduleRuleUnavailable, severity: .limitation,
                layer: .attributes, path: [.tag($0)])
        }
        return report.merging(.init(diagnostics: unqualified))
    }

    private static func qualifierRequired(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let element = dataSet[0x0040A300], element.vr == .SQ else { return .undetermined }
        if case .empty = element.value { return .satisfied }
        guard case .sequence(let items) = element.value else { return .undetermined }
        return items.isEmpty ? .satisfied : .unsatisfied
    }
}
