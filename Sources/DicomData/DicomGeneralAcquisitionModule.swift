import Foundation

/// C.7.10.1 General Acquisition module. All of its attributes are Type 3, so a mandatory module
/// adds no required attribute; value cardinality and non-negative counts/durations are checked here.
/// Temporal agreement with an external clock (C.7.4.2) is not evaluated.
public enum DicomGeneralAcquisitionModule {
    public static func rules(for dataSet: DicomDataSet) -> [DicomAttributeRule] {
        [0x00080017, 0x00080022, 0x0008002A, 0x00080032, 0x00083010, 0x00189073, 0x00200012, 0x00201002].map {
            .init(tag: $0, requirement: .type3, constraints: [.valueCount(0...1)])
        } + [
            .init(tag: 0x00201002, requirement: .type3, constraints: [.integerRange(0...Int.max)]),
            .init(tag: 0x00189073, requirement: .type3, constraints: [.requiredCondition(.known(nonNegativeDuration(in: dataSet)))])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(for: dataSet), limits: limits)
    }

    private static func nonNegativeDuration(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let element = dataSet[0x00189073] else { return .satisfied }
        guard element.vr == .FD, case .floats(let values) = element.value else { return .undetermined }
        return values.allSatisfy { $0 >= 0 } ? .satisfied : .unsatisfied
    }
}
