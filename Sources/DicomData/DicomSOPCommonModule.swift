import Foundation

/// C.12.1 SOP Common attributes and included macros. Specific Character Set is proven by the wire
/// layer, which decodes every text value against the declared sets; digital signatures are
/// structurally checked but not cryptographically verified.
public enum DicomSOPCommonModule {
    public static func rules(for dataSet: DicomDataSet) -> [DicomAttributeRule] {
        [0x00080016, 0x00080018].map {
            .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1)])
        } + additionalRules(for: dataSet)
    }

    public static func validate(_ dataSet: DicomDataSet,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        evaluate(dataSet, rules: rules(for: dataSet), limits: limits)
    }

    private static func additionalRules(for dataSet: DicomDataSet) -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        let sop = DicomCommonMacros.sopInstanceReference()
        var rules: [DicomAttributeRule] = [
            .init(tag: 0x0008001C, requirement: .type3, constraints: [.strings(["YES", "NO"])]),
            .init(tag: 0x01000410, requirement: .type3, constraints: [.strings(["NS", "OR", "AO", "AC"])]),
            .init(tag: 0x00280303, requirement: .type3, constraints: [.strings(["UNMODIFIED", "MODIFIED", "REMOVED"])]),
            .init(tag: 0x00189004, requirement: .type3, constraints: [.strings(["PRODUCT", "RESEARCH", "SERVICE"])]),
            .init(tag: 0x04000600, requirement: .type3, constraints: [.strings(["LOCAL", "IMPORTED"])]),
            .init(tag: 0x00080201, requirement: .type3, constraints: [.requiredCondition(.known(timezone(dataSet[0x00080201])))]),
            .init(tag: 0x00080110, requirement: .type3, itemRules: [
                .init(tag: 0x00080102, requirement: .type1),
                .init(tag: 0x00080112, requirement: .type1C, condition: .undetermined),
                .init(tag: 0x0008010C, requirement: .type1C, condition: .undetermined),
                // Registration is evidenced by the registry attribute itself; a UID replaces the external ID.
                .init(tag: 0x00080114, requirement: .type2C,
                      condition: .all([.present(0x00080112), .not(.present(0x0008010C))])),
                .init(tag: 0x00080109, requirement: .type3, itemRules: [
                    .init(tag: 0x0008010A, requirement: .type1), // Defined Terms, not a closed enumeration.
                    .init(tag: 0x0008010E, requirement: .type1)
                ], constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00080123, requirement: .type3, itemRules: [
                .init(tag: 0x0008010F, requirement: .type1),
                .init(tag: 0x00080105, requirement: .type1),
                .init(tag: 0x00080106, requirement: .type1)
            ], constraints: [.itemCount(1...Int.max), .requiredCondition(.undetermined)]),
            .init(tag: 0x00080124, requirement: .type3, itemRules: [
                .init(tag: 0x00080105, requirement: .type1)
            ], constraints: [.itemCount(1...Int.max), .requiredCondition(.undetermined)]),
            .init(tag: 0x0008001D, requirement: .type3, itemRules: codes,
                  constraints: [.itemCount(1...Int.max), .requiredCondition(.undetermined)]),
            .init(tag: 0x0018A001, requirement: .type3, itemRules: [
                .init(tag: 0x00080070, requirement: .type1),
                .init(tag: 0x0040A170, requirement: .type1, itemRules: codes,
                      constraints: [.itemCount(1...1), .requiredCondition(.undetermined)]),
                .init(tag: 0x00081041, requirement: .type3, itemRules: codes,
                      constraints: [.itemCount(1...1), .requiredCondition(.undetermined)]),
                .init(tag: 0x00081072, requirement: .type3, itemRules: DicomPersonIdentificationMacro.rules(),
                      constraints: [.itemCount(1...Int.max), .personIdentificationNames(0x00081070, whenMultipleItems: false)]),
                .init(tag: 0x0018100A, requirement: .type3, itemRules: DicomCommonMacros.udi(), constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...Int.max)]),
            // C.12.1.1.9-1 Original Attributes, C.12-6 signatures and private element characteristics.
            .init(tag: 0x04000561, requirement: .type3, itemRules: [
                .init(tag: 0x04000550, requirement: .type1),
                .init(tag: 0x04000551, requirement: .type3, itemRules: [.init(tag: 0x04000552, requirement: .type1)]
                    + DicomCommonMacros.attributeIdentifier(), constraints: [.itemCount(1...Int.max)]),
                .init(tag: 0x04000562, requirement: .type1), .init(tag: 0x04000563, requirement: .type1),
                .init(tag: 0x04000564, requirement: .type2), .init(tag: 0x04000565, requirement: .type1)
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x4FFE0001, requirement: .type3, itemRules: [0x04000005, 0x04000010, 0x04000015, 0x04000020].map {
                .init(tag: $0, requirement: .type1)
            }, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0xFFFAFFFA, requirement: .type3, itemRules: [0x04000005, 0x04000100, 0x04000105, 0x04000110,
                0x04000115, 0x04000120].map { .init(tag: $0, requirement: .type1) } + [
                .init(tag: 0x04000305, requirement: .type1C, condition: .present(0x04000310)),
                .init(tag: 0x04000401, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00080300, requirement: .type3, itemRules: [
                .init(tag: 0x00080301, requirement: .type1), .init(tag: 0x00080302, requirement: .type1),
                .init(tag: 0x00080303, requirement: .type1, constraints: [.strings(["SAFE", "UNSAFE", "MIXED"])]),
                .init(tag: 0x00080304, requirement: .type1C, condition: .stringEquals(0x00080303, "MIXED"), mayBePresentOtherwise: true),
                .init(tag: 0x00080305, requirement: .type3, itemRules: [.init(tag: 0x00080306, requirement: .type1),
                    .init(tag: 0x00080307, requirement: .type1)], constraints: [.itemCount(1...Int.max)]),
                .init(tag: 0x00080310, requirement: .type3, itemRules: [0x00080308, 0x00080309, 0x0008030A, 0x0008030C, 0x0008030D].map {
                    .init(tag: $0, requirement: .type1)
                } + [.init(tag: 0x0008030B, requirement: .type1C, condition: .stringEquals(0x0008030A, "SQ"), mayBePresentOtherwise: true)],
                      constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...Int.max)])
        ]
        // Conditional structures whose conditions are only evidenced by their own presence.
        if dataSet.contains(0x00209172) {
            rules.append(.init(tag: 0x00209172, requirement: .type1C, condition: .present(0x00209172),
                               itemRules: DicomCommonMacros.imageSOPInstanceReference(), constraints: [.itemCount(1...1)]))
        }
        if dataSet.contains(0x0040A390) {
            rules.append(.init(tag: 0x0040A390, requirement: .type1C, condition: .present(0x0040A390), itemRules: sop + [
                .init(tag: 0x0040E001, requirement: .type1), .init(tag: 0x0040E010, requirement: .type3)
            ], constraints: [.itemCount(1...Int.max)]))
        }
        if dataSet.contains(0x04000500) {
            rules.append(.init(tag: 0x04000500, requirement: .type1C, condition: .present(0x04000500), itemRules: [
                .init(tag: 0x04000510, requirement: .type1), .init(tag: 0x04000520, requirement: .type1)
            ], constraints: [.itemCount(1...Int.max)]))
        }
        for tag in [0x0018990C, 0x0018990D] where dataSet.contains(tag) {
            rules.append(.init(tag: tag, requirement: .type1C, condition: .present(tag), itemRules: sop + [
                .init(tag: 0x00189938, requirement: .type3), .init(tag: 0x0018993A, requirement: .type3)
            ], constraints: [.itemCount(1...Int.max)]))
        }
        if dataSet.contains(0x00080053) {
            rules.append(.init(tag: 0x00080053, requirement: .type1C, condition: .undetermined,
                               constraints: [.strings(["CLASSIC", "ENHANCED"])]))
        }
        return rules
    }

    private static func evaluate(_ dataSet: DicomDataSet, rules: [DicomAttributeRule],
                                 limits: DicomAttributeValidator.Limits) -> DicomValidationReport {
        let attributes = DicomAttributeValidator.evaluate(dataSet, rules: rules, limits: limits)
        var report = attributes.report
        guard !report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else { return report }
        // Signature and MAC structures are checked above; cryptographic verification is a separate operation.
        if dataSet.contains(0xFFFAFFFA) {
            guard attributes.evaluations < limits.maximumRuleEvaluations, report.diagnostics.count < limits.maximumDiagnostics else {
                return report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached, severity: .limitation,
                    layer: .attributes, path: [.tag(0xFFFAFFFA)])]))
            }
            report = report.merging(.init(diagnostics: [.init(code: .semanticScopeUnavailable, severity: .limitation,
                layer: .attributes, path: [.tag(0xFFFAFFFA)])]))
        }
        return report
    }

    private static func timezone(_ element: DicomDataElement?) -> DicomAttributeRule.Truth {
        guard let element, element.vr == .SH else { return .undetermined }
        if case .empty = element.value { return .satisfied }
        guard case .strings(let values) = element.value else { return .undetermined }
        guard values.count == 1 else { return .unsatisfied }
        if values.allSatisfy({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty }) { return .satisfied }
        let value = values[0]
        guard value.utf8.count <= 16 else { return .unsatisfied }
        let trimmed = value.replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression)
        guard trimmed.utf8.count == 5, trimmed.first == "+" || trimmed.first == "-" else { return .unsatisfied }
        // C.12.1.1.8 uses the same suffix grammar as DT, including +0000 and the UTC range.
        return DicomTemporalValueValidator.valid("20000101" + trimmed, vr: .DT, query: false) ? .satisfied : .unsatisfied
    }
}
