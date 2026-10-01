import Foundation

/// Attribute rules for PS3.3 C.18.3/4/5. Target identity, selector bounds and payloads are separate evidence.
public enum DicomContentReferenceMacro {
    public static let standardEdition = "2026c"

    public enum Kind: String, Sendable {
        case composite = "COMPOSITE", image = "IMAGE", waveform = "WAVEFORM"
    }

    /// Facts established from the referenced object and the author's selection intent. A subset
    /// intent can only be encoded through the selector itself, so an absent selector with unstated
    /// intent is read as applying to all frames/segments/channels; a stated subset intent makes
    /// the selector required.
    public struct Conditions: Sendable {
        public var isMultiframeImage: DicomAttributeRule.Truth = .undetermined
        public var isSegmentation: DicomAttributeRule.Truth = .undetermined
        public var waveformHasMultipleChannels: DicomAttributeRule.Truth = .undetermined
        public var appliesToAllFrames: DicomAttributeRule.Truth = .undetermined
        public var appliesToAllSegments: DicomAttributeRule.Truth = .undetermined
        public var appliesToAllWaveformChannels: DicomAttributeRule.Truth = .undetermined

        public init() {}
    }

    public static func rules(kind: Kind, conditions: Conditions = .init()) -> [DicomAttributeRule] {
        var pair = DicomSRReferenceMacro.sopRules
        switch kind {
        case .composite: break
        case .image:
            pair += imageSelectorRules(conditions: conditions)
            // The accompanying objects each use a single SOP pair, not recursively expanded IMAGE macros.
            pair += [0x00081199, 0x0008114B].map {
                .init(tag: $0, requirement: .type3, itemRules: DicomSRReferenceMacro.sopRules,
                      constraints: [.itemCount(1...1)])
            }
            pair.append(.init(tag: 0x00880200, requirement: .type3, itemRules: DicomSRIconImageValidator.rules,
                              constraints: [.itemCount(1...1)]))
        case .waveform:
            pair.append(.init(tag: 0x0040A0B0, requirement: .type1C, condition: .all([
                .known(conditions.waveformHasMultipleChannels), subset(conditions.appliesToAllWaveformChannels, selector: 0x0040A0B0)
            ]), constraints: [.valueCount(2...Int.max), .evenValueCount, .integerRange(0...Int(UInt16.max))]))
        }
        return [.init(tag: 0x00081199, requirement: .type1, itemRules: pair, constraints: [.itemCount(1...1)])]
    }

    static func imageSelectorRules(conditions: Conditions) -> [DicomAttributeRule] {
        [
                .init(tag: 0x00081160, requirement: .type1C, condition: .all([
                    .known(conditions.isMultiframeImage), subset(conditions.appliesToAllFrames, selector: 0x00081160),
                    .not(.present(0x0062000B))
                ]), constraints: [.integerRange(1...Int.max)]),
                .init(tag: 0x0062000B, requirement: .type1C, condition: .all([
                    .known(conditions.isSegmentation), subset(conditions.appliesToAllSegments, selector: 0x0062000B),
                    .not(.present(0x00081160))
                ]), constraints: [.integerRange(1...Int(UInt16.max))])
            ]
    }

    /// Whether the reference applies to a subset of the object. Unstated intent is evidenced by the
    /// selector itself: an absent selector denotes the whole object, a present one a subset.
    private static func subset(_ appliesToAll: DicomAttributeRule.Truth, selector: Int) -> DicomAttributeRule.Condition {
        appliesToAll == .undetermined ? .present(selector) : .not(.known(appliesToAll))
    }

    /// Checks the attribute subset only; a pass does not qualify target SOP applicability, icons or signatures.
    public static func validate(_ dataSet: DicomDataSet, kind: Kind, conditions: Conditions = .init(),
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(kind: kind, conditions: conditions), limits: limits)
    }
}
