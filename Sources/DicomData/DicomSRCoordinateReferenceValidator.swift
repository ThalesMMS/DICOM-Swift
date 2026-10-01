import Foundation

/// Resolves spatial/temporal SELECTED FROM references and checks C.18.6/C.18.7 metadata bounds.
/// Supplied targets must preserve the actual object's complete metadata; pixel payloads may be omitted.
public enum DicomSRCoordinateReferenceValidator {
    public struct Result: Sendable {
        public let report: DicomValidationReport
        public let temporalConditions: [[Int]: DicomTemporalCoordinatesMacro.Conditions]
        public let spatialConditions: [[Int]: DicomSpatialCoordinatesMacro.Conditions]
        package let checkedPaths: Set<[Int]>
        package let failedPaths: Set<[Int]>
        package let evaluations: Int
    }

    public static func validate(_ dataSet: DicomDataSet, targets: [String: DicomDataSet] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> Result {
        evaluate(dataSet, targets: targets, limits: limits)
    }

    package static func evaluate(_ dataSet: DicomDataSet, targets: [String: DicomDataSet],
                                 limits: DicomAttributeValidator.Limits, spatialOnly: Bool = false) -> Result {
        let graph = DicomSRRelationshipValidator.inspect(dataSet, limits: limits)
        var state = State(limits: limits, targets: targets, diagnostics: graph.report.diagnostics, work: graph.evaluations)
        state.coordinateSelections = Dictionary(uniqueKeysWithValues: graph.coordinates.map { (itemIndices($0.path), $0) })
        for source in graph.coordinates {
            let spatial = DicomSRContentItemMacro.valueType(source.source) == "SCOORD"
            if spatialOnly && !spatial { continue }
            state.hasCoordinates = true
            if spatial { state.validate(source) } else { state.validateTemporal(source) }
            if state.stopped { break }
        }
        return .init(report: .init(evaluatedLayers: state.hasCoordinates ? [.references, .pixelsAndGeometry] : [.references],
                                  diagnostics: state.diagnostics),
                     temporalConditions: state.stopped ? [:] : state.temporalConditions,
                     spatialConditions: state.stopped ? [:] : state.conditions, checkedPaths: state.checkedPaths,
                     failedPaths: state.failedPaths, evaluations: state.work)
    }

    static func itemIndices(_ path: [DicomValidationReport.PathComponent]) -> [Int] {
        path.compactMap { if case .item(let index) = $0 { return index }; return nil }
    }

    struct State {
        let limits: DicomAttributeValidator.Limits
        let targets: [String: DicomDataSet]
        var diagnostics: [DicomValidationReport.Diagnostic]
        var work: Int
        var stopped = false
        var hasCoordinates = false
        var conditions: [[Int]: DicomSpatialCoordinatesMacro.Conditions] = [:]
        var temporalConditions: [[Int]: DicomTemporalCoordinatesMacro.Conditions] = [:]
        var coordinateSelections: [[Int]: DicomSRRelationshipValidator.CoordinateSelection] = [:]
        var checkedPaths: Set<[Int]> = []
        var failedPaths: Set<[Int]> = []

        mutating func consume(_ count: Int = 1, path: [DicomValidationReport.PathComponent]) -> Bool {
            guard !stopped else { return false }
            guard count <= limits.maximumRuleEvaluations - work, diagnostics.count < limits.maximumDiagnostics else {
                stop(path); return false
            }
            work += count
            return true
        }

        mutating func stop(_ path: [DicomValidationReport.PathComponent]) {
            guard !stopped else { return }
            diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .pixelsAndGeometry, path: path))
            stopped = true
        }

        mutating func record(_ code: DicomValidationReport.Code, severity: DicomValidationReport.Severity = .error,
                             path: [DicomValidationReport.PathComponent], layer: DicomValidationReport.Layer = .pixelsAndGeometry,
                             requirement: DicomAttributeRule.Requirement? = nil) {
            guard !stopped else { return }
            guard diagnostics.count < limits.maximumDiagnostics else { stop(path); return }
            diagnostics.append(.init(code: code, severity: severity, layer: layer, path: path, requirement: requirement))
        }

        mutating func validate(_ source: DicomSRRelationshipValidator.CoordinateSelection) {
            let location = source.path + [.tag(0x00700022)]
            guard consume(path: location) else { return }
            let indices = source.path.compactMap { if case .item(let index) = $0 { return index }; return nil }
            checkedPaths.insert(indices)
            let previousDiagnostics = diagnostics.count
            defer {
                if diagnostics.dropFirst(previousDiagnostics).contains(where: { $0.severity == .error }) { failedPaths.insert(indices) }
            }
            var complete = source.isComplete
            var anyTiled = false
            var allNotTiled = source.isComplete && !source.targets.isEmpty
            var dimensions: [(columns: Int, rows: Int)] = []
            let origin = pixelOrigin(source.source)
            if origin == nil { record(.valueUnavailable, severity: .limitation, path: source.path + [.tag(0x00480301)]) }
            for selected in source.targets {
                guard consume(path: selected.path) else { return }
                guard let matched = matchedTarget(selected) else { complete = false; allNotTiled = false; continue }
                let target = matched.dataSet
                complete = complete && matched.selectionComplete
                let columnsPresent = target.contains(0x00480006), rowsPresent = target.contains(0x00480007)
                anyTiled = anyTiled || (columnsPresent && rowsPresent)
                allNotTiled = allNotTiled && !columnsPresent && !rowsPresent
                if columnsPresent != rowsPresent { complete = false }
                let referencePath = selected.path + [.tag(0x00081199), .item(0)]
                if let origin,
                   let columns = count(target, tag: origin == "VOLUME" ? 0x00480006 : 0x00280011,
                                       vr: origin == "VOLUME" ? .UL : .US, path: referencePath),
                   let rows = count(target, tag: origin == "VOLUME" ? 0x00480007 : 0x00280010,
                                    vr: origin == "VOLUME" ? .UL : .US, path: referencePath) {
                    dimensions.append((columns, rows))
                } else { complete = false }
            }
            var facts = DicomSpatialCoordinatesMacro.Conditions()
            facts.referencedImageIsTiled = anyTiled ? .satisfied : allNotTiled ? .unsatisfied : .undetermined
            if !stopped { conditions[indices] = facts }
            if !complete { record(.referenceTargetUnavailable, severity: .limitation, path: location) }
            guard !stopped, let element = source.source[0x00700022], element.vr == .FL,
                  case .floats(let values) = element.value, !values.isEmpty else {
                record(.valueUnavailable, severity: .limitation, path: location); return
            }
            guard consume(values.count, path: location) else { return }
            if let invalid = DicomSpatialCoordinateValueValidator.validate(element, dataSet: source.source, kind: .spatial) {
                record(invalid.code, severity: invalid.severity, path: location); return
            }
            for size in dimensions {
                guard consume(values.count, path: location) else { return }
                if values.enumerated().contains(where: { $0.element > Double($0.offset.isMultiple(of: 2) ? size.columns : size.rows) }) {
                    record(.spatialCoordinateOutOfRange, path: location, requirement: .type1)
                }
            }
        }

