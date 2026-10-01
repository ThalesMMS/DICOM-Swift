import Foundation

/// Ultrasound Image (.6.1): C.8.5.6, optional C.8.5.5 and the conditional C.7.9 palette.
/// Reuses the generated PS3.3 2026c tables and common macros; acquisition facts remain tri-state.
public enum DicomUltrasoundModules {
    static let sopClassUID = "1.2.840.10008.5.1.4.1.1.6.1"
    typealias Rule = DicomAttributeRule
    typealias Condition = DicomAttributeRule.Condition

    public static func validate(_ dataSet: DicomDataSet, transferSyntax: DicomTransferSyntax,
                                pixelData: DicomEnhancedImageModules.PixelData,
                                conditions: DicomCompositeImageModules.Conditions = .init(),
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let context = DicomEnhancedImageTableRules.Context(root: dataSet, sopClassUID: sopClassUID,
            shared: nil, frame: nil, frames: [], facts: conditions, pixelData: pixelData)
        var rules = DicomEnhancedImageTableRules.rules(table: "C.8.5.6", context: context)
        // C.7.9 supplies the palette alternatives; C.8.5.6 specializes the root pixel attributes.
        rules += DicomEnhancedImageTableRules.rules(table: "C.7.6.3", context: context).filter {
            ![0x00280034, 0x00281101, 0x00281102, 0x00281103, 0x00281201, 0x00281202, 0x00281203].contains($0.tag)
        }
        let hasSpacing = [0x00280030, 0x00181164, 0x00182010].contains(where: dataSet.contains)
        let aspect = dataSet[0x00280034]?.stringValues.compactMap(Int.init)
        let nonSquare = aspect?.count == 2 ? (aspect?[0] != aspect?[1] ? Rule.Truth.satisfied : .unsatisfied)
            : conditions.nonSquarePixels
        rules.append(.init(tag: 0x00280034, requirement: .type1C,
            condition: .known(hasSpacing ? .unsatisfied : nonSquare),
            constraints: [.valueCount(2...2), .integerRange(1...Int.max)]))
        // A.6: an absent Contrast/Bolus module does not prove that no contrast was used.
        if !DicomContrastBolusModule.applies(to: dataSet) {
            rules.append(.init(tag: 0x00180010, requirement: .type2C, condition: .known(conditions.contrastMediaUsed)))
        }
        if dataSet.contains(0x00186011) {
            rules += DicomEnhancedImageTableRules.rules(table: "C.8.5.5", context: context)
        }
        if dataSet.string(for: 0x00280004) == "PALETTE COLOR"
            || DicomEnhancedImageTableRules.topLevelTags("C.7.9").contains(where: dataSet.contains) {
            rules += DicomEnhancedImageTableRules.rules(table: "C.7.9", context: context)
        }
        rules += pixelSpecializations(dataSet, transferSyntax: transferSyntax)
        let evaluated = DicomAttributeValidator.evaluate(dataSet, rules: rules, limits: limits)
        var report = evaluated.report
        if pixelData != .integer {
            report = report.merging(.init(diagnostics: [.init(code: pixelData == .undetermined ? .valueUnavailable : .requiredAttributeMissing,
                severity: pixelData == .undetermined ? .limitation : .error, layer: .attributes, path: [.tag(0x7FE00010)])]))
        }
        guard !report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else { return report }
        return report.merging(validateRegionTables(dataSet, remaining: limits.maximumRuleEvaluations - evaluated.evaluations,
            maximumDiagnostics: max(1, limits.maximumDiagnostics - report.diagnostics.count)))
    }

    static func condition(table: String, tag: Int, context: DicomEnhancedImageTableRules.Context) -> Condition? {
        if table == "C.8.5.6" {
            switch tag {
            case 0x00280006: return .integerGreaterThan(0x00280002, 1)
            case 0x00280009: return .present(0x00280008)
            case 0x00282110:
                return .known(context.rootValue(tag).map { $0 == "00" ? .unsatisfied : .satisfied } ?? .undetermined)
            case 0x00082124, 0x0008212A:
                let declared = [0x00082120, 0x00082122, 0x00082124, 0x00082127, 0x00082128, 0x0008212A, 0x0040000A]
                    .contains(where: context.root.contains)
                return .known(context.facts.ultrasoundStagedProtocol == .undetermined && declared
                    ? .satisfied : context.facts.ultrasoundStagedProtocol)
            case 0x0008002A, 0x00183100: return .stringEquals(0x00080060, "IVUS")
            case 0x00183101: return .all([.present(0x00183100), .stringEquals(0x00183100, "MOTOR_PULLBACK")])
            case 0x00183102: return .all([.present(0x00183100), .stringEquals(0x00183100, "GATED_PULLBACK")])
            case 0x00183103, 0x00183104:
                return .all([.present(0x00183100), .any([.stringEquals(0x00183100, "MOTOR_PULLBACK"),
                    .stringEquals(0x00183100, "GATED_PULLBACK")])])
            default: return nil
            }
        }
        guard table == "C.8.5.5" else { return nil }
        func organization(_ values: [Int]) -> Condition {
            .all([.present(0x00186044), .any(values.map { value in
                .all([.integerGreaterThan(0x00186044, value - 1), .not(.integerGreaterThan(0x00186044, value))])
            })])
        }
        switch tag {
        // C.8.5.5.1.4 explicitly defines absence as no pixel component calibration.
        case 0x00186044, 0x0018604C, 0x0018604E: return .present(0x00186044)
        case 0x00186046: return organization([0])
        case 0x00186048, 0x0018604A: return organization([1])
        case 0x00186050, 0x00186052, 0x00186054: return organization([0, 1])
        case 0x00186056: return organization([2, 3])
        // C.8.5.5.1.12/.17 also require pixel values for code lookup, despite the table's Type 1C text naming only 2.
        case 0x00186058: return organization([2, 3])
        case 0x0018605A: return organization([2])
        case 0x00409098: return organization([3])
        default: return nil
        }
    }

