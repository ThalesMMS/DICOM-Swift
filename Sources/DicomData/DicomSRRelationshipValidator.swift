import Foundation

/// Resolves raw Content Item identifiers and checks Enhanced SR, Comprehensive SR and KOS relationship tables.
/// Requires the SELECTED FROM relationships of SCOORD/TCOORD under C.18.6/C.18.7.
/// Does not qualify templates, content values, external SOP references or image geometry.
public enum DicomSRRelationshipValidator {
    public static func validate(_ dataSet: DicomDataSet,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        inspect(dataSet, limits: limits).report
    }

    package struct SelectedItem: Sendable {
        let dataSet: DicomDataSet
        let path: [DicomValidationReport.PathComponent]
    }

    package struct CoordinateSelection: Sendable {
        let source: DicomDataSet
        let path: [DicomValidationReport.PathComponent]
        let targets: [SelectedItem]
        let isComplete: Bool
    }

    package struct GraphResult: Sendable {
        let report: DicomValidationReport
        let coordinates: [CoordinateSelection]
        let evaluations: Int
    }

    package static func inspect(_ dataSet: DicomDataSet, limits: DicomAttributeValidator.Limits) -> GraphResult {
        let profile = string(dataSet, tag: 0x00080016, vr: .UI, maximumBytes: 64).flatMap(DicomSRRelationshipConstraints.init(rawValue:))
        var state = State(profile: profile, limits: limits)
        if profile == nil { state.record(.referenceRuleUnavailable, severity: .limitation, path: [.tag(0x00080016)]) }
        state.walk(dataSet, identifier: [1], path: [])
        state.resolve()
        state.requireCoordinateSelections()
        let coordinates = state.coordinateSources.compactMap { source -> CoordinateSelection? in
            guard let node = state.nodes[source.identifier] else { return nil }
            return .init(source: node.dataSet, path: source.path, targets: state.selectedTargets[source.identifier] ?? [],
                isComplete: !state.stopped && profile != nil && state.fulfilledSelections.contains(source.identifier) &&
                    !state.opaqueChildren.contains(source.identifier) && !state.uncertainSelections.contains(source.identifier))
        }
        return .init(report: .init(evaluatedLayers: [.references], diagnostics: state.diagnostics), coordinates: coordinates, evaluations: state.work)
    }

    private static func string(_ dataSet: DicomDataSet, tag: Int, vr: DicomVR, maximumBytes: Int = 16) -> String? {
        guard let element = dataSet[tag], element.vr == vr, case .strings(let values) = element.value,
              values.count == 1, values[0].utf8.count <= maximumBytes else { return nil }
        let result = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return result.isEmpty ? nil : result
    }

    private struct Node {
        let valueType: String?
        let byReference: Bool
        let dataSet: DicomDataSet
        let path: [DicomValidationReport.PathComponent]
    }

    private struct Edge {
        let source: [Int]
        let target: [Int]
        let relationship: String?
        let byReference: Bool
        let path: [DicomValidationReport.PathComponent]
    }

    private struct State {
        let profile: DicomSRRelationshipConstraints?
        let limits: DicomAttributeValidator.Limits
        var nodes: [[Int]: Node] = [:]
        var opaqueChildren: Set<[Int]> = []
        var edges: [Edge] = []
        var coordinateSources: [(identifier: [Int], path: [DicomValidationReport.PathComponent])] = []
        var fulfilledSelections: Set<[Int]> = []
        var uncertainSelections: Set<[Int]> = []
        var selectedTargets: [[Int]: [SelectedItem]] = [:]
        var diagnostics: [DicomValidationReport.Diagnostic] = []
        var work = 0
        var stopped = false

        mutating func consume(_ count: Int = 1, path: [DicomValidationReport.PathComponent]) -> Bool {
            guard !stopped else { return false }
            guard count <= limits.maximumRuleEvaluations - work, diagnostics.count < limits.maximumDiagnostics else {
                stop(path)
                return false
            }
            work += count
            return true
        }

        mutating func record(_ code: DicomValidationReport.Code, severity: DicomValidationReport.Severity = .error,
                             path: [DicomValidationReport.PathComponent]) {
            guard !stopped else { return }
            guard diagnostics.count < limits.maximumDiagnostics else { stop(path); return }
            diagnostics.append(.init(code: code, severity: severity, layer: .references, path: path))
        }

