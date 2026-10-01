import Foundation

/// C.12.2 hierarchy, supplied-target identity and completeness against the instances
/// referenced by the General Reference module of the same object. No targets are fetched;
/// whether an undeclared reference belongs to the current study stays undetermined.
public enum DicomCommonInstanceReferenceModule {
    static let generalReferenceTags = [0x00081140, 0x0008114A, 0x00082112, 0x00420013]

    public static func applies(to dataSet: DicomDataSet) -> Bool {
        dataSet.contains(0x00081115) || dataSet.contains(0x00081200)
    }

    /// The module's own conditions are triggered by references made elsewhere in the instance.
    public static func required(by dataSet: DicomDataSet) -> Bool {
        applies(to: dataSet) || generalReferenceTags.contains(where: dataSet.contains)
    }

    public static func validate(_ dataSet: DicomDataSet, targets: [String: DicomDataSet] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let series: [DicomAttributeRule] = [
            .init(tag: 0x0020000E, requirement: .type1),
            .init(tag: 0x0008114A, requirement: .type1, itemRules: DicomSRReferenceMacro.sopRules,
                  constraints: [.itemCount(1...Int.max)])
        ]
        // The hierarchy conditions depend on where the General Reference instances live: a
        // reference listed under the other hierarchy settles the absent one; unlisted references do not.
        let general = generalReferenceInstances(dataSet)
        let sameStudy = hierarchyInstances(dataSet[0x00081115])
        let otherStudies = Set(dataSet[0x00081200]?.sequenceItems.flatMap { hierarchyInstances($0.dataSet[0x00081115]) } ?? [])
        func condition(_ tag: Int, settledBy listed: Set<String>) -> DicomAttributeRule.Condition {
            if dataSet.contains(tag) { return .known(.satisfied) }
            return .known(general.allSatisfy(listed.contains) ? .unsatisfied : .undetermined)
        }
        let attributes = DicomAttributeValidator.evaluate(dataSet, rules: [
            .init(tag: 0x00081115, requirement: .type1C, condition: condition(0x00081115, settledBy: otherStudies),
                  itemRules: series, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00081200, requirement: .type1C, condition: condition(0x00081200, settledBy: sameStudy),
                  itemRules: [.init(tag: 0x0020000D, requirement: .type1),
                              .init(tag: 0x00081115, requirement: .type1, itemRules: series,
                                    constraints: [.itemCount(1...Int.max)])], constraints: [.itemCount(1...Int.max)])
        ], limits: limits)
        let remaining = limits.maximumRuleEvaluations - attributes.evaluations
        guard !attributes.report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }),
              attributes.report.diagnostics.count < limits.maximumDiagnostics, remaining > 0 else {
            return attributes.report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached,
                severity: .limitation, layer: .references)]))
        }
        var state = DicomSRReferenceValidator.State(limits: .init(maximumDepth: limits.maximumDepth,
            maximumRuleEvaluations: remaining, maximumDiagnostics: limits.maximumDiagnostics - attributes.report.diagnostics.count))
        let currentStudy = state.uid(dataSet, tag: 0x0020000D)
        collectSeries(dataSet, study: currentStudy, path: [], depth: 0, state: &state)
        for (index, item) in state.items(dataSet, tag: 0x00081200, path: []).enumerated() {
            let path: [DicomValidationReport.PathComponent] = [.tag(0x00081200), .item(index)]
            guard state.visit(path, depth: 1) else { break }
            let study = state.uid(item.dataSet, tag: 0x0020000D)
            if let study, let currentStudy, study == currentStudy {
                state.record(.referenceIdentityContradiction, path: path + [.tag(0x0020000D)])
            } else if currentStudy == nil {
                state.record(.valueUnavailable, severity: .limitation, path: path + [.tag(0x0020000D)])
            }
            collectSeries(item.dataSet, study: study, path: path, depth: 1, state: &state)
        }
        _ = state.compareEvidence()
        state.resolve(targets: targets)
        // C.12.2: once the module is declared, every General Reference instance must appear in its hierarchy.
        if applies(to: dataSet) {
            let listed = Set(state.evidenceReferences.map(\.instance))
            for tag in generalReferenceTags {
                for (index, item) in state.items(dataSet, tag: tag, path: []).enumerated() {
                    let path: [DicomValidationReport.PathComponent] = [.tag(tag), .item(index)]
                    guard state.visit(path, depth: 1) else { break }
                    guard let instance = state.uid(item.dataSet, tag: 0x00081155) else { continue }
                    if !listed.contains(instance) { state.record(.referenceEvidenceMissing, path: path + [.tag(0x00081155)]) }
                }
            }
        }
        return attributes.report.merging(.init(evaluatedLayers: [.references], diagnostics: state.diagnostics))
    }

    private static func generalReferenceInstances(_ dataSet: DicomDataSet) -> [String] {
        generalReferenceTags.flatMap { tag in
            (dataSet[tag]?.sequenceItems ?? []).compactMap { DicomSRReferenceMacro.uid($0.dataSet, tag: 0x00081155) }
        }
    }

    private static func hierarchyInstances(_ series: DicomDataElement?) -> Set<String> {
        Set((series?.sequenceItems ?? []).flatMap { item in
            (item.dataSet[0x0008114A]?.sequenceItems ?? []).compactMap { DicomSRReferenceMacro.uid($0.dataSet, tag: 0x00081155) }
        })
    }

    private static func collectSeries(_ dataSet: DicomDataSet, study: String?, path: [DicomValidationReport.PathComponent],
                                      depth: Int, state: inout DicomSRReferenceValidator.State) {
        for (index, item) in state.items(dataSet, tag: 0x00081115, path: path).enumerated() {
            let location = path + [.tag(0x00081115), .item(index)]
            guard state.visit(location, depth: depth + 1) else { return }
            let series = state.uid(item.dataSet, tag: 0x0020000E)
            if study == nil || series == nil { state.record(.valueUnavailable, severity: .limitation, path: location) }
            for (index, instance) in state.items(item.dataSet, tag: 0x0008114A, path: location).enumerated() {
                let referencePath = location + [.tag(0x0008114A), .item(index)]
                guard state.visit(referencePath, depth: depth + 2) else { return }
                if let reference = state.reference(instance.dataSet, path: referencePath, study: study, series: series) {
                    state.evidenceReferences.append(reference)
                }
            }
        }
    }
}
