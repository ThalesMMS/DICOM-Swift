import Foundation

/// C.7.6.16 root attributes of Multi-frame Functional Groups, C.7.6.17 Multi-frame Dimension and
/// C.12.3 Frame Extraction, shared by the multi-frame SC and Enhanced image compositions.
/// Functional group macro content is composed by the IOD-specific helpers.
public enum DicomFunctionalGroupsModule {
    public static func frameCount(in dataSet: DicomDataSet) -> Int? {
        guard let element = dataSet[0x00280008], element.vr == .IS, element.vm.count == 1, let value = element.intValue, value > 0 else { return nil }
        return value
    }

    public static func rootRules(frames: Int?) -> [DicomAttributeRule] {
        let concatenated = DicomAttributeRule.Condition.present(0x00209161)
        // Membership in a concatenation is evidenced by any of its identifiers; none present means none.
        let concatenationEvidence = DicomAttributeRule.Condition.any([0x00209161, 0x00209162, 0x00200242, 0x00209228].map { .present($0) })
        return [
            .init(tag: 0x00080023, requirement: .type1), .init(tag: 0x00080033, requirement: .type1),
            .init(tag: 0x00200013, requirement: .type1),
            .init(tag: 0x00209161, requirement: .type1C, condition: concatenationEvidence),
            .init(tag: 0x00200242, requirement: .type1C, condition: concatenated, mayBePresentOtherwise: true),
            .init(tag: 0x00209162, requirement: .type1C, condition: concatenated, mayBePresentOtherwise: true),
            .init(tag: 0x00209228, requirement: .type1C, condition: concatenated, mayBePresentOtherwise: true),
            .init(tag: 0x52009229, requirement: .type1, constraints: [.itemCount(1...1)]),
            .init(tag: 0x52009230, requirement: .type1C, condition: DicomCommonMacros.selfEvidencing(0x52009230),
                  constraints: frames.map { [.itemCount($0...$0)] } ?? [])
        ]
    }

    public static func dimensionRules(for dataSet: DicomDataSet) -> [DicomAttributeRule] {
        let organization = dataSet[0x00209311]?.stringValues.first?.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let indexRequired: DicomAttributeRule.Truth = organization == nil ? .satisfied : organization == "TILED_FULL" ? .unsatisfied : .satisfied
        return [
            .init(tag: 0x00209221, requirement: .type1, itemRules: [.init(tag: 0x00209164, requirement: .type1)],
                  constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00209222, requirement: .type1C, condition: .known(indexRequired), mayBePresentOtherwise: true,
                  constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00209311, requirement: .type3, constraints: [.strings(["3D", "3D_TEMPORAL", "TILED_FULL", "TILED_SPARSE"])])
        ]
    }

    /// Per-item Dimension Index conditions: a private pointer needs its creator, and a pointer to an
    /// attribute that is not at the root of the instance needs its functional group pointer.
    public static func dimensionIndexRules(for item: DicomDataSet, root: DicomDataSet) -> [DicomAttributeRule] {
        func pointer(_ tag: Int) -> Int? {
            guard let element = item[tag], element.vr == .AT, case .unsignedIntegers(let values) = element.value, values.count == 1 else { return nil }
            return Int(values[0])
        }
        func isPrivate(_ tag: Int?) -> DicomAttributeRule.Truth {
            guard let tag else { return .undetermined }
            return (tag >> 16) & 1 == 1 ? .satisfied : .unsatisfied
        }
        let index = pointer(0x00209165)
        let inFunctionalGroup: DicomAttributeRule.Truth = item.contains(0x00209167) ? .satisfied
            : index.map { root.contains($0) ? .unsatisfied : .undetermined } ?? .undetermined
        return [
            .init(tag: 0x00209164, requirement: .type1), .init(tag: 0x00209165, requirement: .type1, constraints: [.valueCount(1...1)]),
            .init(tag: 0x00209167, requirement: .type1C, condition: .known(inFunctionalGroup)),
            .init(tag: 0x00209213, requirement: .type1C, condition: .known(isPrivate(index))),
            .init(tag: 0x00209238, requirement: .type1C,
                  condition: .known(item.contains(0x00209167) ? isPrivate(pointer(0x00209167)) : .unsatisfied))
        ]
    }

    /// C.12.3 is required only for frame-level retrieve results, which the sequence itself evidences.
    /// Exactly one retrieve list evidences the extraction kind; the other two are then not required.
    public static func frameExtractionRules() -> [DicomAttributeRule] {
        let lists = [0x00081161, 0x00081162, 0x00081163]
        func list(_ tag: Int) -> DicomAttributeRule {
            let others = lists.filter { $0 != tag }.map { DicomAttributeRule.Condition.not(.present($0)) }
            return .init(tag: tag, requirement: .type1C, condition: .any([.present(tag), .all(others + [.undetermined])]),
                         constraints: tag == 0x00081161 ? [.exactlyOnePresent(Set(lists))] : [])
        }
        return [.init(tag: 0x00081164, requirement: .type1C, condition: .present(0x00081164), itemRules: [
            .init(tag: 0x00081167, requirement: .type1, constraints: [.valueCount(1...1)])
        ] + lists.map(list), constraints: [.itemCount(1...Int.max)])]
    }

    /// Evaluates each Dimension Index item against its own pointer values, sharing the caller's budget.
    /// Returns false when the evaluation limit was reached.
    public static func validateDimensionIndexItems(in dataSet: DicomDataSet, report: inout DicomValidationReport,
                                                   remaining: inout Int, limits: DicomAttributeValidator.Limits) -> Bool {
        for (index, item) in (dataSet[0x00209222]?.sequenceItems ?? []).enumerated() {
            let path: [DicomValidationReport.PathComponent] = [.tag(0x00209222), .item(index)]
            guard remaining > 0, report.diagnostics.count < limits.maximumDiagnostics, limits.maximumDepth > 0 else {
                report = report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached, severity: .limitation, layer: .attributes, path: path)]))
                return false
            }
            let evaluated = DicomAttributeValidator.evaluate(item.dataSet, rules: dimensionIndexRules(for: item.dataSet, root: dataSet),
                limits: .init(maximumDepth: limits.maximumDepth - 1, maximumRuleEvaluations: remaining,
                              maximumDiagnostics: limits.maximumDiagnostics - report.diagnostics.count))
            remaining -= evaluated.evaluations
            report = report.merging(.init(diagnostics: evaluated.report.diagnostics.map {
                .init(code: $0.code, severity: $0.severity, layer: $0.layer, path: path + $0.path, requirement: $0.requirement)
            }))
            guard !evaluated.report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else { return false }
        }
        return true
    }
}
