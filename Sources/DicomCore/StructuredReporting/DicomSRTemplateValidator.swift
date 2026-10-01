import Foundation

/// Opt-in PS3.16 validation, separate from the SR content/relationship validator.
public enum DicomSRTemplateValidator {
    public static func validate(
        _ document: DicomSRDocument, template: String? = nil,
        supportMatrix: DicomSRSupportMatrix = .standard
    ) -> DicomSRTemplateValidationResult {
        let engine = Engine(document: document, supportMatrix: supportMatrix)
        let identifier = template ?? document.templateIdentifier
        guard let identifier, let definition = DicomSRTemplateRegistry.definition(for: identifier) else {
            engine.emit(.templateUnknown, tid: identifier ?? "", row: "", path: [])
            return engine.result
        }
        return validate(document, definition: definition, supportMatrix: supportMatrix)
    }

    public static func validate(
        _ document: DicomSRDocument, definition: DicomSRTemplateDefinition,
        supportMatrix: DicomSRSupportMatrix = .standard
    ) -> DicomSRTemplateValidationResult {
        let engine = Engine(document: document, supportMatrix: supportMatrix)
        let containsRoot = definition.rows.first?.valueType == .value("CONTAINER")
        let items: [(DicomSRContentItem, [Int])]
        if !containsRoot && document.root.valueType == "CONTAINER" {
            items = document.root.children.enumerated().map { ($0.element, [$0.offset]) }
        } else {
            items = [(document.root, [])]
        }
        engine.validateLevel(items: items, definition: definition, rows: definition.rows,
            relationship: nil, bindings: [:], depth: 0, ancestors: [:])
        return engine.result
    }

    private struct Candidate {
        let row: DicomSRTemplateRow
        let definition: DicomSRTemplateDefinition
        let children: [DicomSRTemplateRow]
        let relationship: String?
        let bindings: [String: DicomSRTemplateRow.ValueSet]
        let scope: Int
        let includes: [Int]
        let repeatable: Bool
    }

    private struct Inclusion {
        let row: DicomSRTemplateRow
        let definition: DicomSRTemplateDefinition
        let scope: Int
        let parentIncludes: [Int]
        let emptySatisfies: Bool
        let known: Bool
    }

    private final class Level {
        let items: [(DicomSRContentItem, [Int])]
        let definition: DicomSRTemplateDefinition
        let rows: [DicomSRTemplateRow]
        let relationship: String?
        let bindings: [String: DicomSRTemplateRow.ValueSet]
        let depth: Int
        let ancestors: [String: DicomSRContentItem]
        var candidates: [Candidate] = []
        var includes: [Inclusion] = []
        var nextScope = 0
        var siblingFacts: [Int: [String: [DicomSRContentItem]]] = [:]
        var matches: [[(DicomSRContentItem, [Int])]] = []
        var presence: [Int: [String: [DicomSRContentItem]]] = [:]
        var repeatedIncludes = Set<Int>()
        var path: [Int] { items.first?.1 ?? [] }

        init(items: [(DicomSRContentItem, [Int])], definition: DicomSRTemplateDefinition,
             rows: [DicomSRTemplateRow], relationship: String?,
             bindings: [String: DicomSRTemplateRow.ValueSet], depth: Int,
             ancestors: [String: DicomSRContentItem]) {
            self.items = items
            self.definition = definition
            self.rows = rows
            self.relationship = relationship
            self.bindings = bindings
            self.depth = depth
            self.ancestors = ancestors
        }
    }

    private final class Engine {
        let document: DicomSRDocument
        let supportMatrix: DicomSRSupportMatrix
        var result = DicomSRTemplateValidationResult()
        init(document: DicomSRDocument, supportMatrix: DicomSRSupportMatrix) {
            self.document = document
            self.supportMatrix = supportMatrix
        }

        private var work: [(Engine) -> Void] = []

        let referenceRelationships: Set<String> = [
            "HAS PROPERTIES", "INFERRED FROM", "SELECTED FROM", "HAS OBS CONTEXT", "HAS ACQ CONTEXT"
        ]

