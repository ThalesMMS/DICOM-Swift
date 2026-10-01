import Foundation

/// PS3.3 C.17.2.3/C.17.6.2 content/evidence membership and supplied-target identity checks.
/// Checks declared SOP applicability and explicit frame/segment/channel selectors against supplied target metadata.
/// Does not fetch objects or replace content, full IOD/payload geometry or signature validation.
/// Compose DicomSRRelationshipValidator for intradocument by-reference targets and relationship tables.
public enum DicomSRReferenceValidator {
    public struct Result: Sendable {
        public let report: DicomValidationReport
        /// Only graph-provable conditions are resolved; all other provenance facts remain unknown.
        public let documentConditions: DicomSRDocumentModule.Conditions
        /// Target-derived facts keyed by original zero-based Content Sequence item paths; root is [].
        /// All/subset intent remains unknown. Compose with the author's facts before content attribute validation.
        public let contentReferenceConditions: [[Int]: DicomContentReferenceMacro.Conditions]
    }

    public static func validate(_ dataSet: DicomDataSet, kind: DicomSRDocumentModule.Kind,
                                targets: [String: DicomDataSet] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> Result {
        var state = State(limits: limits)
        state.content(dataSet, path: [], depth: 0)
        let contentComplete = state.malformed == 0 && !state.stopped
        let contentMalformed = state.malformed
        state.evidence(dataSet, tag: 0x0040A375)
        state.evidence(dataSet, tag: 0x0040A385)
        let evidenceComplete = state.malformed == contentMalformed && !state.stopped
        state.compare(kind: kind, contentComplete: contentComplete, evidenceComplete: evidenceComplete)
        var conditions = DicomSRDocumentModule.Conditions()
        if !state.contentReferences.isEmpty { conditions.currentProcedureEvidenceRequired = .satisfied }
        // C.17.2: evidence outside the current procedure's list must be recorded as pertinent other evidence.
        if contentComplete && evidenceComplete && !state.stopped {
            let current = Set(state.evidenceReferences.filter { $0.group == 0x0040A375 }.map(\.instance))
            conditions.pertinentOtherEvidenceRequired = state.contentReferences.allSatisfy { current.contains($0.instance) } ? .unsatisfied : .satisfied
        }
        if kind == .keyObjectSelection {
            let studies = Set(state.evidenceReferences.filter { $0.group == 0x0040A375 }.compactMap(\.study))
            if studies.count > 1 {
                conditions.identicalDocumentsRequired = .satisfied
            } else if contentComplete && evidenceComplete && !state.contentReferences.isEmpty && !state.stopped {
                let known = Set(state.evidenceReferences.filter { $0.group == 0x0040A375 }.map(\.instance))
                if state.contentReferences.allSatisfy({ known.contains($0.instance) }) {
                    conditions.identicalDocumentsRequired = .unsatisfied
                }
            }
        }
        state.resolve(targets: targets)
        // These relations need additional semantic/provenance validators before references can pass.
        for tag in [0x0040A360, 0x0040A525, 0x0008114A] where dataSet.contains(tag) {
            state.record(.referenceRuleUnavailable, severity: .limitation, path: [.tag(tag)])
        }
        return .init(report: .init(evaluatedLayers: [.references], diagnostics: state.diagnostics), documentConditions: conditions,
                     contentReferenceConditions: state.contentReferenceConditions)
    }

    enum Role {
        case content(DicomContentReferenceMacro.Kind)
        case softcopyPresentationState, realWorldValueMapping, nonImage, unqualified, evidence
    }

    struct Reference {
        let instance: String
        let sopClass: String
        var study: String?
        var series: String?
        let group: Int
        let path: [DicomValidationReport.PathComponent]
        let selection: DicomDataSet
        let role: Role
        let contentPath: [Int]?
    }

    struct State {
        static let contentTypes: Set<String> = ["CONTAINER", "TEXT", "CODE", "NUM", "DATE", "TIME", "DATETIME", "PNAME", "UIDREF",
            "IMAGE", "COMPOSITE", "WAVEFORM", "SCOORD", "SCOORD3D", "TCOORD"]
        let limits: DicomAttributeValidator.Limits
        var diagnostics: [DicomValidationReport.Diagnostic] = []
        var contentReferences: [Reference] = []
        var evidenceReferences: [Reference] = []
        var contentReferenceConditions: [[Int]: DicomContentReferenceMacro.Conditions] = [:]
        var work = 0
        var malformed = 0
        var stopped = false

        mutating func visit(_ path: [DicomValidationReport.PathComponent], depth: Int) -> Bool {
            guard !stopped else { return false }
            guard depth <= limits.maximumDepth, work < limits.maximumRuleEvaluations,
                  diagnostics.count < limits.maximumDiagnostics else {
                stop(path)
                return false
            }
            work += 1
            return true
        }

        mutating func stop(_ path: [DicomValidationReport.PathComponent]) {
            guard !stopped else { return }
            diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .references, path: path))
            stopped = true
        }

