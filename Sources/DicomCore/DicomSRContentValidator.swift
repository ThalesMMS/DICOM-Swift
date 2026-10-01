import Foundation

/// Composes raw projection prerequisites with the existing application SR semantic validator.
/// Attribute prerequisites are not complete content/IOD rules. Semantic results describe operation scope.
public enum DicomSRContentValidator {
    /// Per-item precision and condition keys are original zero-based Content Sequence index paths; the root key is empty.
    /// Targets preserve complete actual metadata (pixel payload may be omitted); their derived coordinate facts override caller facts with contradiction diagnostics.
    public static func validate(_ dataSet: DicomDataSet, supportMatrix: DicomSRSupportMatrix = .standard,
                                versionRequirements: [String: DicomAttributeRule.Truth] = [:],
                                numericPrecisionRequirements: [[Int]: DicomNumericMeasurementMacro.PrecisionRequirements] = [:],
                                referenceConditions: [[Int]: DicomContentReferenceMacro.Conditions] = [:],
                                contentConditions: [[Int]: DicomSRContentItemMacro.Conditions] = [:],
                                defaultContentConditions: DicomSRContentItemMacro.Conditions = .init(),
                                temporalConditions: [[Int]: DicomTemporalCoordinatesMacro.Conditions] = [:],
                                spatialConditions: [[Int]: DicomSpatialCoordinatesMacro.Conditions] = [:],
                                targets: [String: DicomDataSet] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var state = State(supportMatrix: supportMatrix, versionRequirements: versionRequirements,
                          numericPrecisionRequirements: numericPrecisionRequirements,
                          referenceConditions: referenceConditions, contentConditions: contentConditions,
                          defaultContentConditions: defaultContentConditions,
                          temporalConditions: temporalConditions, spatialConditions: spatialConditions, limits: limits)
        if !targets.isEmpty {
            let resolved = DicomSRCoordinateReferenceValidator.evaluate(dataSet, targets: targets, limits: limits)
            state.diagnostics = resolved.report.diagnostics
            state.work = resolved.evaluations
            state.resolvedSpatialConditions = resolved.spatialConditions
            state.resolvedTemporalConditions = resolved.temporalConditions
            state.checkedCoordinatePaths = resolved.checkedPaths
            state.failedCoordinatePaths = resolved.failedPaths
            state.additionalLayers = resolved.report.evaluatedLayers
            state.geometricEvidence = resolved.report.evaluatedLayers.contains(.pixelsAndGeometry)
        }
        state.walk(dataSet, path: [], depth: 0)
        if state.geometricEvidence, let path = state.opaqueGeometryPath {
            state.record(.valueUnavailable, severity: .limitation, layer: .pixelsAndGeometry, path: path)
        }
        // Template (TID) content is validated by the application semantic layer and #2345, not here.
        let layers: Set<DicomValidationReport.Layer> = state.geometricEvidence ? [.attributes, .operation, .pixelsAndGeometry] : [.attributes, .operation]
        return .init(evaluatedLayers: layers.union(state.additionalLayers),
                     diagnostics: state.diagnostics)
    }

    private struct State {
        let supportMatrix: DicomSRSupportMatrix
        let versionRequirements: [String: DicomAttributeRule.Truth]
        let numericPrecisionRequirements: [[Int]: DicomNumericMeasurementMacro.PrecisionRequirements]
        let referenceConditions: [[Int]: DicomContentReferenceMacro.Conditions]
        let contentConditions: [[Int]: DicomSRContentItemMacro.Conditions]
        let defaultContentConditions: DicomSRContentItemMacro.Conditions
        let temporalConditions: [[Int]: DicomTemporalCoordinatesMacro.Conditions]
        let spatialConditions: [[Int]: DicomSpatialCoordinatesMacro.Conditions]
        let limits: DicomAttributeValidator.Limits
        var diagnostics: [DicomValidationReport.Diagnostic] = []
        var work = 0
        var stopped = false
        var geometricEvidence = false
        var opaqueGeometryPath: [DicomValidationReport.PathComponent]?
        var resolvedSpatialConditions: [[Int]: DicomSpatialCoordinatesMacro.Conditions] = [:]
        var resolvedTemporalConditions: [[Int]: DicomTemporalCoordinatesMacro.Conditions] = [:]
        var checkedCoordinatePaths: Set<[Int]> = []
        var failedCoordinatePaths: Set<[Int]> = []
        var additionalLayers: Set<DicomValidationReport.Layer> = []