        func emit(_ kind: DicomSRTemplateDiagnostic.Kind, tid: String, row: String, path: [Int]) {
            let diagnostic = DicomSRTemplateDiagnostic(templateIdentifier: tid, rowID: row, path: path,
                kind: kind, message: "TID \(tid) row \(row) path \(path): \(kind.rawValue)")
            switch kind {
            case .templateUnknown, .contextGroupNotChecked, .customConditionNotEvaluated:
                if !result.limitations.contains(diagnostic) { result.limitations.append(diagnostic) }
            case .definedTermSubstituted, .extraItem: result.informational.append(diagnostic)
            default: result.errors.append(diagnostic)
            }
        }

        func same(_ a: DicomCodedConcept?, _ b: DicomCodedConcept) -> Bool {
            a?.codeValue == b.codeValue && a?.codingSchemeDesignator == b.codingSchemeDesignator
        }

        func bound(_ value: DicomSRTemplateRow.ValueSet,
                   _ bindings: [String: DicomSRTemplateRow.ValueSet]) -> DicomSRTemplateRow.ValueSet {
            switch value {
            case .parameter(let name), .unitsParameter(let name): return bindings[name] ?? .none
            default: return value
            }
        }

        func conceptScore(_ item: DicomSRContentItem, _ c: Candidate) -> Int? {
            switch c.row.concept {
            case .enumerated(let code): return same(item.conceptName, code) ? 4 : nil
            case .definedTerm(let code): return same(item.conceptName, code) ? 4 : 1
            case .parameter(let name):
                switch bound(.parameter(name), c.bindings) {
                case .definedTerms(let codes): return codes.contains(where: { same(item.conceptName, $0) }) ? 4 : nil
                case .units(let code): return same(item.conceptName, code) ? 4 : nil
                default: return 0
                }
            case .contextGroup, .any: return 0
            }
        }

        func relationMatches(_ item: DicomSRContentItem, _ relationship: String?) -> Bool {
            guard let relationship else { return true }
            let expectedReference = relationship.hasPrefix("R-")
            let base = expectedReference ? String(relationship.dropFirst(2)) : relationship
            let actual = item.relationshipType.map { $0.hasPrefix("R-") ? String($0.dropFirst(2)) : $0 }
            guard actual == base else { return false }
            if expectedReference && !item.isByReference { return false }
            return !item.isByReference || referenceRelationships.contains(base)
        }

        func optionalExpansion(_ definition: DicomSRTemplateDefinition, depth: Int = 0) -> Bool {
            guard depth < 32 else { return false }
            return definition.rows.filter { $0.nestingLevel == 0 }.allSatisfy { row in
                switch row.requirement {
                case .userOptional, .userConditional: return true
                default:
                    if case .include(let tid) = row.valueType,
                       let nested = DicomSRTemplateRegistry.definition(for: tid) {
                        return optionalExpansion(nested, depth: depth + 1)
                    }
                    return false
                }
            }
        }

        func expand(_ rows: [DicomSRTemplateRow], definition: DicomSRTemplateDefinition,
                             relationship: String?, bindings: [String: DicomSRTemplateRow.ValueSet],
                             scope: Int, parents: [Int], repeatable: Bool, depth: Int,
                             candidates: inout [Candidate], includes: inout [Inclusion], nextScope: inout Int) {
            guard depth < 32 else {
                emit(.includeMissing, tid: definition.identifier, row: "", path: [])
                return
            }
            guard let level = rows.first?.nestingLevel else { return }
            var index = 0
            while index < rows.count {
                let row = rows[index]
                let start = index + 1
                index = start
                while index < rows.count && rows[index].nestingLevel > level { index += 1 }
                let children = Array(rows[start..<index])
                let effectiveRelationship = row.relationship ?? relationship
                if case .include(let tid) = row.valueType {
                    let nested = DicomSRTemplateRegistry.definition(for: tid)
                    let includeIndex = includes.count
                    includes.append(Inclusion(row: row, definition: definition, scope: scope,
                        parentIncludes: parents, emptySatisfies: nested.map { optionalExpansion($0) } ?? false,
                        known: nested != nil))
                    guard let nested else { continue }
                    var parameters = bindings
                    for (name, value) in row.bindings { parameters[name] = bound(value, bindings) }
                    nextScope += 1
                    expand(nested.rows, definition: nested, relationship: effectiveRelationship,
                        bindings: parameters, scope: nextScope, parents: parents + [includeIndex],
                        repeatable: repeatable || row.vm == .oneOrMore, depth: depth + 1,
                        candidates: &candidates, includes: &includes, nextScope: &nextScope)
                } else {
                    candidates.append(Candidate(row: row, definition: definition, children: children,
                        relationship: effectiveRelationship, bindings: bindings, scope: scope,
                        includes: parents, repeatable: repeatable))
                }
            }
        }