        mutating func stop(_ path: [DicomValidationReport.PathComponent]) {
            guard !stopped else { return }
            diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .references, path: path))
            stopped = true
        }

        mutating func walk(_ dataSet: DicomDataSet, identifier: [Int], path: [DicomValidationReport.PathComponent]) {
            guard identifier.count - 1 <= limits.maximumDepth else { stop(path); return }
            guard consume(path: path) else { return }
            let byReference = dataSet.contains(0x0040DB73)
            let valueType = string(dataSet, tag: 0x0040A040, vr: .CS)
            nodes[identifier] = .init(valueType: valueType, byReference: byReference, dataSet: dataSet, path: path)
            if !byReference && (valueType == "SCOORD" || valueType == "TCOORD") {
                coordinateSources.append((identifier, path))
            }
            if identifier.count > 1 {
                let target = byReference ? referenceIdentifier(dataSet, path: path) : identifier
                let relationship = string(dataSet, tag: 0x0040A010, vr: .CS)
                if target == nil && (relationship == nil || relationship == "SELECTED FROM") {
                    uncertainSelections.insert(Array(identifier.dropLast()))
                }
                if let target {
                    edges.append(.init(source: Array(identifier.dropLast()), target: target,
                        relationship: relationship, byReference: byReference, path: path))
                }
            } else if byReference {
                record(.contentReferenceIdentifierInvalid, path: [.tag(0x0040DB73)])
            }
            guard !stopped, let children = dataSet[0x0040A730] else { return }
            if byReference {
                record(.relationshipNotAllowed, path: path + [.tag(0x0040A730)])
                return // A by-reference relationship cannot contain either document macro.
            }
            guard children.vr == .SQ, case .sequence(let items) = children.value else {
                if children.vr == .SQ, case .empty = children.value { return }
                opaqueChildren.insert(identifier)
                record(.valueUnavailable, severity: .limitation, path: path + [.tag(0x0040A730)])
                return
            }
            for (index, item) in items.enumerated() {
                guard !stopped else { return }
                walk(item.dataSet, identifier: identifier + [index + 1], path: path + [.tag(0x0040A730), .item(index)])
            }
        }

        mutating func referenceIdentifier(_ dataSet: DicomDataSet, path: [DicomValidationReport.PathComponent]) -> [Int]? {
            let location = path + [.tag(0x0040DB73)]
            guard let element = dataSet[0x0040DB73], element.vr == .UL,
                  case .unsignedIntegers(let values) = element.value else {
                record(.valueUnavailable, severity: .limitation, path: location)
                return nil
            }
            guard values.count <= limits.maximumDepth + 1 else { stop(location); return nil }
            guard consume(values.count, path: location) else { return nil }
            guard values.first == 1, values.allSatisfy({ $0 > 0 && $0 <= UInt(UInt32.max) }) else {
                record(.contentReferenceIdentifierInvalid, path: location)
                return nil
            }
            return values.map { Int($0) }
        }

        mutating func requireCoordinateSelections() {
            guard !stopped else { return } // Unvisited relationships cannot prove absence.
            for source in coordinateSources {
                let path = source.path + [.tag(0x0040A730)]
                guard consume(path: path) else { return }
                if !fulfilledSelections.contains(source.identifier) && !opaqueChildren.contains(source.identifier) &&
                    !uncertainSelections.contains(source.identifier) {
                    record(.requiredRelationshipMissing, path: path)
                }
            }
        }

        mutating func resolve() {
            for edge in edges {
                let location = edge.path + [.tag(edge.byReference ? 0x0040DB73 : 0x0040A010)]
                guard consume(path: location) else { return }
                let possibleSelection = edge.relationship == nil || edge.relationship == "SELECTED FROM"
                guard let target = nodes[edge.target] else {
                    if possibleSelection { uncertainSelections.insert(edge.source) }
                    // A target below an uninterpreted sequence is unavailable, not proven absent.
                    guard consume(edge.target.count, path: location) else { return }
                    let unknown = (1..<edge.target.count).contains { opaqueChildren.contains(Array(edge.target.prefix($0))) }
                    record(unknown ? .referenceTargetUnavailable : .contentReferenceTargetMissing,
                           severity: unknown ? .limitation : .error, path: location)
                    continue
                }
                guard !target.byReference else {
                    if possibleSelection { uncertainSelections.insert(edge.source) }
                    record(.contentReferenceTargetNotByValue, path: location)
                    continue
                }
                let forbiddenAncestor = edge.byReference && (profile == .comprehensive || profile == .comprehensive3D) &&
                    edge.source.starts(with: edge.target)
                if forbiddenAncestor {
                    record(.contentReferenceAncestorForbidden, path: location)
                }
                guard let sourceType = nodes[edge.source]?.valueType, let targetType = target.valueType,
                      let relationship = edge.relationship else {
                    if possibleSelection { uncertainSelections.insert(edge.source) }
                    record(.valueUnavailable, severity: .limitation, path: location)
                    continue
                }
                let permitted = profile?.permits(source: sourceType, relationship: relationship,
                                                  target: targetType, byReference: edge.byReference) ?? true
                if !permitted { record(.relationshipNotAllowed, path: edge.path + [.tag(0x0040A010)]) }
                let coordinateTarget = (sourceType == "SCOORD" && targetType == "IMAGE") ||
                    (sourceType == "TCOORD" && (["SCOORD", "IMAGE", "WAVEFORM"].contains(targetType) ||
                        (profile == .comprehensive3D && targetType == "SCOORD3D")))
                if relationship == "SELECTED FROM", coordinateTarget, permitted, !forbiddenAncestor {
                    fulfilledSelections.insert(edge.source)
                    selectedTargets[edge.source, default: []].append(.init(dataSet: target.dataSet, path: target.path))
                }
            }
        }
    }
}