        mutating func walk(_ dataSet: DicomDataSet, path: [DicomValidationReport.PathComponent], depth: Int) {
            guard !stopped else { return }
            guard depth <= limits.maximumDepth, work < limits.maximumRuleEvaluations,
                  diagnostics.count < limits.maximumDiagnostics else { stop(path); return }
            work += 1
            let indices = path.compactMap { component -> Int? in
                if case .item(let index) = component { return index }
                return nil
            }
            var spatialFacts = spatialConditions[indices] ?? .init()
            var coordinateFactContradiction = false
            var temporalFacts = temporalConditions[indices] ?? .init()
            if let resolved = resolvedTemporalConditions[indices] {
                for key in [\DicomTemporalCoordinatesMacro.Conditions.referencesWaveform, \.channelsUseSingleMultiplexGroup] {
                    let actual = resolved[keyPath: key], supplied = temporalFacts[keyPath: key]
                    if actual != .undetermined {
                        if supplied != .undetermined && supplied != actual {
                            record(.attributeValueContradiction, severity: .error, layer: .attributes,
                                   path: path + [.tag(0x0040A132)], requirement: .type1C)
                            coordinateFactContradiction = true
                        }
                        temporalFacts[keyPath: key] = actual
                    }
                }
            }
            if let resolved = resolvedSpatialConditions[indices], resolved.referencedImageIsTiled != .undetermined {
                if spatialFacts.referencedImageIsTiled != .undetermined && spatialFacts.referencedImageIsTiled != resolved.referencedImageIsTiled {
                    record(.attributeValueContradiction, severity: .error, layer: .attributes, path: path + [.tag(0x00480301)])
                    coordinateFactContradiction = true
                }
                spatialFacts = resolved
            }
            let raw = DicomAttributeValidator.evaluate(dataSet,
                rules: DicomSRContentRules.rules(for: dataSet, isRoot: depth == 0, versionRequirements: versionRequirements,
                    numericPrecision: numericPrecisionRequirements[indices] ?? .init(),
                    referenceConditions: referenceConditions[indices] ?? .init(),
                    contentConditions: contentConditions[indices] ?? defaultContentConditions,
                    temporalConditions: temporalFacts, spatialConditions: spatialFacts),
                limits: .init(maximumDepth: limits.maximumDepth - depth,
                              maximumRuleEvaluations: limits.maximumRuleEvaluations - work,
                              maximumDiagnostics: limits.maximumDiagnostics - diagnostics.count))
            work += raw.evaluations
            for diagnostic in raw.report.diagnostics {
                if diagnostic.code == .evaluationLimitReached { stop(path + diagnostic.path); break }
                record(diagnostic.code, severity: diagnostic.severity, layer: diagnostic.layer,
                       path: path + diagnostic.path, requirement: diagnostic.requirement)
            }
            guard !stopped else { return }
            if dataSet.contains(0x0040DB73) {
                record(.semanticScopeUnavailable, severity: .limitation, layer: .operation, path: path + [.tag(0x0040DB73)])
                return // The existing semantic model cannot represent by-reference items.
            }
            var geometryFailed = failedCoordinatePaths.contains(indices) || coordinateFactContradiction
            if let kind = DicomSpatialCoordinatesMacro.Kind(rawValue: DicomSRContentItemMacro.valueType(dataSet) ?? "") {
                geometricEvidence = true
                let geometry = DicomSpatialGeometryValidator.evaluate(dataSet, kind: kind,
                    limits: .init(maximumRuleEvaluations: limits.maximumRuleEvaluations - work,
                                  maximumDiagnostics: limits.maximumDiagnostics - diagnostics.count))
                work += geometry.evaluations
                geometryFailed = geometryFailed || geometry.report[.pixelsAndGeometry] == .failed
                for diagnostic in geometry.report.diagnostics {
                    if diagnostic.code == .evaluationLimitReached { stop(path + diagnostic.path); break }
                    record(diagnostic.code, severity: diagnostic.severity, layer: diagnostic.layer,
                           path: path + diagnostic.path, requirement: diagnostic.requirement)
                }
                if kind == .spatial && !checkedCoordinatePaths.contains(indices) {
                    record(.referenceTargetUnavailable, severity: .limitation, layer: .pixelsAndGeometry,
                           path: path + [.tag(0x00700022)]) // Actual image/frame/matrix upper bounds remain unqualified.
                }
            }
            if DicomSRContentItemMacro.valueType(dataSet) == "TCOORD" {
                geometricEvidence = true
                if !checkedCoordinatePaths.contains(indices) {
                    let samples = dataSet.contains(0x0040A132)
                    let tag = samples ? 0x0040A132 : dataSet.contains(0x0040A138) ? 0x0040A138 : 0x0040A13A
                    record(samples ? .referenceTargetUnavailable : .temporalAlignmentUnavailable,
                           severity: .limitation, layer: .pixelsAndGeometry, path: path + [.tag(tag)])
                }
            }
            guard !stopped else { return }
            if geometryFailed || raw.report[.attributes] == .failed || raw.report.diagnostics.contains(where: { $0.code == .valueUnavailable }) {
                record(.semanticProjectionUnavailable, severity: .limitation, layer: .operation, path: path)
            } else {
                project(dataSet, path: path, isRoot: depth == 0)
            }
            guard !stopped, let children = dataSet[0x0040A730] else { return }
            if children.vr == .SQ, case .empty = children.value { return }
            guard children.vr == .SQ, case .sequence(let items) = children.value else {
                if opaqueGeometryPath == nil { opaqueGeometryPath = path + [.tag(0x0040A730)] }
                return
            }
            for (index, item) in items.enumerated() {
                guard !stopped else { return }
                walk(item.dataSet, path: path + [.tag(0x0040A730), .item(index)], depth: depth + 1)
            }
        }

