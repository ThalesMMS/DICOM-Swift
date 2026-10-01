import Foundation

/// C.8.6.2 and the Basic Pixel Spacing Calibration Macro. Does not qualify acquisition physics or coded view semantics.
public enum DicomSCImageModule {
    public static func rules(for dataSet: DicomDataSet,
                             calibratedImage: DicomAttributeRule.Truth = .undetermined) -> [DicomAttributeRule] {
        let pixel = pair(dataSet[0x00280030])
        let nominal = pair(dataSet[0x00182010])
        let imager = pair(dataSet[0x00181164])
        var emptyProgression = false
        if let progression = dataSet[0x00540500], progression.vr == .CS {
            switch progression.value {
            case .empty: emptyProgression = true
            case .strings(let values): emptyProgression = values.allSatisfy { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty }
            default: break
            }
        }
        let type = dataSet[0x00280A02]
        let declaresCalibration = type?.vr == .CS && type?.stringValues.count == 1 &&
            ["GEOMETRY", "FIDUCIAL"].contains(type?.stringValues.first?.trimmingCharacters(in: .whitespaces) ?? "")
        var calibrated = calibratedImage
        if calibrated == .undetermined {
            if declaresCalibration { calibrated = .satisfied }
            if case .values(let a, let b) = pixel {
                for reference in [nominal, imager] {
                    if case .values(let c, let d) = reference, a != c || b != d { calibrated = .satisfied }
                }
            }
        }
        return [
            .init(tag: 0x00280030, requirement: .type1C, condition: .known(calibrated), mayBePresentOtherwise: true,
                  constraints: [.requiredCondition(.known(validSpacing(pixel, in: dataSet))),
                    .requiredCondition(.known(calibratedImage == .unsatisfied ? agreement(pixel, with: nominal) : .satisfied)),
                    .requiredCondition(.known(calibratedImage == .unsatisfied ? agreement(pixel, with: imager) : .satisfied))]),
            .init(tag: 0x00182010, requirement: .type3,
                  constraints: [.requiredCondition(.known(validSpacing(nominal, in: dataSet))),
                    .requiredCondition(.known(aspectAgreement(nominal, with: pair(dataSet[0x00280034], vr: .IS))))]),
            .init(tag: 0x00181164, requirement: .type3, constraints: [.requiredCondition(.known(validSpacing(imager, in: dataSet)))]),
            .init(tag: 0x00280A02, requirement: .type3, constraints: [.strings(["GEOMETRY", "FIDUCIAL"]),
                .requiredCondition(.known(calibratedImage == .unsatisfied && declaresCalibration ? .unsatisfied : .satisfied))]),
            .init(tag: 0x00280A04, requirement: .type1C, condition: .present(0x00280A02)),
            .init(tag: 0x0040E008, requirement: .type3, itemRules: DicomCodeSequenceMacro.standardRules(),
                  constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00540220, requirement: .type3, itemRules: DicomCodeSequenceMacro.standardRules() + [
                .init(tag: 0x00540222, requirement: .type3, itemRules: DicomCodeSequenceMacro.standardRules(),
                      constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...1), .requiredCondition(.known(.undetermined))]),
            // Progression depends on coded view meaning and the ordering of the actual series.
            .init(tag: 0x00540500, requirement: .type3,
                  constraints: [.requiredCondition(.known(emptyProgression ? .satisfied : .undetermined))])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet,
                                calibratedImage: DicomAttributeRule.Truth = .undetermined,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(for: dataSet, calibratedImage: calibratedImage), limits: limits)
    }

    private enum Pair {
        case empty
        case values(Decimal, Decimal)
        case invalid
        case unavailable
    }

    private static func pair(_ element: DicomDataElement?, vr: DicomVR = .DS) -> Pair {
        guard let element else { return .empty }
        guard element.vr == vr else { return .unavailable }
        if case .empty = element.value { return .empty }
        guard case .strings(let strings) = element.value else { return .unavailable }
        if strings.allSatisfy({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty }) { return .empty }
        guard strings.count == 2 else { return .invalid }
        do {
            let values = try strings.map { try DicomDecimalString.parse($0, vr: vr) }
            return .values(values[0], values[1])
        } catch DicomDecimalString.Failure.invalid { return .invalid }
        catch { return .unavailable }
    }

    private static func validSpacing(_ pair: Pair, in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        switch pair {
        case .empty: return .satisfied
        case .invalid: return .unsatisfied
        case .unavailable: return .undetermined
        case .values(let row, let column):
            var unknown = false
            for (value, tag) in [(row, 0x00280010), (column, 0x00280011)] {
                if value < 0 { return .unsatisfied }
                if value == 0 {
                    guard let element = dataSet[tag], element.vr == .US, element.vm.count == 1,
                          let dimension = element.intValue, (1...65535).contains(dimension) else { unknown = true; continue }
                    if dimension != 1 { return .unsatisfied }
                }
            }
            return unknown ? .undetermined : .satisfied
        }
    }

    private static func agreement(_ pixel: Pair, with reference: Pair) -> DicomAttributeRule.Truth {
        if case .empty = pixel { return .satisfied }
        if case .empty = reference { return .satisfied }
        guard case .values(let a, let b) = pixel, case .values(let c, let d) = reference else { return .undetermined }
        return a == c && b == d ? .satisfied : .unsatisfied
    }

    private static func aspectAgreement(_ nominal: Pair, with aspect: Pair) -> DicomAttributeRule.Truth {
        if case .empty = nominal { return .satisfied }
        if case .empty = aspect { return .satisfied }
        guard case .values(var row, var column) = nominal, case .values(var vertical, var horizontal) = aspect else { return .undetermined }
        guard vertical > 0, horizontal > 0 else { return .unsatisfied }
        guard row > 0, column > 0 else { return .undetermined }
        var left = Decimal()
        var right = Decimal()
        guard NSDecimalMultiply(&left, &row, &horizontal, .plain) == .noError,
              NSDecimalMultiply(&right, &column, &vertical, .plain) == .noError else { return .undetermined }
        return left == right ? .satisfied : .unsatisfied
    }
}
