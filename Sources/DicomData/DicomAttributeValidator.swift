import Foundation

/// Evaluates PS3.5 section 7.4 requirements on an owned dataset. VR/VM, wire structure,
/// references, pixel payloads, and SOP-specific semantics remain separate validation layers.
public enum DicomAttributeValidator {
    public struct Limits: Sendable {
        public let maximumDepth: Int
        public let maximumRuleEvaluations: Int
        public let maximumDiagnostics: Int

        public init(maximumDepth: Int = 64, maximumRuleEvaluations: Int = 100_000, maximumDiagnostics: Int = 128) {
            self.maximumDepth = min(64, max(0, maximumDepth))
            self.maximumRuleEvaluations = max(0, maximumRuleEvaluations)
            self.maximumDiagnostics = max(1, maximumDiagnostics)
        }
    }

    /// The diagnostic budget reserves one additional terminal limitation when evaluation stops.
    public static func validate(_ dataSet: DicomDataSet, rules: [DicomAttributeRule],
                                limits: Limits = .init()) -> DicomValidationReport {
        evaluate(dataSet, rules: rules, limits: limits).report
    }

    /// Reports consumed rule/constraint work so a composing traversal can share one budget.
    public static func evaluate(_ dataSet: DicomDataSet, rules: [DicomAttributeRule],
                                limits: Limits = .init()) -> (report: DicomValidationReport, evaluations: Int) {
        var state = State(limits: limits)
        if rules.isEmpty {
            state.diagnostics.append(.init(code: .emptyRuleSet, severity: .limitation, layer: .attributes))
        } else {
            state.evaluate(dataSet, rules: rules, path: [], depth: 0)
        }
        return (.init(evaluatedLayers: [.attributes], diagnostics: state.diagnostics), state.evaluations)
    }

    private struct State {
        let limits: Limits
        var diagnostics: [DicomValidationReport.Diagnostic] = []
        var evaluations = 0
        var stopped = false

        mutating func evaluate(_ dataSet: DicomDataSet, rules: [DicomAttributeRule],
                               path: [DicomValidationReport.PathComponent], depth: Int) {
            for rule in rules {
                guard !stopped else { return }
                let location = path + [.tag(rule.tag)]
                guard depth <= limits.maximumDepth, evaluations < limits.maximumRuleEvaluations,
                      diagnostics.count < limits.maximumDiagnostics else {
                    diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation,
                                             layer: .attributes, path: location, requirement: rule.requirement))
                    stopped = true
                    return
                }
                evaluations += 1
                evaluateAttribute(dataSet, rule: rule, path: location, depth: depth)
            }
        }

        mutating func evaluateAttribute(_ dataSet: DicomDataSet, rule: DicomAttributeRule,
                                        path: [DicomValidationReport.PathComponent], depth: Int) {
            let element = dataSet[rule.tag]
            let conditional = rule.requirement == .type1C || rule.requirement == .type2C
            let truth = conditional ? (rule.condition?.evaluate(in: dataSet) ?? .undetermined) : .satisfied
            if truth == .undetermined {
                record(.conditionUndetermined, severity: .limitation, rule: rule, path: path)
            } else if truth == .unsatisfied {
                if element != nil && !rule.mayBePresentOtherwise {
                    record(.conditionalAttributeForbidden, rule: rule, path: path)
                }
            } else if element == nil && rule.requirement != .type3 {
                record(.requiredAttributeMissing, rule: rule, path: path)
            }
            guard let element else { return }
            let requiresValue = truth == .satisfied && (rule.requirement == .type1 || rule.requirement == .type1C)
            let optionalSequenceNeedsItem = rule.requirement == .type3 && element.vr == .SQ
            if (requiresValue || optionalSequenceNeedsItem) && isEmpty(element) {
                record(.requiredValueEmpty, rule: rule, path: path)
            } else if requiresValue && element.vr == .UN {
                record(.valueUnavailable, severity: .limitation, rule: rule, path: path)
            }
            for constraint in rule.constraints {
                guard !stopped else { return }
                guard evaluations < limits.maximumRuleEvaluations else {
                    diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation,
                                             layer: .attributes, path: path, requirement: rule.requirement))
                    stopped = true
                    return
                }
                evaluations += 1
                let componentCount: Int?
                switch constraint {
                case .temporalCoordinateValues, .spatialCoordinateValues: componentCount = element.vm.count
                case .personIdentificationNames(let tag, _): componentCount = dataSet[tag]?.vm.count ?? 0
                default: componentCount = nil
                }
                if let count = componentCount {
                    guard count <= limits.maximumRuleEvaluations - evaluations else {
                        diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation,
                                                 layer: .attributes, path: path, requirement: rule.requirement))
                        stopped = true
                        return
                    }
                    evaluations += count
                }
                if let issue = DicomAttributeConstraintValidator.validate(constraint, element: element, dataSet: dataSet) {
                    let itemConstraint = issue.code == .exclusiveAttributeChoiceInvalid
                    record(issue.code, severity: issue.severity, rule: rule,
                           path: itemConstraint ? Array(path.dropLast()) : path, includeRequirement: !itemConstraint)
                }
            }
            guard !rule.itemRules.isEmpty else { return }
            // UN may legally retain a sequence whose item encoding has not been interpreted.
            // Missing item evidence is not proof that the source held a non-sequence value.
            if element.vr == .UN {
                if !requiresValue || isEmpty(element) {
                    record(.valueUnavailable, severity: .limitation, rule: rule, path: path)
                }
                return
            }
            guard element.vr == .SQ else {
                record(.sequenceExpected, rule: rule, path: path)
                return
            }
            if case .empty = element.value { return }
            guard case .sequence(let items) = element.value else {
                record(.sequenceExpected, rule: rule, path: path)
                return
            }
            for (index, item) in items.enumerated() {
                evaluate(item.dataSet, rules: rule.itemRules, path: path + [.item(index)], depth: depth + 1)
                if stopped { return }
            }
        }

        mutating func record(_ code: DicomValidationReport.Code, severity: DicomValidationReport.Severity = .error,
                             rule: DicomAttributeRule, path: [DicomValidationReport.PathComponent],
                             includeRequirement: Bool = true) {
            guard !stopped else { return }
            guard diagnostics.count < limits.maximumDiagnostics else {
                diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation,
                                         layer: .attributes, path: path, requirement: rule.requirement))
                stopped = true
                return
            }
            diagnostics.append(.init(code: code, severity: severity, layer: .attributes,
                                     path: path, requirement: includeRequirement ? rule.requirement : nil))
        }

        func isEmpty(_ element: DicomDataElement) -> Bool {
            switch element.value {
            case .empty: return true
            case .strings(let values):
                let singleText = [DicomVR.ST, .LT, .UT, .UR].contains(element.vr)
                let delimiters = CharacterSet(charactersIn: element.vr == .PN ? " \\^=" : singleText ? " " : " \\")
                return values.allSatisfy { $0.trimmingCharacters(in: delimiters).isEmpty }
            case .sequence(let items): return items.isEmpty
            case .bytes(let bytes): return bytes.isEmpty
            case .signedIntegers(let values): return values.isEmpty
            case .unsignedIntegers(let values): return values.isEmpty
            case .floats(let values): return values.isEmpty
            }
        }
    }
}