    static func constraints(table: String, tag: Int) -> [Rule.Constraint] {
        if table == "C.8.5.6" {
            switch tag {
            case 0x00282110: return [.strings(["00", "01"])]
            case 0x00280014: return [.integers([0, 1])]
            case 0x00181080: return [.strings(["Y", "N"])]
            case 0x00082122, 0x00082124, 0x00082128, 0x0008212A, 0x00183103, 0x00183104:
                return [.integerRange(1...Int.max)]
            default: return []
            }
        }
        guard table == "C.8.5.5" else { return [] }
        switch tag {
        case 0x00186012: return [.integerRange(0...5)]
        case 0x00186014: return [.integers(Set(0...18).subtracting([9]))]
        case 0x00186016: return [.integerRange(0...31)]
        case 0x00186024, 0x00186026, 0x0018604C: return [.integerRange(0...12)]
        case 0x00186044: return [.integerRange(0...3)]
        case 0x0018604E: return [.integerRange(0...10)]
        case 0x00186050, 0x00186056: return [.integerRange(1...Int.max)]
        case 0x00186048: return [.integerLessThanOrEqualAttribute(0x0018604A)]
        default: return []
        }
    }

    private static func pixelSpecializations(_ dataSet: DicomDataSet, transferSyntax: DicomTransferSyntax) -> [Rule] {
        let photo = dataSet.string(for: 0x00280004)
        let palette = photo == "PALETTE COLOR"
        var rules: [Rule] = [
            .init(tag: 0x00280002, requirement: .type1, constraints: [.integers(photo == "MONOCHROME2" || palette ? [1] : [3])]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.integers(palette ? [8, 16] : [8])]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280100, offset: 0)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.integers([0])])
        ]
        let encoding = transferSyntax.registryEntry
        if dataSet.int(for: 0x00280002) == 3 {
            let allowed: Set<String>
            switch encoding.codec {
            case .rle: allowed = ["RGB", "YBR_FULL"]
            case .jpegBaseline, .jpegExtended: allowed = ["YBR_FULL_422"]
            case .jpeg2000, .jpeg2000Part2, .htj2k: allowed = [encoding.compression.isLossy ? "YBR_ICT" : "YBR_RCT"]
            case .mpeg2, .h264, .hevc: allowed = ["YBR_PARTIAL_420"]
            default: allowed = ["RGB"]
            }
            rules.append(.init(tag: 0x00280004, requirement: .type1, constraints: [.strings(allowed)]))
            rules.append(.init(tag: 0x00280006, requirement: .type1,
                constraints: [.integers(photo == "RGB" ? [0, 1] : photo == "YBR_FULL" && encoding.codec == .rle ? [1] : [0])]))
        }
        if encoding.compression.isLossy {
            rules.append(.init(tag: 0x00282110, requirement: .type1, constraints: [.strings(["01"])]))
        }
        return rules
    }

    private static func validateRegionTables(_ dataSet: DicomDataSet, remaining: Int,
                                             maximumDiagnostics: Int) -> DicomValidationReport {
        var diagnostics: [DicomValidationReport.Diagnostic] = []
        var budget = remaining
        for (index, item) in (dataSet[0x00186011]?.sequenceItems ?? []).enumerated() {
            let region = item.dataSet
            let path: [DicomValidationReport.PathComponent] = [.tag(0x00186011), .item(index)]
            let tags = [0x00186052, 0x00186054, 0x00186058, 0x0018605A, 0x00409098]
            let cost = 1 + tags.reduce(0) { $0 + max(region[$1]?.vm.count ?? 0, region[$1]?.sequenceItems.count ?? 0) }
            guard cost <= budget, diagnostics.count < maximumDiagnostics else {
                diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .attributes, path: path))
                break
            }
            budget -= cost
            for (table, count) in [(0x00186052, 0x00186050), (0x00186054, 0x00186050),
                                  (0x00186058, 0x00186056), (0x0018605A, 0x00186056), (0x00409098, 0x00186056)] {
                guard let element = region[table], let expected = region[count]?.intValue else { continue }
                let actual = element.vr == .SQ ? element.sequenceItems.count : element.vm.count
                if actual != expected {
                    diagnostics.append(.init(code: .attributeValueContradiction, severity: .error, layer: .attributes,
                        path: path + [.tag(table)]))
                }
            }
        }
        return .init(evaluatedLayers: [.attributes], diagnostics: diagnostics)
    }
}
