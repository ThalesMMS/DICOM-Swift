import Foundation

/// Declared Clinical Trial Subject, Study and Series modules (PS3.3 C.7.1.3, C.7.2.3, C.7.3.2).
/// Consent metadata is validated, never interpreted as authorization to distribute an instance.
public enum DicomClinicalTrialModules {
    private static let subjectTags = [0x00120010, 0x00120020, 0x00120021, 0x00120022, 0x00120023,
        0x00120030, 0x00120031, 0x00120032, 0x00120040, 0x00120041, 0x00120042, 0x00120043, 0x00120081, 0x00120082]
    private static let studyTags = [0x00120050, 0x00120051, 0x00120052, 0x00120053, 0x00120054, 0x00120055, 0x00120083]
    private static let seriesTags = [0x00120060, 0x00120071, 0x00120072, 0x00120073]

    public static func validate(_ dataSet: DicomDataSet,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var rules: [DicomAttributeRule] = []
        if subjectTags.contains(where: dataSet.contains) {
            rules += [0x00120010, 0x00120020].map { .init(tag: $0, requirement: .type1) }
            rules += [0x00120021, 0x00120030, 0x00120031].map { .init(tag: $0, requirement: .type2) }
            rules += [
                .init(tag: 0x00120023, requirement: .type3, itemRules: [
                    .init(tag: 0x00120020, requirement: .type1), .init(tag: 0x00120022, requirement: .type1)
                ], constraints: [.itemCount(1...Int.max)]),
                .init(tag: 0x00120040, requirement: .type1C, condition: .not(.present(0x00120042)), mayBePresentOtherwise: true),
                .init(tag: 0x00120042, requirement: .type1C, condition: .not(.present(0x00120040)), mayBePresentOtherwise: true),
                .init(tag: 0x00120081, requirement: .type1C, condition: .present(0x00120082))
            ]
        }
        if studyTags.contains(where: dataSet.contains) {
            rules += [
                .init(tag: 0x00120050, requirement: .type2),
                .init(tag: 0x00120053, requirement: .type1C, condition: .present(0x00120052)),
                .init(tag: 0x00120054, requirement: .type3, itemRules: DicomCodeSequenceMacro.standardRules(),
                      constraints: [.itemCount(1...Int.max)]),
                .init(tag: 0x00120083, requirement: .type3, itemRules: [
                    .init(tag: 0x00120085, requirement: .type1, constraints: [.strings(["NO", "YES", "WITHDRAWN"])]),
                    .init(tag: 0x00120084, requirement: .type1C,
                          condition: .any([.stringEquals(0x00120085, "YES"), .stringEquals(0x00120085, "WITHDRAWN")])),
                    // Without a Subject protocol, NAMED_PROTOCOL must identify its protocol here.
                    // Otherwise a missing item identifier does not establish which protocol was intended.
                    .init(tag: 0x00120020, requirement: .type1C,
                          condition: .all([.present(0x00120084), .stringEquals(0x00120084, "NAMED_PROTOCOL"),
                              .known(dataSet.contains(0x00120020) ? .undetermined : .satisfied)]))
                ], constraints: [.itemCount(1...Int.max)])
            ]
        }
        if seriesTags.contains(where: dataSet.contains) {
            rules.append(.init(tag: 0x00120060, requirement: .type2))
        }
        guard !rules.isEmpty else { return .init() }
        return DicomAttributeValidator.validate(dataSet, rules: rules, limits: limits)
    }
}
