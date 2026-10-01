import Foundation

/// Declared C.7.6.22 Specimen module (Table C.7.6.22-2). Identifier meaning, laboratory
/// workflow and Defined context groups for container/specimen types are not interpreted.
public enum DicomSpecimenModule {
    private static let tags = [0x00400512, 0x00400513, 0x00400515, 0x00400518, 0x0040051A, 0x00400520, 0x00400560]

    public static func applies(to dataSet: DicomDataSet) -> Bool { tags.contains(where: dataSet.contains) }

    public static func rules(for dataSet: DicomDataSet) -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        let issuer = DicomCommonMacros.hl7HierarchicDesignator()
        let terminology: [DicomAttributeRule.Constraint] = [.itemCount(1...1), .requiredCondition(.known(.undetermined))]
        return [
            .init(tag: 0x00400512, requirement: .type1, constraints: [.valueCount(1...1)]),
            .init(tag: 0x00400513, requirement: .type2, itemRules: issuer, constraints: [.itemCount(0...1)]),
            .init(tag: 0x00400515, requirement: .type3, itemRules: [
                .init(tag: 0x00400512, requirement: .type1, constraints: [.valueCount(1...1)]),
                .init(tag: 0x00400513, requirement: .type2, itemRules: issuer, constraints: [.itemCount(0...1)])
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00400518, requirement: .type2, itemRules: codes,
                  constraints: dataSet.sequenceItems(for: 0x00400518).isEmpty ? [.itemCount(0...1)] : [.itemCount(0...1), .requiredCondition(.known(.undetermined))]),
            .init(tag: 0x00400520, requirement: .type3, itemRules: [
                .init(tag: 0x00500012, requirement: .type1, itemRules: codes, constraints: [.itemCount(1...1)])
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00400560, requirement: .type1, itemRules: [
                .init(tag: 0x00400551, requirement: .type1, constraints: [.valueCount(1...1)]),
                .init(tag: 0x00400554, requirement: .type1, constraints: [.valueCount(1...1)]),
                .init(tag: 0x00400562, requirement: .type2, itemRules: issuer, constraints: [.itemCount(0...1)]),
                .init(tag: 0x0040059A, requirement: .type3, itemRules: codes, constraints: terminology),
                .init(tag: 0x00400610, requirement: .type2, itemRules: [
                    .init(tag: 0x00400612, requirement: .type1, itemRules: DicomCommonMacros.contentItem(),
                          constraints: [.itemCount(1...Int.max)])
                ]),
                // Required when the image holds multiple specimens, which the description count establishes.
                .init(tag: 0x00400620, requirement: .type1C, condition: .known(multipleSpecimens(in: dataSet)),
                      itemRules: DicomCommonMacros.contentItem(), constraints: [.itemCount(1...Int.max)]),
                .init(tag: 0x00082228, requirement: .type3, itemRules: codes + [
                    .init(tag: 0x00082230, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...Int.max)])
                ], constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...Int.max)])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        guard applies(to: dataSet) else { return .init() }
        return DicomAttributeValidator.validate(dataSet, rules: rules(for: dataSet), limits: limits)
    }

    private static func multipleSpecimens(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let element = dataSet[0x00400560], element.vr == .SQ, case .sequence(let items) = element.value else { return .undetermined }
        return items.count > 1 ? .satisfied : .unsatisfied
    }
}
