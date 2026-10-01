import Foundation

/// C.8.2.3 Single-Frame CT Series, required for CT Image Storage - For Processing and otherwise
/// optional; evaluated when Presentation Intent Type is declared or the SOP Class requires it.
public enum DicomSingleFrameCTSeriesModule {
    public static let forProcessingSOPClassUID = "1.2.840.10008.5.1.4.1.1.2.3"

    public static func applies(to dataSet: DicomDataSet) -> Bool {
        dataSet.contains(0x00080068) || dataSet.string(for: 0x00080016) == forProcessingSOPClassUID
    }

    public static func rules(for dataSet: DicomDataSet) -> [DicomAttributeRule] {
        let forProcessing: DicomAttributeRule.Truth = dataSet.string(for: 0x00080016) == forProcessingSOPClassUID ? .satisfied : .unsatisfied
        return [
            .init(tag: 0x00080060, requirement: .type1, constraints: [.strings(["CT"])]),
            .init(tag: 0x00080068, requirement: .type1C, condition: .known(forProcessing), mayBePresentOtherwise: true,
                  constraints: [.valueCount(1...1), .strings(["FOR PRESENTATION", "FOR PROCESSING"])])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        guard applies(to: dataSet) else { return .init() }
        return DicomAttributeValidator.validate(dataSet, rules: rules(for: dataSet), limits: limits)
    }
}