        mutating func record(_ code: DicomValidationReport.Code, severity: DicomValidationReport.Severity = .error,
                             path: [DicomValidationReport.PathComponent]) {
            guard !stopped else { return }
            guard diagnostics.count < limits.maximumDiagnostics else { stop(path); return }
            diagnostics.append(.init(code: code, severity: severity, layer: .references, path: path))
        }

        mutating func items(_ dataSet: DicomDataSet, tag: Int,
                            path: [DicomValidationReport.PathComponent]) -> [DicomSequenceItem] {
            guard let element = dataSet[tag] else { return [] }
            if element.vr == .SQ, case .sequence(let items) = element.value { return items }
            if element.vr == .SQ, case .empty = element.value { return [] }
            malformed += 1
            record(element.vr == .UN ? .valueUnavailable : .sequenceExpected,
                   severity: element.vr == .UN ? .limitation : .error, path: path + [.tag(tag)])
            return []
        }

        func uid(_ dataSet: DicomDataSet, tag: Int) -> String? {
            DicomSRReferenceMacro.uid(dataSet, tag: tag)
        }

        mutating func reference(_ dataSet: DicomDataSet, path: [DicomValidationReport.PathComponent],
                                role: Role = .evidence, contentPath: [Int]? = nil, group: Int = 0, study: String? = nil, series: String? = nil) -> Reference? {
            guard let sopClass = uid(dataSet, tag: 0x00081150), let instance = uid(dataSet, tag: 0x00081155) else {
                malformed += 1
                record(.valueUnavailable, severity: .limitation, path: path)
                return nil
            }
            for tag in [0x04000402, 0x04000403] where dataSet.contains(tag) {
                record(.referenceRuleUnavailable, severity: .limitation, path: path + [.tag(tag)])
            }
            let selection = DicomDataSet(elements: [0x00081160, 0x0062000B, 0x0040A0B0].compactMap { dataSet[$0] })
            return .init(instance: instance, sopClass: sopClass, study: study, series: series, group: group,
                         path: path, selection: selection, role: role, contentPath: contentPath)
        }

