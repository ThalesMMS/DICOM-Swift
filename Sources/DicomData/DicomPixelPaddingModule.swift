import Foundation

/// Declared integer pixel padding for classic CT/MR/SC (C.7.5.1.1.2).
/// Does not establish which source pixels belong to the unpadded acquisition image.
public enum DicomPixelPaddingModule {
    public static func validate(_ dataSet: DicomDataSet, hasPixelData: DicomAttributeRule.Truth = .undetermined,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let pixel = DicomAttributeRule.Condition.any([.known(hasPixelData), .present(0x00287FE0)])
        let constraints: (Int) -> [DicomAttributeRule.Constraint] = { tag in
            [.valueCount(0...1), .forbiddenWhen(.not(pixel)),
             .requiredCondition(.known(domain(dataSet, tag: tag)))]
        }
        return DicomAttributeValidator.validate(dataSet, rules: [
            .init(tag: 0x00280120, requirement: .type1C, condition: .all([pixel, .present(0x00280121)]),
                  mayBePresentOtherwise: true, constraints: constraints(0x00280120)),
            // A present Range Limit declares a range; missing acquisition intent is not inferred.
            .init(tag: 0x00280121, requirement: .type1C, condition: .present(0x00280121),
                  constraints: constraints(0x00280121) + [.requiredCondition(.present(0x00280120)),
                      .requiredCondition(.known(order(dataSet)))])
        ], limits: limits)
    }

    private static func domain(_ dataSet: DicomDataSet, tag: Int) -> DicomAttributeRule.Truth {
        guard let element = dataSet[tag] else { return .undetermined }
        if case .empty = element.value { return .satisfied }
        guard let samples = word(dataSet, 0x00280002), let photo = photometric(dataSet) else { return .undetermined }
        guard samples == 1, ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR"].contains(photo) else { return .unsatisfied }
        guard let allocated = word(dataSet, 0x00280100), let stored = word(dataSet, 0x00280101),
              let high = word(dataSet, 0x00280102), let representation = word(dataSet, 0x00280103) else { return .undetermined }
        guard allocated == 1 || allocated > 0 && allocated.isMultiple(of: 8),
              stored > 0, stored <= allocated, high == stored - 1, representation <= 1 else { return .unsatisfied }
        guard element.vr != .UN else { return .undetermined }
        guard element.vr == (representation == 1 ? .SS : .US), element.vm.count == 1,
              let value = element.intValue else { return .unsatisfied }
        // Padding attributes themselves are 16-bit US/SS, even for wider stored pixels.
        let bits = min(stored, 16)
        let lower = representation == 1 ? -(1 << (bits - 1)) : 0
        let upper = representation == 1 ? (1 << (bits - 1)) - 1 : (1 << bits) - 1
        return (lower...upper).contains(value) ? .satisfied : .unsatisfied
    }

    private static func order(_ dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let first = dataSet[0x00280120], let last = dataSet[0x00280121],
              [.US, .SS].contains(first.vr), first.vr == last.vr,
              first.vm.count == 1, last.vm.count == 1,
              let low = first.intValue, let high = last.intValue, let photo = photometric(dataSet) else { return .undetermined }
        switch photo {
        case "MONOCHROME1": return low >= high ? .satisfied : .unsatisfied
        case "MONOCHROME2", "PALETTE COLOR": return low <= high ? .satisfied : .unsatisfied
        default: return .unsatisfied
        }
    }

    private static func word(_ dataSet: DicomDataSet, _ tag: Int) -> Int? {
        guard let element = dataSet[tag], element.vr == .US, element.vm.count == 1,
              let value = element.intValue, (0...65535).contains(value) else { return nil }
        return value
    }

    private static func photometric(_ dataSet: DicomDataSet) -> String? {
        guard let element = dataSet[0x00280004], element.vr == .CS,
              case .strings(let values) = element.value, values.count == 1, values[0].utf8.count <= 16 else { return nil }
        let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return value.isEmpty ? nil : value
    }
}
