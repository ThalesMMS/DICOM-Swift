import Foundation

/// C.17.1 SR Document Series and C.17.6.1 Key Object Document Series.
public enum DicomSRSeriesModule {
    public static func rules(kind: DicomSRDocumentModule.Kind) -> [DicomAttributeRule] {
        [
            .init(tag: DicomTag.modality.rawValue, requirement: .type1, constraints: [.valueCount(1...1), .strings([kind == .keyObjectSelection ? "KO" : "SR"])]),
            .init(tag: DicomTag.seriesInstanceUID.rawValue, requirement: .type1, constraints: [.valueCount(1...1)]),
            .init(tag: DicomTag.seriesNumber.rawValue, requirement: .type1, constraints: [.valueCount(1...1)]),
            .init(tag: 0x00081111, requirement: .type2, itemRules: DicomCommonMacros.sopInstanceReference(), constraints: [.itemCount(0...1)]),
            .init(tag: 0x0008103F, requirement: .type3, itemRules: DicomCodeSequenceMacro.standardRules(), constraints: [.itemCount(1...1)])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, kind: DicomSRDocumentModule.Kind,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(kind: kind), limits: limits)
    }
}