        @inline(never)
        func validateLevel(items: [(DicomSRContentItem, [Int])], definition: DicomSRTemplateDefinition,
                                    rows: [DicomSRTemplateRow], relationship: String?,
                                    bindings: [String: DicomSRTemplateRow.ValueSet], depth: Int,
                                    ancestors: [String: DicomSRContentItem]) {
            prepare(Level(items: items, definition: definition, rows: rows, relationship: relationship,
                bindings: bindings, depth: depth, ancestors: ancestors))
            // Continuations keep depth-first diagnostic order without retaining native frames.
            while let next = work.popLast() { next(self) }
        }

        @inline(never)
        private func prepare(_ level: Level) {
            guard level.depth < 32 else {
                emit(.includeMissing, tid: level.definition.identifier, row: "", path: level.items.first?.1 ?? [])
                return
            }
            expand(level.rows, definition: level.definition, relationship: level.relationship, bindings: level.bindings,
                   scope: 0, parents: [], repeatable: false, depth: level.depth,
                   candidates: &level.candidates, includes: &level.includes, nextScope: &level.nextScope)
            collectSiblingFacts(level)
            level.matches = Array(repeating: [(DicomSRContentItem, [Int])](), count: level.candidates.count)
            for (original, path) in level.items { match(original, path: path, level: level) }
            var pending: [(Engine) -> Void] = []
            scheduleRepeatedIncludes(level, pending: &pending)
            pending.append { $0.checkInclusions(level) }
            for index in level.candidates.indices {
                pending.append { $0.checkCandidate(level, index: index) }
            }
            work.append(contentsOf: pending.reversed())
        }

        @inline(never)
        private func collectSiblingFacts(_ level: Level) {
            // Concept-specific sibling facts select among includes with overlapping rows
            // (for example CT pixel spacing in TID 1604 versus radiography in TID 1603).
            for c in level.candidates {
                for (item, _) in level.items {
                    if case .value(let vt) = c.row.valueType, item.valueType == vt,
                       conceptScore(item, c) == 4, relationMatches(item, c.relationship) {
                        level.siblingFacts[c.scope, default: [:]][c.row.id, default: []].append(item)
                    }
                }
            }
        }

        @inline(never)
        private func match(_ original: DicomSRContentItem, path: [Int], level: Level) {
            guard let item = resolve(original, path: path, level: level) else { return }
            var selected = select(item, original: original, level: level)
            if selected == nil {
                // Diagnose a malformed known row instead of treating it as an extension.
                selected = level.candidates.indices.first { index in
                    let c = level.candidates[index]
                    guard case .enumerated(let code) = c.row.concept else { return false }
                    return same(item.conceptName, code)
                }
                if let selected {
                    let c = level.candidates[selected]
                    if case .value(let vt) = c.row.valueType, vt != item.valueType {
                        emit(.valueTypeMismatch, tid: c.definition.identifier, row: c.row.id, path: path)
                    } else {
                        emit(.relationshipMismatch, tid: c.definition.identifier, row: c.row.id, path: path)
                    }
                } else if let index = level.candidates.indices.first(where: {
                    let c = level.candidates[$0]
                    if case .enumerated = c.row.concept, case .value(let vt) = c.row.valueType {
                        return vt == item.valueType && relationMatches(original, c.relationship)
                    }
                    return false
                }), level.candidates.count == 1 {
                    selected = index
                    emit(.conceptMismatch, tid: level.candidates[index].definition.identifier,
                         row: level.candidates[index].row.id, path: path)
                }
            }
            guard let selected else {
                emit(level.definition.isExtensible ? .extraItem : .notExtensibleExtraItem,
                     tid: level.definition.identifier, row: "", path: path)
                return
            }
            let c = level.candidates[selected]
            level.matches[selected].append((item, path))
            level.presence[c.scope, default: [:]][c.row.id, default: []].append(item)
            for includeIndex in c.includes {
                let inclusion = level.includes[includeIndex]
                level.presence[inclusion.scope, default: [:]][inclusion.row.id, default: []].append(item)
            }
        }

