import Foundation

/// Declared C.7.4.2 Synchronization module. Cross-instance agreement of the synchronization
/// frame of reference within a series is not verified from a single instance.
public enum DicomSynchronizationModule {
    private static let tags = [0x00181061, 0x0018106A, 0x0018106C, 0x00181800, 0x00181801, 0x00181802, 0x00181803, 0x00200200]

    public static func applies(to dataSet: DicomDataSet) -> Bool { tags.contains(where: dataSet.contains) }

    public static func rules() -> [DicomAttributeRule] {
        [
            .init(tag: 0x00200200, requirement: .type1, constraints: [.valueCount(1...1)]),
            .init(tag: 0x0018106A, requirement: .type1, constraints: [.valueCount(1...1), .strings(["SOURCE", "EXTERNAL", "PASSTHRU", "NO TRIGGER"])]),
            // C.7.4.2: required if the channel or trigger is encoded in a waveform of this instance.
            .init(tag: 0x0018106C, requirement: .type1C, condition: .all([.present(0x54000100),
                .any([.present(0x0018106C), .all([.not(.stringEquals(0x0018106A, "NO TRIGGER")), .known(.undetermined)])])]),
                  constraints: [.valueCount(2...2)]),
            .init(tag: 0x00181800, requirement: .type1, constraints: [.valueCount(1...1), .strings(["Y", "N"])]),
            .init(tag: 0x00181802, requirement: .type3, constraints: [.strings(["NTP", "IRIG", "GPS", "SNTP", "PTP"])])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        guard applies(to: dataSet) else { return .init() }
        return DicomAttributeValidator.validate(dataSet, rules: rules(), limits: limits)
    }
}