        mutating func project(_ dataSet: DicomDataSet, path: [DicomValidationReport.PathComponent], isRoot: Bool) {
            // Do not let parser defaults or recursive child filtering affect validation or source paths.
            guard let valueType = dataSet[0x0040A040], valueType.vr == .CS,
                  case .strings(let values) = valueType.value, values.count == 1, !values[0].isEmpty else {
                record(.semanticProjectionUnavailable, severity: .limitation, layer: .operation, path: path + [.tag(0x0040A040)])
                return
            }
            if let unsupported = unsupportedCodeEncoding(dataSet) {
                record(.semanticProjectionUnavailable, severity: .limitation, layer: .operation, path: path + unsupported)
                return
            }
            let reference = dataSet.sequenceItems(for: .referencedSOPSequence).first?.dataSet
            let vectors: [(Int, [DicomValidationReport.PathComponent])] = [
                (dataSet[0x00700022]?.vm.count ?? 0, [.tag(0x00700022)]),
                (reference?[0x00081160]?.vm.count ?? 0, [.tag(0x00081199), .item(0), .tag(0x00081160)])
            ]
            for (count, location) in vectors {
                guard count <= limits.maximumRuleEvaluations - work else { stop(path + location); return }
                work += count
            }
            guard let item = DicomSRParser.contentItem(from: dataSet.removing(0x0040A730)) else {
                record(.semanticProjectionUnavailable, severity: .limitation, layer: .operation, path: path)
                return
            }
            var errors: [DicomSRSemanticValidationError] = []
            if isRoot {
                let document = DicomSRDocument(sopClassUID: dataSet.string(for: .sopClassUID),
                    templateIdentifier: dataSet.sequenceItems(for: .contentTemplateSequence).first?.dataSet.string(for: .templateIdentifier),
                    root: item)
                DicomSRSemanticValidator.validateDocumentIdentity(document, supportMatrix: supportMatrix, errors: &errors)
            }
            DicomSRSemanticValidator.validateItemContents(item, path: "root", isRoot: isRoot,
                supportMatrix: supportMatrix, errors: &errors)
            for error in errors { append(error, dataSet: dataSet, prefix: path) }
        }

        func unsupportedCodeEncoding(_ dataSet: DicomDataSet) -> [DicomValidationReport.PathComponent]? {
            let measured = dataSet.sequenceItems(for: .measuredValueSequence).first?.dataSet
            let entries: [(DicomDataSet?, [DicomValidationReport.PathComponent])] = [
                (dataSet.sequenceItems(for: .conceptNameCodeSequence).first?.dataSet, [.tag(0x0040A043), .item(0)]),
                (dataSet.sequenceItems(for: .conceptCodeSequence).first?.dataSet, [.tag(0x0040A168), .item(0)]),
                (measured?.sequenceItems(for: .measurementUnitsCodeSequence).first?.dataSet,
                 [.tag(0x0040A300), .item(0), .tag(0x004008EA), .item(0)])
            ]
            for (entry, path) in entries {
                for tag in [0x00080119, 0x00080120] where entry?.contains(tag) == true { return path + [.tag(tag)] }
            }
            return nil
        }

        mutating func append(_ error: DicomSRSemanticValidationError, dataSet: DicomDataSet,
                             prefix: [DicomValidationReport.PathComponent]) {
            let mapped = DicomSRSemanticDiagnosticMapping.map(error, dataSet: dataSet)
            record(mapped.code, severity: mapped.severity, layer: .operation, path: prefix + mapped.path)
        }

        mutating func record(_ code: DicomValidationReport.Code, severity: DicomValidationReport.Severity,
                             layer: DicomValidationReport.Layer, path: [DicomValidationReport.PathComponent],
                             requirement: DicomAttributeRule.Requirement? = nil) {
            guard !stopped else { return }
            guard diagnostics.count < limits.maximumDiagnostics else { stop(path); return }
            diagnostics.append(.init(code: code, severity: severity, layer: layer, path: path, requirement: requirement))
        }

        mutating func stop(_ path: [DicomValidationReport.PathComponent]) {
            guard !stopped else { return }
            diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .attributes, path: path))
            diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .operation, path: path))
            if geometricEvidence {
                diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .pixelsAndGeometry, path: path))
            }
            stopped = true
        }
    }
}