        @inline(never)
        private func resolve(_ original: DicomSRContentItem, path: [Int], level: Level) -> DicomSRContentItem? {
            var item = original
            if let identifier = original.referencedContentItemIdentifier {
                let permitted = [DicomSRDocument.comprehensiveSRStorageSOPClassUID,
                    DicomSRDocument.comprehensive3DSRStorageSOPClassUID].contains(document.sopClassUID ?? "")
                if !permitted || !referenceRelationships.contains(original.relationshipType ?? "") {
                    emit(.byReferenceNotPermitted, tid: level.definition.identifier, row: "", path: path)
                }
                guard let target = DicomSRSemanticValidator.referencedItem(in: document.root, identifier: identifier),
                      !target.isByReference, !([1] + path.map { $0 + 1 }).starts(with: identifier) else {
                    emit(.byReferenceUnresolved, tid: level.definition.identifier, row: "", path: path)
                    return nil
                }
                if let uid = document.sopClassUID,
                   let constraints = DicomSRRelationshipConstraints(rawValue: uid),
                   let parent = DicomSRSemanticValidator.referencedItem(in: document.root,
                       identifier: [1] + path.dropLast().map { $0 + 1 }),
                   !constraints.permits(source: parent.valueType, relationship: original.relationshipType ?? "",
                                        target: target.valueType, byReference: true) {
                    emit(.byReferenceNotPermitted, tid: level.definition.identifier, row: "", path: path)
                }
                item = target
            }
            return item
        }

        @inline(never)
        private func select(_ item: DicomSRContentItem, original: DicomSRContentItem, level: Level) -> Int? {
            var selected: Int?
            var best = -1
            for (index, candidate) in level.candidates.enumerated() {
                guard case .value(let vt) = candidate.row.valueType, item.valueType == vt,
                      relationMatches(original, candidate.relationship),
                      let score = conceptScore(item, candidate) else { continue }
                if let identification = item.contentTemplate,
                   candidate.row.nestingLevel == 0,
                   identification.templateIdentifier != candidate.definition.identifier { continue }
                // Explicit R-rows take precedence for references; exact concepts beat wildcard rows.
                let eligible = candidate.includes.allSatisfy { index in
                    let include = level.includes[index]
                    switch include.row.requirement {
                    case .mandatoryConditional(let rule), .userConditional(let rule):
                        return condition(rule, row: include.row.id,
                            presence: level.siblingFacts[include.scope] ?? [:], ancestors: level.ancestors) != false
                    default: return true
                    }
                }
                let conditional: Bool
                switch candidate.row.requirement {
                case .mandatoryConditional(let rule), .userConditional(let rule):
                    conditional = condition(rule, row: candidate.row.id,
                        presence: level.siblingFacts[candidate.scope] ?? [:], ancestors: level.ancestors) == true
                default: conditional = false
                }
                let ranked = (eligible ? 100 : 0) + score * 10 + (conditional ? 2 : 0) + (candidate.relationship?.hasPrefix("R-") == true ? 1 : 0)
                if ranked > best { selected = index; best = ranked }
            }
            return selected
        }

