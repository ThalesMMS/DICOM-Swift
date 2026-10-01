import Foundation

/// C.7.6.4 Contrast/Bolus module, required when contrast media was used. Use is evidenced only
/// by the module's own attributes, so the module is evaluated when any of them is present.
public enum DicomContrastBolusModule {
    private static let tags = [0x00180010, 0x00180012, 0x00180014, 0x0018002A, 0x00181040, 0x00181041, 0x00181042, 0x00181043,
                               0x00181044, 0x00181046, 0x00181047, 0x00181048, 0x00181049]

    public static func applies(to dataSet: DicomDataSet) -> Bool { tags.contains(where: dataSet.contains) }

    public static func rules() -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        return [
            .init(tag: 0x00180010, requirement: .type2),
            .init(tag: 0x00180012, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00180014, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...1)]),
            .init(tag: 0x0018002A, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...Int.max)])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        guard applies(to: dataSet) else { return .init() }
        return DicomAttributeValidator.validate(dataSet, rules: rules(), limits: limits)
    }
}
