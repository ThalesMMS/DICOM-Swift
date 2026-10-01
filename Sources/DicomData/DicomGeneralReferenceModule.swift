import Foundation

/// C.12.4 declared references, supplied-target identity and the geometry claimed by
/// Spatial Locations Preserved. Purpose/derivation code meaning is terminology, not schema.
public enum DicomGeneralReferenceModule {
    private static let referenceTags = [0x00081140, 0x0008114A, 0x00082112, 0x00420013]

    public static func applies(to dataSet: DicomDataSet) -> Bool {
        (referenceTags + [0x00082111, 0x00089215]).contains(where: dataSet.contains)
    }

    public static func validate(_ dataSet: DicomDataSet, targets: [String: DicomDataSet] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let code = DicomCodeSequenceMacro.standardRules()
        var rules = referenceTags.map { tag -> DicomAttributeRule in
            var itemRules = DicomSRReferenceMacro.sopRules + [
                .init(tag: 0x0040A170, requirement: tag == 0x0008114A ? .type1 : .type3,
                      itemRules: code, constraints: [.itemCount(1...1)])
            ]
            if tag == 0x00082112 {
                itemRules += [.init(tag: 0x0028135A, requirement: .type3, constraints: [.strings(["YES", "NO", "REORIENTED_ONLY"])]),
                    .init(tag: 0x00200020, requirement: .type1C,
                          condition: .all([.present(0x0028135A), .stringEquals(0x0028135A, "REORIENTED_ONLY")]),
                          mayBePresentOtherwise: true, constraints: [.valueCount(0...2)])]
            }
            return .init(tag: tag, requirement: .type3, itemRules: itemRules, constraints: [.itemCount(1...Int.max)])
        }
        rules.append(.init(tag: 0x00089215, requirement: .type3, itemRules: code, constraints: [.itemCount(1...Int.max)]))
        let attributes = DicomAttributeValidator.evaluate(dataSet, rules: rules, limits: limits)
        let remaining = limits.maximumRuleEvaluations - attributes.evaluations
        guard !attributes.report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }),
              attributes.report.diagnostics.count < limits.maximumDiagnostics, remaining > 0 else {
            return attributes.report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached,
                severity: .limitation, layer: .references)]))
        }
        var state = DicomSRReferenceValidator.State(limits: .init(maximumDepth: limits.maximumDepth,
            maximumRuleEvaluations: remaining, maximumDiagnostics: limits.maximumDiagnostics - attributes.report.diagnostics.count))
        for tag in referenceTags {
            let image = tag == 0x00081140 || tag == 0x00082112
            for (index, item) in state.items(dataSet, tag: tag, path: []).enumerated() {
                let path: [DicomValidationReport.PathComponent] = [.tag(tag), .item(index)]
                guard state.visit(path, depth: 1) else { break }
                if let reference = state.reference(item.dataSet, path: path, role: image ? .content(.image) : .nonImage) {
                    state.evidenceReferences.append(reference)
                    if tag == 0x00082112, let preserved = item.dataSet[0x0028135A]?.stringValues.first?
                        .trimmingCharacters(in: CharacterSet(charactersIn: " ")), preserved != "NO", !preserved.isEmpty,
                       let target = targets[reference.instance] {
                        // YES keeps the whole grid; REORIENTED_ONLY permits a rotation/flip of the same grid.
                        let tags = preserved == "YES" ? [0x00280010, 0x00280011, 0x00280030, 0x00200037, 0x00200032] : [0x00280030]
                        switch geometryAgreement(dataSet, target, tags: tags, ordered: preserved == "YES") {
                        case .satisfied: break
                        case .unsatisfied: state.record(.referenceTargetGeometryInvalid, path: path + [.tag(0x0028135A)])
                        case .undetermined: state.record(.valueUnavailable, severity: .limitation, path: path + [.tag(0x0028135A)])
                        }
                    }
                    if image {
                        guard !state.stopped, state.work < state.limits.maximumRuleEvaluations,
                              state.diagnostics.count < state.limits.maximumDiagnostics else { state.stop(path); break }
                        var conditions = DicomContentReferenceMacro.Conditions()
                        if let traits = DicomSOPReferenceTraits.entries[reference.sopClass] {
                            conditions.isMultiframeImage = traits.isMultiframeImage
                            conditions.isSegmentation = traits.isSegmentation ? .satisfied : .unsatisfied
                        }
                        let selectors = DicomAttributeValidator.evaluate(item.dataSet,
                            rules: DicomContentReferenceMacro.imageSelectorRules(conditions: conditions),
                            limits: .init(maximumDepth: max(0, limits.maximumDepth - 1),
                                maximumRuleEvaluations: state.limits.maximumRuleEvaluations - state.work,
                                maximumDiagnostics: state.limits.maximumDiagnostics - state.diagnostics.count))
                        state.work += selectors.evaluations
                        state.diagnostics += selectors.report.diagnostics.map {
                            .init(code: $0.code, severity: $0.severity, layer: $0.layer,
                                  path: path + $0.path, requirement: $0.requirement)
                        }
                        if selectors.report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) { state.stopped = true }
                    }
                }
            }
        }
        _ = state.compareEvidence()
        state.resolve(targets: targets)
        return attributes.report.merging(.init(evaluatedLayers: [.references], diagnostics: state.diagnostics))
    }

    private static func geometryAgreement(_ source: DicomDataSet, _ target: DicomDataSet, tags: [Int],
                                          ordered: Bool) -> DicomAttributeRule.Truth {
        for tag in tags {
            let mine = values(source[tag]), theirs = values(target[tag])
            if mine == nil, theirs == nil { continue } // Neither object declares this geometry attribute.
            guard let mine, let theirs else { return .undetermined }
            if ordered ? mine != theirs : mine.sorted() != theirs.sorted() { return .unsatisfied }
        }
        return .satisfied
    }

    private static func values(_ element: DicomDataElement?) -> [String]? {
        guard let element else { return nil }
        switch element.value {
        case .strings(let values): return values.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")) }
        case .unsignedIntegers(let values): return values.map(String.init)
        case .signedIntegers(let values): return values.map(String.init)
        default: return nil
        }
    }
}
