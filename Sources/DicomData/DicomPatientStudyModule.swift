import Foundation

/// Declared C.7.2.2 Patient Study module. Every root attribute is Type 3, so the module is
/// evaluated once any of its attributes is present; nested requirements and the non-human
/// condition then apply. Clinical meaning of the values is not interpreted.
public enum DicomPatientStudyModule {
    private static let tags = [0x00081080, 0x00081084, 0x00081301, 0x00081302, 0x00081303, 0x00081304, 0x00100011,
        0x00100014, 0x00100041, 0x00100043, 0x00101010, 0x00101020, 0x00101021, 0x00101022, 0x00101023, 0x00101024,
        0x00101030, 0x00102000, 0x00102110, 0x00102180, 0x001021A0, 0x001021B0, 0x001021C0, 0x001021D0, 0x00102203,
        0x00321066, 0x00321067, 0x00380010, 0x00380014, 0x00380060, 0x00380062, 0x00380064, 0x00380500]

    public static func applies(to dataSet: DicomDataSet) -> Bool { tags.contains(where: dataSet.contains) }

    public static func rules(nonHumanPatient: DicomAttributeRule.Truth) -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        let issuer = DicomCommonMacros.hl7HierarchicDesignator()
        let effective: [DicomAttributeRule] = [.init(tag: 0x0040A034, requirement: .type3), .init(tag: 0x0040A035, requirement: .type3)]
        return [0x00081084, 0x00081301, 0x00081302, 0x00081303, 0x00081304, 0x00101021, 0x00321067].map {
            .init(tag: $0, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...Int.max)])
        } + [
            .init(tag: 0x00100011, requirement: .type3, itemRules: [
                .init(tag: 0x00100012, requirement: .type1), .init(tag: 0x00100013, requirement: .type3)
            ] + effective, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00100014, requirement: .type3, itemRules: [
                .init(tag: 0x00100015, requirement: .type1, itemRules: codes, constraints: [.itemCount(1...1)]),
                .init(tag: 0x00100016, requirement: .type3)
            ] + effective, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00100041, requirement: .type3, itemRules: [
                .init(tag: 0x00100044, requirement: .type1, itemRules: codes, constraints: [.itemCount(1...1)]),
                .init(tag: 0x00100045, requirement: .type3)
            ] + effective, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00100043, requirement: .type3, itemRules: [
                .init(tag: 0x00100046, requirement: .type1, itemRules: codes, constraints: [.itemCount(1...1)]),
                // Both depend on the nested code being (131232, DCM, "Specified"); nested values are not
                // reachable by a rule condition, so the requirement stays undetermined rather than assumed.
                .init(tag: 0x00100042, requirement: .type2C, condition: .undetermined),
                .init(tag: 0x00100047, requirement: .type2C, condition: .undetermined)
            ] + effective, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x001021A0, requirement: .type3, constraints: [.strings(["YES", "NO", "UNKNOWN"])]),
            .init(tag: 0x001021C0, requirement: .type3, constraints: [.valueCount(1...1), .integers([1, 2, 3, 4])]),
            .init(tag: 0x00102203, requirement: .type2C, condition: .known(nonHumanPatient),
                  constraints: [.strings(["ALTERED", "UNALTERED"])]),
            .init(tag: 0x00380014, requirement: .type3, itemRules: issuer, constraints: [.itemCount(1...1)]),
            .init(tag: 0x00380064, requirement: .type3, itemRules: issuer, constraints: [.itemCount(1...1)])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, nonHumanPatient: DicomAttributeRule.Truth = .undetermined,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        guard applies(to: dataSet) else { return .init() }
        return DicomAttributeValidator.validate(dataSet, rules: rules(nonHumanPatient: nonHumanPatient), limits: limits)
    }
}
