import Foundation

/// CR Series (C.8.1.1), CR Image (C.8.1.2) with its calibration and exposure-index macros, and the
/// optional Display Shutter module (C.7.6.11) of the Computed Radiography Image IOD.
public enum DicomCRModules {
    private static let shutterTags = [0x00181600, 0x00181602, 0x00181604, 0x00181606, 0x00181608, 0x00181610, 0x00181612,
                                      0x00181620, 0x00181622, 0x00181624]

    public static func rules(for dataSet: DicomDataSet, calibratedImage: DicomAttributeRule.Truth) -> [DicomAttributeRule] {
        var rules: [DicomAttributeRule] = [
            // C.8.1.1 CR Series.
            .init(tag: 0x00180015, requirement: .type2),
            .init(tag: 0x00185101, requirement: .type2),
            // C.8.1.2 CR Image with Tables 10-10 and 10-23.
            .init(tag: 0x00280004, requirement: .type1, constraints: [.strings(["MONOCHROME1", "MONOCHROME2"])]),
            .init(tag: 0x00181402, requirement: .type3, constraints: [.strings(["LANDSCAPE", "PORTRAIT"])]),
            .init(tag: 0x00181404, requirement: .type3, constraints: [.integerRange(0...Int.max)])
        ] + DicomCommonMacros.pixelSpacingCalibration(calibratedImage: calibratedImage)
        if shutterTags.contains(where: dataSet.contains) {
            rules += displayShutterRules(for: dataSet)
        }
        return rules
    }

    /// Table C.7-17a: every shape names its own geometry; a shape may appear at most once.
    static func displayShutterRules(for dataSet: DicomDataSet) -> [DicomAttributeRule] {
        func shape(_ value: String) -> DicomAttributeRule.Condition { .stringEquals(0x00181600, value) }
        return [
            .init(tag: 0x00181600, requirement: .type1, constraints: [.valueCount(1...3),
                .strings(["RECTANGULAR", "CIRCULAR", "POLYGONAL"]), .requiredCondition(.known(distinctShapes(in: dataSet)))]),
            .init(tag: 0x00181602, requirement: .type1C, condition: shape("RECTANGULAR"), mayBePresentOtherwise: true),
            .init(tag: 0x00181604, requirement: .type1C, condition: shape("RECTANGULAR"), mayBePresentOtherwise: true),
            .init(tag: 0x00181606, requirement: .type1C, condition: shape("RECTANGULAR"), mayBePresentOtherwise: true),
            .init(tag: 0x00181608, requirement: .type1C, condition: shape("RECTANGULAR"), mayBePresentOtherwise: true),
            .init(tag: 0x00181610, requirement: .type1C, condition: shape("CIRCULAR"), mayBePresentOtherwise: true,
                  constraints: [.valueCount(2...2)]),
            .init(tag: 0x00181612, requirement: .type1C, condition: shape("CIRCULAR"), mayBePresentOtherwise: true),
            .init(tag: 0x00181620, requirement: .type1C, condition: shape("POLYGONAL"), mayBePresentOtherwise: true,
                  constraints: [.valueCount(6...Int.max)]),
            .init(tag: 0x00181622, requirement: .type3, constraints: [.valueCount(1...1)]),
            .init(tag: 0x00181624, requirement: .type3, constraints: [.valueCount(3...3)])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, calibratedImage: DicomAttributeRule.Truth = .undetermined,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(for: dataSet, calibratedImage: calibratedImage), limits: limits)
    }

    private static func distinctShapes(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let element = dataSet[0x00181600] else { return .satisfied }
        guard element.vr == .CS, case .strings(let values) = element.value else { return .undetermined }
        let shapes = values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }.filter { !$0.isEmpty }
        return Set(shapes).count == shapes.count ? .satisfied : .unsatisfied
    }
}