        func pixelOrigin(_ source: DicomDataSet) -> String? {
            guard let element = source[0x00480301] else { return "FRAME" }
            guard element.vr == .CS, case .strings(let values) = element.value, values.count == 1, values[0].utf8.count <= 16 else { return nil }
            let origin = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            return ["FRAME", "VOLUME"].contains(origin) ? origin : nil
        }

        mutating func count(_ target: DicomDataSet, tag: Int, vr: DicomVR,
                            path: [DicomValidationReport.PathComponent]) -> Int? {
            guard consume(path: path) else { return nil }
            guard let element = target[tag], element.vr == vr else {
                record(.valueUnavailable, severity: .limitation, path: path); return nil
            }
            guard element.vm.count == 1 else { record(.referenceTargetGeometryInvalid, path: path); return nil }
            let maximum = vr == .UL ? Int(UInt32.max) : Int(UInt16.max)
            let value: Int?
            switch element.value {
            case .unsignedIntegers(let numbers): value = numbers.first.flatMap(Int.init(exactly:))
            case .signedIntegers(let numbers): value = numbers.first
            default: record(.valueUnavailable, severity: .limitation, path: path); return nil
            }
            guard let value, (1...maximum).contains(value) else {
                record(.referenceTargetGeometryInvalid, path: path); return nil
            }
            return value
        }

        mutating func recordReference(_ code: DicomValidationReport.Code, severity: DicomValidationReport.Severity = .error,
                                      path: [DicomValidationReport.PathComponent]) {
            record(code, severity: severity, path: path, layer: .references)
        }

        mutating func matchedTarget(_ selected: DicomSRRelationshipValidator.SelectedItem, kind: DicomContentReferenceMacro.Kind = .image) -> (dataSet: DicomDataSet, selectionComplete: Bool)? {
            let sequencePath = selected.path + [.tag(0x00081199)]
            guard let sequence = selected.dataSet[0x00081199], sequence.vr == .SQ, case .sequence(let items) = sequence.value else {
                recordReference(.valueUnavailable, severity: .limitation, path: sequencePath); return nil
            }
            guard items.count == 1 else { recordReference(.sequenceItemCountInvalid, path: sequencePath); return nil }
            let pair = items[0].dataSet, path = sequencePath + [.item(0)]
            guard let sopClass = DicomSRReferenceMacro.uid(pair, tag: 0x00081150),
                  let instance = DicomSRReferenceMacro.uid(pair, tag: 0x00081155) else {
                recordReference(.valueUnavailable, severity: .limitation, path: path); return nil
            }
            guard let traits = DicomSOPReferenceTraits.entries[sopClass] else {
                recordReference(.referenceRuleUnavailable, severity: .limitation, path: path + [.tag(0x00081150)]); return nil
            }
            guard traits.kind == kind else { recordReference(.referenceSOPClassNotAllowed, path: path + [.tag(0x00081150)]); return nil }
            guard let target = targets[instance] else {
                recordReference(.referenceTargetUnavailable, severity: .limitation, path: path + [.tag(0x00081155)]); return nil
            }
            for (sourceTag, targetTag, expected) in [(0x00081150, 0x00080016, sopClass), (0x00081155, 0x00080018, instance)] {
                guard let actual = DicomSRReferenceMacro.uid(target, tag: targetTag) else {
                    recordReference(.valueUnavailable, severity: .limitation, path: path + [.tag(sourceTag)]); return nil
                }
                guard actual == expected else { recordReference(.referenceIdentityContradiction, path: path + [.tag(sourceTag)]); return nil }
            }
            var selection = DicomSRReferenceValidator.State(limits: .init(maximumDepth: limits.maximumDepth,
                maximumRuleEvaluations: limits.maximumRuleEvaluations - work, maximumDiagnostics: limits.maximumDiagnostics - diagnostics.count))
            selection.validateSelections(.init(instance: instance, sopClass: sopClass, study: nil, series: nil, group: 0,
                path: path, selection: pair, role: .content(kind), contentPath: nil), target: target)
            work += selection.work
            for diagnostic in selection.diagnostics {
                if diagnostic.code == .evaluationLimitReached { stop(diagnostic.path); return nil }
                record(diagnostic.code, severity: diagnostic.severity, path: diagnostic.path, layer: diagnostic.layer)
            }
            return stopped ? nil : (target, selection.diagnostics.isEmpty)
        }
    }
}