        mutating func content(_ dataSet: DicomDataSet, path: [DicomValidationReport.PathComponent], depth: Int) {
            guard visit(path, depth: depth) else { return }
            // By-reference edges introduce no new external SOP objects; their by-value targets are visited once.
            // Intradocument validity belongs to DicomSRRelationshipValidator.
            var referenceKind: DicomContentReferenceMacro.Kind?
            if !dataSet.contains(0x0040DB73) {
                if let element = dataSet[0x0040A040], element.vr == .CS, case .strings(let values) = element.value,
                   values.count == 1, values[0].utf8.count <= 16,
                   Self.contentTypes.contains(values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))) {
                    referenceKind = DicomContentReferenceMacro.Kind(rawValue:
                        values[0].trimmingCharacters(in: CharacterSet(charactersIn: " ")))
                } else {
                    malformed += 1
                    record(.referenceRuleUnavailable, severity: .limitation, path: path + [.tag(0x0040A040)])
                }
            }
            contentSOPs(dataSet, path: path, depth: depth, kind: referenceKind)
            for (index, item) in items(dataSet, tag: 0x0040A730, path: path).enumerated() {
                guard !stopped else { return }
                content(item.dataSet, path: path + [.tag(0x0040A730), .item(index)], depth: depth + 1)
            }
        }

        mutating func contentSOPs(_ dataSet: DicomDataSet, path: [DicomValidationReport.PathComponent], depth: Int,
                                  kind: DicomContentReferenceMacro.Kind? = nil, imageCompanions: Bool = false) {
            for tag in [0x00081199, 0x0008114B] {
                let pairs = items(dataSet, tag: tag, path: path)
                for (index, item) in pairs.enumerated() {
                    let location = path + [.tag(tag), .item(index)]
                    guard visit(location, depth: depth + 1) else { return }
                    let role: Role
                    if let kind, tag == 0x00081199 { role = .content(kind) }
                    else if imageCompanions { role = tag == 0x00081199 ? .softcopyPresentationState : .realWorldValueMapping }
                    else { role = .unqualified }
                    let contentPath: [Int]? = kind != nil && tag == 0x00081199 && pairs.count == 1 ? path.compactMap {
                        if case .item(let index) = $0 { return index }; return nil
                    } : nil
                    if let reference = reference(item.dataSet, path: location, role: role, contentPath: contentPath) {
                        contentReferences.append(reference)
                    }
                    // Only immediate companions of the primary IMAGE pair have C.18.4 semantics.
                    contentSOPs(item.dataSet, path: location, depth: depth + 1,
                                imageCompanions: kind == .image && tag == 0x00081199)
                }
            }
        }

        mutating func evidence(_ dataSet: DicomDataSet, tag: Int) {
            for (studyIndex, studyItem) in items(dataSet, tag: tag, path: []).enumerated() {
                let studyPath: [DicomValidationReport.PathComponent] = [.tag(tag), .item(studyIndex)]
                guard visit(studyPath, depth: 1) else { return }
                let study = uid(studyItem.dataSet, tag: 0x0020000D)
                if study == nil { malformed += 1; record(.valueUnavailable, severity: .limitation, path: studyPath + [.tag(0x0020000D)]) }
                for (seriesIndex, seriesItem) in items(studyItem.dataSet, tag: 0x00081115, path: studyPath).enumerated() {
                    let seriesPath = studyPath + [.tag(0x00081115), .item(seriesIndex)]
                    guard visit(seriesPath, depth: 2) else { return }
                    let series = uid(seriesItem.dataSet, tag: 0x0020000E)
                    if series == nil { malformed += 1; record(.valueUnavailable, severity: .limitation, path: seriesPath + [.tag(0x0020000E)]) }
                    for (index, item) in items(seriesItem.dataSet, tag: 0x00081199, path: seriesPath).enumerated() {
                        let location = seriesPath + [.tag(0x00081199), .item(index)]
                        guard visit(location, depth: 3) else { return }
                        if let reference = reference(item.dataSet, path: location, group: tag, study: study, series: series) {
                            evidenceReferences.append(reference)
                        }
                    }
                }
            }
        }

        mutating func compareEvidence() -> [String: Reference] {
            var known: [String: Reference] = [:]
            var seriesStudies: [String: String] = [:]
            for reference in evidenceReferences {
                guard visit(reference.path, depth: 0) else { return known }
                if var previous = known[reference.instance] {
                    if previous.group != reference.group {
                        record(.referenceEvidenceConflict, path: reference.path + [.tag(0x00081155)])
                    }
                    let studyConflict = previous.study != nil && reference.study != nil && previous.study != reference.study
                    let seriesConflict = previous.series != nil && reference.series != nil && previous.series != reference.series
                    if previous.sopClass != reference.sopClass || studyConflict || seriesConflict {
                        record(.referenceIdentityContradiction, path: reference.path)
                    }
                    // Retain known fields so an earlier omission cannot hide a later conflict.
                    previous.study = previous.study ?? reference.study
                    previous.series = previous.series ?? reference.series
                    known[reference.instance] = previous
                } else { known[reference.instance] = reference }
                if let combined = known[reference.instance], let series = combined.series, let study = combined.study {
                    if let previous = seriesStudies[series], previous != study {
                        record(.referenceIdentityContradiction, path: reference.path)
                    } else { seriesStudies[series] = study }
                }
            }
            return known
        }

        mutating func compare(kind: DicomSRDocumentModule.Kind, contentComplete: Bool, evidenceComplete: Bool) {
            let known = compareEvidence()
            guard !stopped else { return }
            var contentInstances: Set<String> = []
            var contentClasses: [String: String] = [:]
            for reference in contentReferences {
                guard visit(reference.path, depth: 0) else { return }
                contentInstances.insert(reference.instance)
                if let previous = contentClasses[reference.instance], previous != reference.sopClass {
                    record(.referenceIdentityContradiction, path: reference.path + [.tag(0x00081150)])
                } else { contentClasses[reference.instance] = reference.sopClass }
                if let evidence = known[reference.instance], kind == .structuredReport || evidence.group == 0x0040A375 {
                    if evidence.sopClass != reference.sopClass {
                        record(.referenceIdentityContradiction, path: reference.path + [.tag(0x00081150)])
                    }
                } else if evidenceComplete {
                    record(.referenceEvidenceMissing, path: reference.path + [.tag(0x00081155)])
                }
            }
            if kind == .keyObjectSelection && contentComplete {
                for reference in evidenceReferences where reference.group == 0x0040A375 && !contentInstances.contains(reference.instance) {
                    guard visit(reference.path, depth: 0) else { return }
                    record(.referenceEvidenceUnexpected, path: reference.path + [.tag(0x00081155)])
                }
            }
        }

        /// A known incompatible declared class fails even when its target cannot be retrieved.
        mutating func validateApplicability(_ reference: Reference) -> Bool {
            switch reference.role {
            case .evidence: return true // Evidence membership imposes no IMAGE/WAVEFORM/COMPOSITE role.
            case .unqualified:
                record(.referenceRuleUnavailable, severity: .limitation, path: reference.path)
                return false
            default: break
            }
            let path = reference.path + [.tag(0x00081150)]
            guard let traits = DicomSOPReferenceTraits.entries[reference.sopClass] else {
                record(.referenceRuleUnavailable, severity: .limitation, path: path)
                return false
            }
            let allowed: Bool
            switch reference.role {
            case .content(let kind): allowed = traits.kind == kind
            case .softcopyPresentationState: allowed = traits.isSoftcopyPresentationState
            case .realWorldValueMapping: allowed = traits.isRealWorldValueMapping
            case .nonImage: allowed = traits.kind != .image
            case .unqualified, .evidence: return false
            }
            if !allowed { record(.referenceSOPClassNotAllowed, path: path) }
            return allowed
        }

        /// With no target supplied at all, no reference resolves: that is one limitation of the whole object (empty
        /// path), so an object with many references keeps its diagnostic budget (Isis issue #2516). A reference
        /// missing from supplied targets is reported where it is.
        mutating func resolve(targets: [String: DicomDataSet]) {
            var unsuppliedRecorded = false
            for reference in contentReferences + evidenceReferences {
                guard visit(reference.path, depth: 0) else { return }
                let applicable = validateApplicability(reference)
                guard let target = targets[reference.instance] else {
                    if !targets.isEmpty {
                        record(.referenceTargetUnavailable, severity: .limitation, path: reference.path + [.tag(0x00081155)])
                    } else if !unsuppliedRecorded {
                        record(.referenceTargetUnavailable, severity: .limitation, path: [])
                        unsuppliedRecorded = true
                    }
                    validateSelections(reference, target: nil)
                    continue
                }
                let expected = [(0x00080018, reference.instance), (0x00080016, reference.sopClass),
                                (0x0020000D, reference.study), (0x0020000E, reference.series)]
                var identityMatches = true
                for (tag, value) in expected {
                    guard let value else { continue }
                    guard let actual = uid(target, tag: tag) else {
                        identityMatches = false
                        record(.valueUnavailable, severity: .limitation, path: reference.path)
                        continue
                    }
                    if actual != value {
                        identityMatches = false
                        record(.referenceIdentityContradiction, path: reference.path)
                    }
                }
                let matched = identityMatches && applicable ? target : nil
                validateSelections(reference, target: matched)
                if let matched { deriveContentConditions(reference, target: matched) }
            }
        }
    }
}
