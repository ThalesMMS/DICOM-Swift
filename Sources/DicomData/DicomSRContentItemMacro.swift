import Foundation

/// PS3.3 C.17-5/C.17-6 item requirements and C.18.8 container identification.
/// NUM, CODE, reference, coordinate and TABLE value macros are composed separately.
public enum DicomSRContentItemMacro {
    public static let standardEdition = "2026c"

    public struct Conditions: Sendable {
        public var containerHasHeading: DicomAttributeRule.Truth = .undetermined
        public var referencePurposeInConceptName: DicomAttributeRule.Truth = .undetermined
        public var observationTimeDiffers: DicomAttributeRule.Truth = .undetermined
        /// A template known at encoding defined a single-container subtree and this is its outermost invocation.
        public var identifyingTemplateRequired: DicomAttributeRule.Truth = .undetermined
        /// IOD-level Value Type enumeration (A.35); nil permits every C.17.3 Value Type.
        public var allowedValueTypes: Set<String>?
        public init() {}
    }

    private static let valueTypes: Set<String> = ["TEXT", "NUM", "CODE", "DATE", "TIME", "DATETIME", "UIDREF", "PNAME",
        "COMPOSITE", "IMAGE", "WAVEFORM", "SCOORD", "SCOORD3D", "TCOORD", "CONTAINER", "TABLE"]
    private static let relationships: Set<String> = ["CONTAINS", "HAS PROPERTIES", "HAS OBS CONTEXT", "HAS ACQ CONTEXT",
        "INFERRED FROM", "SELECTED FROM", "HAS CONCEPT MOD"]
    private static let scalarValues = [("TEXT", 0x0040A160), ("DATETIME", 0x0040A120), ("DATE", 0x0040A121),
                                       ("TIME", 0x0040A122), ("PNAME", 0x0040A123), ("UIDREF", 0x0040A124)]
    private static let payloadRoots: [(Int, Set<String>)] = [
        (0x0040A300, ["NUM"]), (0x0040A301, ["NUM"]), (0x0040A168, ["CODE"]),
        (0x00081199, ["IMAGE", "COMPOSITE", "WAVEFORM"]), (0x00700022, ["SCOORD", "SCOORD3D"]),
        (0x00700023, ["SCOORD", "SCOORD3D"]), (0x0070031A, ["SCOORD", "SCOORD3D"]),
        (0x00480301, ["SCOORD"]), (0x30060024, ["SCOORD3D"]),
        (0x0040A130, ["TCOORD"]), (0x0040A132, ["TCOORD"]), (0x0040A138, ["TCOORD"]), (0x0040A13A, ["TCOORD"]),
        (0x0040A050, ["CONTAINER"]), (0x0040A504, ["CONTAINER"]), (0x0040A801, ["TABLE"])
    ]

    public static func rules(for dataSet: DicomDataSet, isRoot: Bool = false, conditions: Conditions = .init(),
                             versionRequirements: [String: DicomAttributeRule.Truth] = [:]) -> [DicomAttributeRule] {
        let relationship = DicomAttributeRule(tag: 0x0040A010, requirement: isRoot ? .type3 : .type1,
            constraints: isRoot ? [.forbiddenWhen(.known(.satisfied))] : [.strings(relationships)])
        if dataSet.contains(0x0040DB73) {
            let forbidden = [0x0040A040, 0x0040A043, 0x0040A032, 0x0040A171, 0x0040A730] +
                scalarValues.map(\.1) + payloadRoots.map(\.0)
            return [relationship, .init(tag: 0x0040DB73, requirement: .type1C, condition: .known(.satisfied),
                constraints: [.integerRange(1...Int.max), .forbiddenWhen(.known(isRoot ? .satisfied : .unsatisfied))])] +
                forbidden.map { .init(tag: $0, requirement: .type3, constraints: [.forbiddenWhen(.known(.satisfied))]) }
        }
        let type = valueType(dataSet)
        let requiredConcept: DicomAttributeRule.Truth
        if isRoot || type.map({ ["TEXT", "NUM", "CODE", "DATETIME", "DATE", "TIME", "UIDREF", "PNAME", "TABLE"].contains($0) }) == true {
            requiredConcept = .satisfied
        } else if type == "CONTAINER" {
            // A heading is only evidenced by the concept name itself.
            requiredConcept = conditions.containerHasHeading == .undetermined
                ? (dataSet.contains(0x0040A043) ? .satisfied : .unsatisfied) : conditions.containerHasHeading
        } else if type != nil {
            // C.17.3 requires no concept name for reference and coordinate items; it may still be present.
            requiredConcept = conditions.referencePurposeInConceptName == .undetermined ? .unsatisfied : conditions.referencePurposeInConceptName
        } else { requiredConcept = .undetermined }
        // Outermost template invocations are the root or explicitly identified containers.
        let templateRequired = conditions.identifyingTemplateRequired == .undetermined && !isRoot
            ? (dataSet.contains(0x0040A504) ? .satisfied : .unsatisfied) : conditions.identifyingTemplateRequired
        var result: [DicomAttributeRule] = [
            relationship,
            .init(tag: 0x0040A040, requirement: .type1,
                  constraints: [.strings(isRoot ? ["CONTAINER"] : conditions.allowedValueTypes ?? valueTypes), .valueCount(1...1)]),
            .init(tag: 0x0040A043, requirement: .type1C, condition: .known(requiredConcept), mayBePresentOtherwise: true,
                  itemRules: DicomCodeSequenceMacro.rules(versionRequirements: versionRequirements), constraints: [.itemCount(1...1)]),
            .init(tag: 0x0040A032, requirement: .type1C, condition: .known(conditions.observationTimeDiffers), mayBePresentOtherwise: true),
            .init(tag: 0x0040A171, requirement: .type3),
            .init(tag: 0x0040A730, requirement: .type1C, condition: .present(0x0040A730), constraints: [.itemCount(1...Int.max)])
        ]
        for (valueType, tag) in scalarValues {
            result.append(.init(tag: tag, requirement: .type1C,
                condition: .known(type.map { $0 == valueType ? .satisfied : .unsatisfied } ?? .undetermined),
                constraints: tag == 0x0040A160 ? [.unformattedText] : []))
        }
        if let type {
            result += payloadRoots.filter { !$0.1.contains(type) }.map {
                .init(tag: $0.0, requirement: .type3, constraints: [.forbiddenWhen(.known(.satisfied))])
            }
        }
        if type == "CONTAINER" {
            result += [
                .init(tag: 0x0040A050, requirement: .type1, constraints: [.strings(["SEPARATE", "CONTINUOUS"])]),
                .init(tag: 0x0040A504, requirement: .type1C, condition: .known(templateRequired), itemRules: [
                    .init(tag: 0x00080105, requirement: .type1), .init(tag: 0x00080118, requirement: .type3),
                    .init(tag: 0x0040DB00, requirement: .type1, constraints: [.dicomTemplateIdentifier])
                ], constraints: [.itemCount(1...1)])
            ]
        }
        return result
    }

    public static func validate(_ dataSet: DicomDataSet, isRoot: Bool = false, conditions: Conditions = .init(),
                                versionRequirements: [String: DicomAttributeRule.Truth] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(for: dataSet, isRoot: isRoot, conditions: conditions,
            versionRequirements: versionRequirements), limits: limits)
    }

    package static func valueType(_ dataSet: DicomDataSet) -> String? {
        guard let element = dataSet[0x0040A040], element.vr == .CS, case .strings(let values) = element.value,
              values.count == 1, values[0].utf8.count <= 16 else { return nil }
        let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return valueTypes.contains(value) ? value : nil
    }
}