        @inline(never)
        private func scheduleRepeatedIncludes(_ level: Level, pending: inout [(Engine) -> Void]) {
            for (includeIndex, inclusion) in level.includes.enumerated() {
                guard inclusion.row.vm == .oneOrMore,
                      case .include(let tid) = inclusion.row.valueType,
                      let nested = DicomSRTemplateRegistry.definition(for: tid),
                      nested.rows.filter({ $0.nestingLevel == 0 }).count > 1,
                      !inclusion.parentIncludes.contains(where: { level.repeatedIncludes.contains($0) }) else { continue }
                level.repeatedIncludes.insert(includeIndex)
                let owned = level.candidates.indices.filter { level.candidates[$0].includes.contains(includeIndex) }
                let matched = owned.flatMap { index in level.matches[index].map {
                    ($0.0, $0.1, level.candidates[index].definition.identifier + ":" + level.candidates[index].row.id)
                } }
                    .sorted { $0.1.lexicographicallyPrecedes($1.1) }
                var invocations: [[(DicomSRContentItem, [Int])]] = []
                var rowIDs = Set<String>()
                for (item, itemPath, rowID) in matched {
                    // IMAGE/COMPOSITE/WAVEFORM are alternative roots of one TID 1601 invocation.
                    let begins = tid == "1601" || rowID == tid + ":" + (nested.rows.first?.id ?? "") || rowIDs.contains(rowID)
                    if invocations.isEmpty || begins { invocations.append([]); rowIDs.removeAll() }
                    invocations[invocations.count - 1].append((item, itemPath))
                    rowIDs.insert(rowID)
                }
                let parameters = owned.first.map { level.candidates[$0].bindings } ?? level.bindings
                for invocation in invocations {
                    pending.append { engine in
                        engine.prepare(Level(items: invocation, definition: nested, rows: nested.rows,
                        relationship: inclusion.row.relationship ?? level.relationship, bindings: parameters,
                        depth: level.depth + 1, ancestors: level.ancestors))
                    }
                }
            }
        }

        @inline(never)
        private func checkInclusions(_ level: Level) {
            let path = level.path
            for inclusion in level.includes {
                if inclusion.parentIncludes.contains(where: { level.repeatedIncludes.contains($0) }) { continue }
                let count = level.presence[inclusion.scope]?[inclusion.row.id]?.count ?? 0
                let activeParents = inclusion.parentIncludes.allSatisfy {
                    let p = level.includes[$0]
                    return !(level.presence[p.scope]?[p.row.id] ?? []).isEmpty
                }
                guard activeParents else { continue }
                if !inclusion.known {
                    if case .mandatoryConditional(let condition) = inclusion.row.requirement,
                       self.condition(condition, row: inclusion.row.id,
                                      presence: level.presence[inclusion.scope] ?? [:], ancestors: level.ancestors) == true {
                        emit(.templateUnknown, tid: inclusion.definition.identifier, row: inclusion.row.id, path: path)
                    } else if case .mandatory = inclusion.row.requirement {
                        emit(.includeMissing, tid: inclusion.definition.identifier, row: inclusion.row.id, path: path)
                    }
                    continue
                }
                checkRequirement(inclusion.row, tid: inclusion.definition.identifier, count: count,
                    presence: level.presence[inclusion.scope] ?? [:], ancestors: level.ancestors, path: path,
                    emptySatisfies: inclusion.emptySatisfies)
            }
        }

        @inline(never)
        private func checkCandidate(_ level: Level, index: Int) {
            let c = level.candidates[index]
            let path = level.path
            if c.includes.contains(where: { level.repeatedIncludes.contains($0) }) { return }
            let active = c.includes.allSatisfy {
                let inclusion = level.includes[$0]
                return !(level.presence[inclusion.scope]?[inclusion.row.id] ?? []).isEmpty
            }
            guard active else { return }
            checkRequirement(c.row, tid: c.definition.identifier, count: level.matches[index].count,
                presence: level.presence[c.scope] ?? [:], ancestors: level.ancestors, path: path, emptySatisfies: false)
            if c.row.vm == .one && !c.repeatable && level.matches[index].count > 1 {
                emit(.cardinality, tid: c.definition.identifier, row: c.row.id, path: path)
            }
            for matchIndex in level.matches[index].indices.reversed() {
                work.append { $0.checkMatch(level, candidateIndex: index, matchIndex: matchIndex) }
            }
        }

        @inline(never)
        private func checkMatch(_ level: Level, candidateIndex: Int, matchIndex: Int) {
            let c = level.candidates[candidateIndex]
            let (item, itemPath) = level.matches[candidateIndex][matchIndex]
            checkValue(item, candidate: c, path: itemPath)
            var inherited = level.ancestors
            inherited[c.row.id] = item
            prepare(Level(items: item.children.enumerated().map { ($0.element, itemPath + [$0.offset]) },
                definition: c.definition, rows: c.children, relationship: nil, bindings: c.bindings,
                depth: level.depth + 1, ancestors: inherited))
        }

