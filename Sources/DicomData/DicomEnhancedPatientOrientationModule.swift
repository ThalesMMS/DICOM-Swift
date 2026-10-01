import Foundation

/// Declared C.7.6.30 Enhanced Patient Orientation module (Patient Orientation Macro).
/// Membership in the Defined context groups for orientation and equipment relationship is not verified.
public enum DicomEnhancedPatientOrientationModule {
    public static func applies(to dataSet: DicomDataSet) -> Bool {
        dataSet.contains(0x00540410) || dataSet.contains(0x30100030)
    }

    public static func validate(_ dataSet: DicomDataSet, limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        guard applies(to: dataSet) else { return .init() }
        return DicomAttributeValidator.validate(dataSet, rules: DicomCommonMacros.patientOrientation(), limits: limits)
    }
}
