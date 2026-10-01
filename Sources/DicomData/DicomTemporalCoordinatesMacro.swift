import Foundation

/// PS3.3 C.18.7 attribute/representation rules. Target resolution, sample bounds and temporal alignment are separate evidence.
public enum DicomTemporalCoordinatesMacro {
    public static let standardEdition = "2026c"

    public struct Conditions: Sendable {
        public var referencesWaveform: DicomAttributeRule.Truth = .undetermined
        /// The selected waveform channels belong to one multiplex group, established from resolved targets/selectors.
        public var channelsUseSingleMultiplexGroup: DicomAttributeRule.Truth = .undetermined
        public init() {}
    }

    public static func rules(conditions: Conditions = .init()) -> [DicomAttributeRule] {
        let tags: Set<Int> = [0x0040A132, 0x0040A138, 0x0040A13A]
        var result: [DicomAttributeRule] = [.init(tag: 0x0040A130, requirement: .type1,
            constraints: [.valueCount(1...1), .strings(["POINT", "MULTIPOINT", "SEGMENT", "MULTISEGMENT", "BEGIN", "END"]),
                          .exactlyOnePresent(tags)])]
        for tag in tags.sorted() {
            var conditionsForValue = tags.sorted().filter { $0 != tag }.map { DicomAttributeRule.Condition.not(.present($0)) }
            var constraints: [DicomAttributeRule.Constraint] = [.temporalCoordinateValues]
            if tag == 0x0040A132 {
                conditionsForValue.append(.known(conditions.referencesWaveform))
                constraints.append(.requiredCondition(.known(conditions.channelsUseSingleMultiplexGroup)))
            }
            result.append(.init(tag: tag, requirement: .type1C, condition: .all(conditionsForValue), constraints: constraints))
        }
        return result
    }

    public static func validate(_ dataSet: DicomDataSet, conditions: Conditions = .init(),
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(conditions: conditions), limits: limits)
    }
}
