import Foundation

/// Declared C.7.6.12 Device Sequence. Defined Terms for diameter units remain extensible.
public enum DicomDeviceModule {
    public static func validate(_ dataSet: DicomDataSet,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        guard dataSet.contains(0x00500010) else { return .init() }
        return DicomAttributeValidator.validate(dataSet, rules: [
            .init(tag: 0x00500010, requirement: .type1,
                  itemRules: DicomCodeSequenceMacro.standardRules() + [
                    .init(tag: 0x00500017, requirement: .type2C, condition: .present(0x00500016))
                  ], constraints: [.itemCount(1...Int.max)])
        ], limits: limits)
    }
}
