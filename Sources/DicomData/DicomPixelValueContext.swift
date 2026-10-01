import Foundation

/// Only the discriminators needed for a contextual VR cross dataset/item boundaries.
/// A present but invalid local value replaces the inherited value, so it cannot
/// accidentally acquire the parent's meaning during recovery.
package struct DicomPixelValueContext {
    package static let discriminatorTags: [Int] = [0x00080060, 0x00280101, 0x00280103, 0x00281052, 0x00281053, 0x00281054, 0x00283000, 0x54001004]
    private var values: [Int: DicomDataElement] = [:]

    package init() {}

    package init(_ source: DicomDataSet, inheriting parent: Self = .init()) {
        values = parent.values
        for tag in Self.discriminatorTags {
            if let element = source[tag] { values[tag] = element }
        }
    }

    var storedValueVR: DicomVR? {
        guard let representation = unsignedWord(0x00280103), representation <= 1 else { return nil }
        return representation == 1 ? .SS : .US
    }

    func waveformVR(explicitVR: Bool) -> DicomVR? {
        guard explicitVR else { return .OW }
        guard let bits = unsignedWord(0x54001004) else { return nil }
        switch bits {
        case 8: return .OB
        case 16, 32, 64: return .OW
        default: return nil
        }
    }

    /// PS3.3 C.11.2.1.1: VOI input follows the possible output of the modality transform.
    package var voiInputVR: DicomVR? {
        let hasRescale = values[0x00281052] != nil || values[0x00281053] != nil
        if let modalityLUT = values[0x00283000] {
            guard !hasRescale, case .sequence(let items) = modalityLUT.value, !items.isEmpty else { return nil }
            return .US
        }
        guard hasRescale else { return storedValueVR }
        guard var slope = decimal(0x00281053), var intercept = decimal(0x00281052) else { return nil }
        if values[0x00080060]?.stringValue == "CT", values[0x00281054]?.stringValue == "HU" { return .SS }
        guard let storedVR = storedValueVR, let bits = unsignedWord(0x00280101), (1...64).contains(bits) else { return nil }
        // Decimal keeps the 64-bit endpoints exact, unlike conversion through Double.
        let power = (0..<bits).reduce(Decimal(1)) { value, _ in value * 2 }
        let lower = storedVR == .SS ? -power / 2 : 0
        let upper = storedVR == .SS ? power / 2 - 1 : power - 1
        guard let first = transformed(lower, slope: &slope, intercept: &intercept),
              let last = transformed(upper, slope: &slope, intercept: &intercept) else { return nil }
        return min(first, last) < 0 ? .SS : .US
    }

    private func unsignedWord(_ tag: Int) -> UInt? {
        guard let element = values[tag], element.vr == .US,
              case .unsignedIntegers(let words) = element.value, words.count == 1 else { return nil }
        return words[0]
    }

    private func decimal(_ tag: Int) -> Decimal? {
        guard let element = values[tag], element.vr == .DS,
              case .strings(let strings) = element.value, strings.count == 1 else { return nil }
        return try? DicomDecimalString.parse(strings[0])
    }

    private func transformed(_ input: Decimal, slope: inout Decimal, intercept: inout Decimal) -> Decimal? {
        var input = input
        var product = Decimal()
        var output = Decimal()
        guard NSDecimalMultiply(&product, &input, &slope, .plain) == .noError,
              NSDecimalAdd(&output, &product, &intercept, .plain) == .noError else { return nil }
        return output
    }
}
