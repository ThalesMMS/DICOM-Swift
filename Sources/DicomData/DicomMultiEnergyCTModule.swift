import Foundation

/// C.8.2.2 Multi-energy CT Image module, required when Multi-energy CT Acquisition is YES:
/// the acquisition sequence with its source, detector and path macros, the CT exposure,
/// X-Ray details, acquisition details and geometry sequences, the processing sequence and the
/// characteristics sequence. Index references between sources, detectors and paths are checked.
public enum DicomMultiEnergyCTModule {
    public static func applies(to dataSet: DicomDataSet) -> Bool {
        dataSet.contains(0x00189362) || dataSet.contains(0x00189363) || dataSet.contains(0x00189364)
            || dataSet.string(for: 0x00189361)?.trimmingCharacters(in: CharacterSet(charactersIn: " ")) == "YES"
    }

    public static func rules(for dataSet: DicomDataSet) -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        let algorithm = DicomCommonMacros.algorithmIdentification()
        let imageType = components(dataSet[0x00080008])
        let original = DicomAttributeRule.Condition.known(imageType.map { $0.first == "ORIGINAL" ? .satisfied : .unsatisfied } ?? .undetermined)
        let multiEnergy = DicomAttributeRule.Condition.known(dataSet.string(for: 0x00189361).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) == "YES" ? .satisfied : .unsatisfied
        } ?? .unsatisfied)
        let monoenergetic = DicomAttributeRule.Condition.known(imageType.map { $0.count > 3 && $0[3] == "VMI" ? .satisfied : .unsatisfied } ?? .undetermined)
        let weighting = DicomAttributeRule.Condition.known(proportionalWeighting(in: dataSet))
        // An absent Acquisition Type is not a CONSTANT_ANGLE acquisition.
        let rotating = DicomAttributeRule.Condition.any([.not(.present(0x00189302)), .not(.stringEquals(0x00189302, "CONSTANT_ANGLE"))])
        func originalRule(_ tag: Int, condition: DicomAttributeRule.Condition = original) -> DicomAttributeRule {
            .init(tag: tag, requirement: .type1C, condition: condition, mayBePresentOtherwise: true)
        }
        let acquisition: [DicomAttributeRule] = [
            .init(tag: 0x0018937B, requirement: .type3),
            .init(tag: 0x00189365, requirement: .type1, itemRules: [0x00189366, 0x00189367, 0x00189368, 0x00189369, 0x0018936A].map {
                .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1)])
            } + [.init(tag: 0x0018936B, requirement: .type1C, condition: .stringEquals(0x00189368, "SWITCHING_SOURCE"), mayBePresentOtherwise: true)],
                  constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0018936F, requirement: .type1, itemRules: [0x00189370, 0x00189371, 0x00189372].map {
                .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1)])
            } + [
                .init(tag: 0x00189374, requirement: .type1C, condition: .stringEquals(0x00189372, "PHOTON_COUNTING"), mayBePresentOtherwise: true),
                .init(tag: 0x00189375, requirement: .type1C, condition: .stringEquals(0x00189372, "PHOTON_COUNTING"), mayBePresentOtherwise: true)
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00189379, requirement: .type1, itemRules: [0x00189376, 0x00189377, 0x0018937A].map {
                .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1)])
            }, constraints: [.itemCount(1...Int.max)]),
            // Tables C.8-124, C.8-125, C.8-119 and C.8-122 with their ORIGINAL-image conditions.
            .init(tag: 0x00189321, requirement: .type1, itemRules: [
                .init(tag: 0x00181272, requirement: .type1C, condition: .present(0x00181271), itemRules: codes, constraints: [.itemCount(1...1)]),
                originalRule(0x00189323), originalRule(0x00189328, condition: .all([original, multiEnergy])),
                originalRule(0x00189330), originalRule(0x00189332),
                .init(tag: 0x00189345, requirement: .type2C, condition: original),
                .init(tag: 0x00189346, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...1)]),
                .init(tag: 0x00189377, requirement: .type1C, condition: multiEnergy, mayBePresentOtherwise: true)
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00189325, requirement: .type1, itemRules: [
                originalRule(0x00180060), originalRule(0x00181160), originalRule(0x00181190),
                originalRule(0x00187050, condition: .all([original, .not(.stringEquals(0x00181160, "NONE"))])),
                .init(tag: 0x00189353, requirement: .type1C, condition: weighting, mayBePresentOtherwise: true),
                .init(tag: 0x00189378, requirement: .type1C, condition: multiEnergy, mayBePresentOtherwise: true)
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00189304, requirement: .type1, itemRules: [
                originalRule(0x00180090), originalRule(0x00181120), originalRule(0x00181130),
                .init(tag: 0x00181140, requirement: .type1C, condition: .all([original, rotating]),
                      mayBePresentOtherwise: true, constraints: [.strings(["CW", "CC"])]),
                originalRule(0x00189305, condition: .all([original, rotating])),
                originalRule(0x00189306), originalRule(0x00189307),
                .init(tag: 0x00189378, requirement: .type1C, condition: multiEnergy, mayBePresentOtherwise: true)
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00189312, requirement: .type1, itemRules: [
                originalRule(0x00181110), originalRule(0x00189335),
                .init(tag: 0x00189378, requirement: .type1C, condition: multiEnergy, mayBePresentOtherwise: true)
            ], constraints: [.itemCount(1...Int.max)])
        ]
        return [
            .init(tag: 0x00189362, requirement: .type1, itemRules: acquisition, constraints: [.itemCount(1...1)]),
            // A.3.3.1: multi-energy images carry a Real World Value Mapping (validated by General Image).
            .init(tag: 0x00409096, requirement: .type1C, condition: multiEnergy, mayBePresentOtherwise: true),
            .init(tag: 0x00189363, requirement: .type3, itemRules: [
                .init(tag: 0x0018937E, requirement: .type1), .init(tag: 0x0018937F, requirement: .type3),
                .init(tag: 0x00189380, requirement: .type3, itemRules: algorithm, constraints: [.itemCount(1...Int.max)]),
                .init(tag: 0x00189381, requirement: .type3, itemRules: [
                    .init(tag: 0x0018937D, requirement: .type1, itemRules: codes, constraints: [.itemCount(1...1)])
                ], constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00189364, requirement: .type1C, condition: monoenergetic, mayBePresentOtherwise: true, itemRules: [
                .init(tag: 0x0018937C, requirement: .type1C, condition: monoenergetic, mayBePresentOtherwise: true),
                .init(tag: 0x00221612, requirement: .type3, itemRules: algorithm, constraints: [.itemCount(1...Int.max)]),
                .init(tag: 0x00741212, requirement: .type3, itemRules: DicomCommonMacros.contentItem(), constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...1)])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        guard applies(to: dataSet) else { return .init() }
        let attributes = DicomAttributeValidator.evaluate(dataSet, rules: rules(for: dataSet), limits: limits)
        var report = attributes.report.limitingDiagnostics(to: limits.maximumDiagnostics)
        guard !report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }),
              let acquisition = dataSet[0x00189362]?.sequenceItems.first?.dataSet else { return report }
        var diagnostics: [DicomValidationReport.Diagnostic] = []
        let base: [DicomValidationReport.PathComponent] = [.tag(0x00189362), .item(0)]
        func indexes(_ tag: Int, _ field: Int) -> [Int?] {
            (acquisition[tag]?.sequenceItems ?? []).map { $0.dataSet[field]?.intValue }
        }
        func record(_ code: DicomValidationReport.Code, _ path: [DicomValidationReport.PathComponent]) {
            diagnostics.append(.init(code: code, severity: .error, layer: .attributes, path: base + path))
        }
        // Source and detector indexes count from 1 in item order; paths and details reference them.
        let sources = indexes(0x00189365, 0x00189366), detectors = indexes(0x0018936F, 0x00189370)
        for (sequence, values) in [(0x00189365, sources), (0x0018936F, detectors)] {
            for (index, value) in values.enumerated() where value != nil && value != index + 1 {
                record(.attributeValueContradiction, [.tag(sequence), .item(index), .tag(sequence == 0x00189365 ? 0x00189366 : 0x00189370)])
            }
        }
        let paths = indexes(0x00189379, 0x0018937A)
        for (index, item) in (acquisition[0x00189379]?.sequenceItems ?? []).enumerated() {
            if let value = paths[index], value != index + 1 { record(.attributeValueContradiction, [.tag(0x00189379), .item(index), .tag(0x0018937A)]) }
            if let source = item.dataSet[0x00189377]?.intValue, !sources.contains(source) {
                record(.referenceEvidenceMissing, [.tag(0x00189379), .item(index), .tag(0x00189377)])
            }
            if let detector = item.dataSet[0x00189376]?.intValue, !detectors.contains(detector) {
                record(.referenceEvidenceMissing, [.tag(0x00189379), .item(index), .tag(0x00189376)])
            }
        }
        for (sequence, field, known) in [(0x00189321, 0x00189377, sources), (0x00189325, 0x00189378, paths),
                                         (0x00189304, 0x00189378, paths), (0x00189312, 0x00189378, paths)] {
            for (index, item) in (acquisition[sequence]?.sequenceItems ?? []).enumerated() {
                if let value = item.dataSet[field]?.intValue, !known.contains(value) {
                    record(.referenceEvidenceMissing, [.tag(sequence), .item(index), .tag(field)])
                }
            }
        }
        let available = limits.maximumDiagnostics - report.diagnostics.count
        if diagnostics.count > available {
            diagnostics = Array(diagnostics.prefix(max(0, available - 1)))
                + [.init(code: .evaluationLimitReached, severity: .limitation, layer: .attributes, path: base)]
        }
        report = report.merging(.init(diagnostics: diagnostics)).limitingDiagnostics(to: limits.maximumDiagnostics)
        return report
    }

    private static func components(_ element: DicomDataElement?) -> [String]? {
        guard let element, element.vr == .CS, case .strings(let values) = element.value else { return nil }
        return values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
    }

    /// Energy Weighting Factor is required when a Derivation Code item is (113097, DCM).
    private static func proportionalWeighting(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let items = dataSet[0x00089215]?.sequenceItems else { return .unsatisfied }
        var unknown = false
        for item in items {
            guard let scheme = item.dataSet.string(for: 0x00080102), let code = item.dataSet.string(for: 0x00080100) else { unknown = true; continue }
            if scheme.trimmingCharacters(in: CharacterSet(charactersIn: " ")) == "DCM",
               code.trimmingCharacters(in: CharacterSet(charactersIn: " ")) == "113097" { return .satisfied }
        }
        return unknown ? .undetermined : .unsatisfied
    }
}
