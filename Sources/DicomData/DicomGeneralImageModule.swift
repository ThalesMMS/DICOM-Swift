import Foundation

/// C.7.6.1 for classic CT/MR/SC and the Segmentation/Parametric Map objects. Anatomy, physical
/// orientation and source-history evidence are separate from these attribute and icon checks.
public enum DicomGeneralImageModule {
    public static func rules(for dataSet: DicomDataSet, kind: DicomCompositeImageModules.Kind,
                             temporallyRelatedSeries: DicomAttributeRule.Truth = .undetermined,
                             hasPixelData: DicomAttributeRule.Truth = .undetermined,
                             hasFloatPixelData: DicomAttributeRule.Truth = .unsatisfied) -> [DicomAttributeRule] {
        rules(for: dataSet, kind: kind, temporallyRelatedSeries: temporallyRelatedSeries, hasPixelData: hasPixelData,
              hasFloatPixelData: hasFloatPixelData, maximumComponents: DicomAttributeValidator.Limits().maximumRuleEvaluations)
    }

    private static func rules(for dataSet: DicomDataSet, kind: DicomCompositeImageModules.Kind,
                              temporallyRelatedSeries: DicomAttributeRule.Truth, hasPixelData: DicomAttributeRule.Truth,
                              hasFloatPixelData: DicomAttributeRule.Truth, maximumComponents: Int) -> [DicomAttributeRule] {
        let needsOrientation = kind.isSecondaryCapture && ![0x00200032, 0x00200037].contains(where: dataSet.contains)
        let codes = DicomCodeSequenceMacro.standardRules()
        return [
            .init(tag: 0x00200013, requirement: .type2),
            // The classic CT/MR/SC IODs contain one frame, even if an extension declares a frame count;
            // the multi-frame SC and functional group IODs take their count from their multi-frame modules.
            .init(tag: 0x00280008, requirement: .type3,
                  constraints: [.valueCount(0...1), .integerRange(1...(kind == .secondaryCaptureMultiframe || kind.usesFunctionalGroups || kind == .rtDose ? Int.max : 1))]),
            .init(tag: 0x00200020, requirement: .type2C, condition: .known(needsOrientation ? .satisfied : .unsatisfied),
                  mayBePresentOtherwise: true, constraints: [.requiredCondition(.known(patientOrientation(in: dataSet)))]),
            .init(tag: 0x00080023, requirement: .type2C, condition: .known(temporallyRelatedSeries), mayBePresentOtherwise: true),
            .init(tag: 0x00080033, requirement: .type2C, condition: .known(temporallyRelatedSeries), mayBePresentOtherwise: true),
            .init(tag: 0x00080008, requirement: .type3, constraints: [.requiredCondition(.known(imageType(in: dataSet, maximumComponents: maximumComponents)))]),
            .init(tag: 0x00280300, requirement: .type3, constraints: [.strings(["YES", "NO", "BOTH"])]),
            .init(tag: 0x00280301, requirement: .type3, constraints: [.strings(["YES", "NO"])]),
            .init(tag: 0x00280302, requirement: .type3, constraints: [.strings(["YES", "NO"])]),
            .init(tag: 0x00282110, requirement: .type3, constraints: [.strings(["00", "01"])]),
            .init(tag: 0x00282112, requirement: .type3,
                  constraints: [.requiredCondition(.known(compressionRatioCount(in: dataSet, maximumComponents: maximumComponents)))]),
            .init(tag: 0x20500020, requirement: .type3,
                  constraints: [.strings(["IDENTITY", "INVERSE"]), .requiredCondition(.known(presentationShape(in: dataSet)))]),
            .init(tag: 0x00880200, requirement: .type3,
                  constraints: [.itemCount(1...1)]),
            // Tables 10-7/10-8 anatomy and the C.7.6.16-12b real-world mapping macro; classic images
            // carry no float pixel alternative.
            .init(tag: 0x00082218, requirement: .type3, itemRules: codes + [
                .init(tag: 0x00082220, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...1)]),
            .init(tag: 0x00082228, requirement: .type3, itemRules: codes + [
                .init(tag: 0x00082230, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00409096, requirement: .type3,
                  itemRules: DicomCommonMacros.realWorldValueMapping(hasPixelData: hasPixelData, hasFloatPixelData: hasFloatPixelData),
                  constraints: [.itemCount(1...Int.max)])
        ]
    }

    public static func validate(_ dataSet: DicomDataSet, kind: DicomCompositeImageModules.Kind,
                                temporallyRelatedSeries: DicomAttributeRule.Truth = .undetermined,
                                hasPixelData: DicomAttributeRule.Truth = .undetermined,
                                hasFloatPixelData: DicomAttributeRule.Truth = .unsatisfied,
                                iconPixelDataSource: DicomSRIconImageValidator.PixelDataSource = .omitted,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var remaining = limits.maximumRuleEvaluations
        // Reserve all components before deriving conditions, including optional empty values.
        for tag in [0x00080008, 0x00282112, 0x00282114] {
            if case .strings(let values) = dataSet[tag]?.value {
                guard values.count <= remaining else {
                    return .init(diagnostics: [.init(code: .evaluationLimitReached, severity: .limitation,
                        layer: .attributes, path: [.tag(tag)])])
                }
                remaining -= values.count
            }
        }
        let attributes = DicomAttributeValidator.evaluate(dataSet,
            rules: rules(for: dataSet, kind: kind, temporallyRelatedSeries: temporallyRelatedSeries,
                         hasPixelData: hasPixelData, hasFloatPixelData: hasFloatPixelData, maximumComponents: limits.maximumRuleEvaluations),
            limits: .init(maximumDepth: limits.maximumDepth, maximumRuleEvaluations: remaining,
                          maximumDiagnostics: limits.maximumDiagnostics))
        var report = attributes.report
        guard !report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else { return report }
        remaining -= attributes.evaluations
        func add(_ code: DicomValidationReport.Code, tag: Int, layer: DicomValidationReport.Layer = .attributes,
                 severity: DicomValidationReport.Severity = .limitation) -> Bool {
            guard remaining > 0, report.diagnostics.count < limits.maximumDiagnostics else {
                report = report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached,
                    severity: .limitation, layer: layer, path: [.tag(tag)])]))
                return false
            }
            remaining -= 1
            report = report.merging(.init(diagnostics: [.init(code: code, severity: severity, layer: layer, path: [.tag(tag)])]))
            return true
        }
        // C.7.6.1.1.1: Patient Orientation shall be consistent with the direction cosines when both are present.
        if dataSet.contains(0x00200037), let values = text(dataSet[0x00200020]), !values.isEmpty {
            switch orientationAgreement(values, in: dataSet) {
            case .satisfied: break
            case .unsatisfied: guard add(.attributeValueContradiction, tag: 0x00200020, severity: .error) else { return report }
            case .undetermined: guard add(.valueUnavailable, tag: 0x00200020) else { return report }
            }
        }
        if let element = dataSet[0x00880200], element.vr == .SQ, case .sequence(let items) = element.value, items.count == 1 {
            guard limits.maximumDepth > 0, remaining > 0, report.diagnostics.count < limits.maximumDiagnostics else {
                return report.merging(.init(diagnostics: [DicomValidationReport.Layer.attributes, .pixelsAndGeometry].map {
                    .init(code: .evaluationLimitReached, severity: .limitation, layer: $0, path: [.tag(0x00880200)])
                }))
            }
            let icon = DicomSRIconImageValidator.validate(items[0].dataSet, pixelDataSource: iconPixelDataSource,
                kind: .generalImage, limits: .init(maximumDepth: max(0, limits.maximumDepth - 1),
                    maximumRuleEvaluations: remaining, maximumDiagnostics: limits.maximumDiagnostics - report.diagnostics.count))
            report = report.merging(.init(evaluatedLayers: icon.evaluatedLayers, diagnostics: icon.diagnostics.map {
                .init(code: $0.code, severity: $0.severity, layer: $0.layer,
                      path: [.tag(0x00880200), .item(0)] + $0.path, requirement: $0.requirement)
            }))
        }
        return report
    }

    private static func text(_ element: DicomDataElement?) -> [String]? {
        guard let element, element.vr == .CS else { return nil }
        if case .empty = element.value { return [] }
        guard case .strings(let values) = element.value, values.count <= 2,
              values.allSatisfy({ $0.utf8.count <= 16 }) else { return nil }
        let trimmed = values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
        return trimmed.allSatisfy(\.isEmpty) ? [] : trimmed
    }

    private static func imageType(in dataSet: DicomDataSet, maximumComponents: Int) -> DicomAttributeRule.Truth {
        guard let element = dataSet[0x00080008], element.vr == .CS else { return .undetermined }
        if case .empty = element.value { return .satisfied }
        guard case .strings(let values) = element.value, values.count <= maximumComponents else { return .undetermined }
        if values.allSatisfy({ $0.utf8.count <= 16 && $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty }) { return .satisfied }
        guard values.count >= 2, values[0].utf8.count <= 16, values[1].utf8.count <= 16 else { return .unsatisfied }
        let first = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let second = values[1].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return ["ORIGINAL", "DERIVED"].contains(first) && ["PRIMARY", "SECONDARY"].contains(second) ? .satisfied : .unsatisfied
    }

    private static func patientOrientation(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let values = text(dataSet[0x00200020]) else { return .undetermined }
        if values.isEmpty { return .satisfied }
        guard values.count == 2 else { return .unsatisfied }
        let anatomy = dataSet.contains(0x00102210) ? text(dataSet[0x00102210]) : ["BIPED"]
        guard let anatomy, anatomy.count == 1, ["BIPED", "QUADRUPED"].contains(anatomy[0]) else { return .undetermined }
        let terms: Set<String> = anatomy[0] == "BIPED" ? ["A", "P", "R", "L", "H", "F"] :
            ["LE", "RT", "D", "V", "CR", "CD", "R", "M", "L", "PR", "DI", "PA", "PL"]
        for value in values {
            var suffix = value[...]
            var count = 0
            while !suffix.isEmpty {
                let pair = String(suffix.prefix(2))
                let term = terms.contains(pair) ? pair : String(suffix.prefix(1))
                guard count < 3, terms.contains(term) else { return .unsatisfied }
                suffix.removeFirst(term.count)
                count += 1
            }
            guard count > 0 else { return .unsatisfied }
        }
        return .satisfied
    }

    /// Expected direction letters, from the largest cosine component downward; a value must be a
    /// prefix of that sequence. Quadruped axes depend on the body part and stay undetermined.
    private static func orientationAgreement(_ values: [String], in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        if dataSet.contains(0x00102210), text(dataSet[0x00102210]) != ["BIPED"] { return .undetermined }
        guard values.count == 2, let element = dataSet[0x00200037], element.vr == .DS,
              case .strings(let strings) = element.value, strings.count == 6,
              let cosines = try? strings.map({ try DicomDecimalString.parse($0, vr: .DS) }) else { return .undetermined }
        let letters = [("L", "R"), ("P", "A"), ("H", "F")]
        for (value, vector) in zip(values, [Array(cosines.prefix(3)), Array(cosines.suffix(3))]) {
            let ranked = vector.enumerated().filter { $0.element != 0 }
                .sorted { ($0.element < 0 ? -$0.element : $0.element) > ($1.element < 0 ? -$1.element : $1.element) }
            let magnitudes = ranked.map { $0.element < 0 ? -$0.element : $0.element }
            guard !ranked.isEmpty, Set(magnitudes).count == magnitudes.count else { return .undetermined }
            let expected = ranked.map { $0.element > 0 ? letters[$0.offset].0 : letters[$0.offset].1 }.joined()
            guard value.count <= expected.count, expected.hasPrefix(value) else { return .unsatisfied }
        }
        return .satisfied
    }

    private static func presentationShape(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let shape = text(dataSet[0x20500020]) else { return .undetermined }
        if shape.isEmpty { return .satisfied }
        guard let photo = text(dataSet[0x00280004]), shape.count == 1, photo.count == 1 else { return .undetermined }
        let identity = ["MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL", "YBR_FULL_422", "YBR_PARTIAL_422", "YBR_PARTIAL_420", "YBR_ICT", "YBR_RCT"]
        guard photo[0] == "MONOCHROME1" || identity.contains(photo[0]) else { return .undetermined }
        return shape[0] == (photo[0] == "MONOCHROME1" ? "INVERSE" : "IDENTITY") ? .satisfied : .unsatisfied
    }

    private static func compressionRatioCount(in dataSet: DicomDataSet, maximumComponents: Int) -> DicomAttributeRule.Truth {
        guard let ratio = dataSet[0x00282112], let method = dataSet[0x00282114] else { return .satisfied }
        guard ratio.vr == .DS, method.vr == .CS else { return .undetermined }
        guard ratio.vm.count <= maximumComponents, method.vm.count <= maximumComponents else { return .undetermined }
        if ratio.vm.count == 0 || method.vm.count == 0 { return .satisfied }
        for element in [ratio, method] {
            if case .strings(let values) = element.value,
               values.allSatisfy({ $0.utf8.count <= 16 && $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty }) { return .satisfied }
        }
        return ratio.vm.count == method.vm.count ? .satisfied : .unsatisfied
    }
}