        func condition(_ condition: DicomSRTemplateRow.Condition, row: String,
                       presence: [String: [DicomSRContentItem]], ancestors: [String: DicomSRContentItem]) -> Bool? {
            let has: (String) -> Bool = { !(presence[$0] ?? []).isEmpty }
            switch condition {
            case .xor(let ids): return !ids.contains(where: has)
            case .iff(let id): return has(id)
            case .ifRowAbsent(let id): return !has(id)
            case .ifRowsAnyPresent(let ids): return ids.contains(where: has)
            case .ifRowValue(let id, let code): return (presence[id] ?? []).contains { same($0.codeValue, code) }
            case .ifRowConcept(let id, let code): return same(ancestors[id]?.conceptName, code)
            case .not(let value): return self.condition(value, row: row, presence: presence, ancestors: ancestors).map { !$0 }
            case .all(let values):
                let evaluated = values.map { self.condition($0, row: row, presence: presence, ancestors: ancestors) }
                if evaluated.contains(false) { return false }
                return evaluated.contains(nil) ? nil : true
            case .any(let values):
                let evaluated = values.map { self.condition($0, row: row, presence: presence, ancestors: ancestors) }
                if evaluated.contains(true) { return true }
                return evaluated.contains(nil) ? nil : false
            case .custom: return nil
            }
        }

        func checkRequirement(_ row: DicomSRTemplateRow, tid: String, count: Int,
                                       presence: [String: [DicomSRContentItem]],
                                       ancestors: [String: DicomSRContentItem], path: [Int], emptySatisfies: Bool) {
            switch row.requirement {
            case .mandatory:
                if count == 0 && !emptySatisfies { emit(.missingMandatory, tid: tid, row: row.id, path: path) }
            case .userOptional: break
            case .mandatoryConditional(let value), .userConditional(let value):
                guard let required = condition(value, row: row.id, presence: presence, ancestors: ancestors) else {
                    emit(.customConditionNotEvaluated, tid: tid, row: row.id, path: path)
                    return
                }
                let mandatory: Bool
                if case .mandatoryConditional = row.requirement { mandatory = true } else { mandatory = false }
                // IF absence/at-least-one conditions require presence but do not prohibit it otherwise.
                let prohibits: Bool
                switch value {
                case .ifRowAbsent, .not: prohibits = false
                case .all(let conditions):
                    prohibits = conditions.contains { if case .xor = $0 { return true }; return false }
                default: prohibits = true
                }
                let effectiveProhibits = prohibits && !(tid == "1002" && row.id == "1")
                if (required && mandatory && count == 0 && !emptySatisfies) || (!required && effectiveProhibits && count > 0) {
                    emit(.conditionViolated, tid: tid, row: row.id, path: path)
                }
            }
        }

        func checkValue(_ item: DicomSRContentItem, candidate c: Candidate, path: [Int]) {
            if case .definedTerm(let code) = c.row.concept, !same(item.conceptName, code) {
                emit(.definedTermSubstituted, tid: c.definition.identifier, row: c.row.id, path: path)
            }
            var group: Bool = false
            if case .contextGroup = c.row.concept { group = true }
            if case .parameter(let name) = c.row.concept, case .contextGroup = bound(.parameter(name), c.bindings) {
                group = true
            }
            switch bound(c.row.valueSet, c.bindings) {
            case .units(let code):
                if item.valueType == "NUM" && !same(item.measurementUnits, code) {
                    emit(.unitsMismatch, tid: c.definition.identifier, row: c.row.id, path: path)
                }
            case .definedTerms(let codes):
                if case .unitsParameter = c.row.valueSet, item.valueType == "NUM",
                   !codes.contains(where: { same(item.measurementUnits, $0) }) {
                    emit(.unitsMismatch, tid: c.definition.identifier, row: c.row.id, path: path)
                }
                if item.valueType == "CODE", !codes.contains(where: { same(item.codeValue, $0) }) {
                    emit(.definedTermSubstituted, tid: c.definition.identifier, row: c.row.id, path: path)
                }
            case .contextGroup: group = true
            default: break
            }
            if group { emit(.contextGroupNotChecked, tid: c.definition.identifier, row: c.row.id, path: path) }
        }
    }
}
