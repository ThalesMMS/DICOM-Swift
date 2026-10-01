import Foundation

public enum CDAValidationSeverity: String, Codable, CaseIterable, Sendable {
    case error
    case warning
    case info
}

public struct CDAValidationFinding: Codable, Equatable, Sendable {
    public let constraintID: String
    public let path: String
    public let severity: CDAValidationSeverity
    public let code: String
    /// Deliberately content-free.  It contains only structural counts, code
    /// values, or datatype names; narrative text and person/organization names
    /// are never copied into a report.
    public let detail: String

    public init(constraintID: String, path: String, severity: CDAValidationSeverity,
                code: String, detail: String) {
        self.constraintID = constraintID
        self.path = path
        self.severity = severity
        self.code = code
        self.detail = detail
    }

    public var id: String { constraintID }
}

public typealias CDAFinding = CDAValidationFinding

public struct CDAValidationCoverage: Codable, Equatable, Sendable {
    public var evaluated: Int
    public var notEvaluable: Int
    public var evaluatedConstraintIDs: [String]
    public var notEvaluableConstraintIDs: [String]

    public init(evaluated: Int = 0, notEvaluable: Int = 0,
                evaluatedConstraintIDs: [String] = [], notEvaluableConstraintIDs: [String] = []) {
        self.evaluated = evaluated
        self.notEvaluable = notEvaluable
        self.evaluatedConstraintIDs = evaluatedConstraintIDs
        self.notEvaluableConstraintIDs = notEvaluableConstraintIDs
    }

    public var constraintsEvaluated: Int { evaluated }
    public var constraintsNotEvaluable: Int { notEvaluable }
    public var total: Int { evaluated + notEvaluable }
    public var evaluatedIDs: [String] { evaluatedConstraintIDs }
    public var notEvaluableIDs: [String] { notEvaluableConstraintIDs }

    fileprivate mutating func recordEvaluated(_ constraintID: String) {
        evaluated += 1
        if !evaluatedConstraintIDs.contains(constraintID) { evaluatedConstraintIDs.append(constraintID) }
    }

    fileprivate mutating func recordNotEvaluable(_ constraintID: String) {
        notEvaluable += 1
        if !notEvaluableConstraintIDs.contains(constraintID) { notEvaluableConstraintIDs.append(constraintID) }
    }
}

public struct CDAValidationReport: Codable, Equatable, Sendable {
    public var findings: [CDAValidationFinding]
    public var coverage: CDAValidationCoverage

    public init(findings: [CDAValidationFinding] = [], coverage: CDAValidationCoverage = .init()) {
        self.findings = findings
        self.coverage = coverage
    }

    public var isValid: Bool { !findings.contains { $0.severity == .error } }
    public var errors: [CDAValidationFinding] { findings.filter { $0.severity == .error } }
    public var warnings: [CDAValidationFinding] { findings.filter { $0.severity == .warning } }
    public var infos: [CDAValidationFinding] { findings.filter { $0.severity == .info } }
    public var violations: [CDAValidationFinding] { findings }
    public var evaluated: Int { coverage.evaluated }
    public var notEvaluable: Int { coverage.notEvaluable }
    public var evaluatedConstraintCount: Int { coverage.evaluated }
    public var notEvaluableConstraintCount: Int { coverage.notEvaluable }
    public var evaluatedConstraintIDs: [String] { coverage.evaluatedConstraintIDs }
    public var notEvaluableConstraintIDs: [String] { coverage.notEvaluableConstraintIDs }
}

/// Deterministic structural validator for the template subset.  It intentionally
/// does not attempt to be an XPath or complete C-CDA validator.
public struct CDAValidator: Sendable {
    public var templates: CDATemplateRegistry

    public init(templates: CDATemplateRegistry = .builtIn) { self.templates = templates }

    public func validate(_ document: ClinicalDocument,
                         against references: [CDATemplateReference]? = nil) -> CDAValidationReport {
        var report = CDAValidationReport()
        let rootPath = "/" + document.node.name.localName
        let allCursors = cursors(in: document.node, path: rootPath)

        let discovered = templateReferences(in: document.node, cursors: allCursors)
        let selected: [CDATemplateReference]
        if let references {
            selected = references
        } else {
            selected = discovered.map(\.reference)
        }

        // Unknown template IDs are always visible, including template IDs on a
        // section or entry that is otherwise outside the selected set.
        for item in discovered where templates.template(for: item.reference) == nil {
            add(&report, constraintID: "templateId.known", path: item.path,
                severity: .error, code: "unknownTemplate", detail: "template id is not registered")
        }

        var seenSelection = Set<String>()
        for reference in selected {
            let key = reference.description
            guard seenSelection.insert(key).inserted else { continue }
            guard let raw = templates.template(for: reference) else {
                // Explicit references need a finding even if no corresponding
                // templateId exists in the document.
                if !discovered.contains(where: { $0.reference.matches(reference) || reference.matches($0.reference) }) {
                    add(&report, constraintID: "templateId.known", path: rootPath,
                        severity: .error, code: "unknownTemplate", detail: "template id is not registered")
                }
                continue
            }
            do {
                let composed = try templates.composedTemplate(for: raw.id)
                let targets = targetCursors(for: composed, in: document.node, rootPath: rootPath, all: allCursors)
                if targets.isEmpty && references != nil {
                    add(&report, constraintID: "template.target", path: rootPath,
                        severity: .warning, code: "templateNotPresent", detail: "actual count 0")
                }
                for target in targets {
                    for constraint in composed.constraints {
                        evaluate(constraint, on: target, root: document.node, report: &report)
                    }
                }
            } catch let error as CDATemplateRegistryError {
                let code: String
                let detail: String
                switch error {
                case .inheritanceCycle: code = "templateInheritanceCycle"; detail = "inheritance cycle"
                case .unknownTemplate: code = "unknownTemplate"; detail = "template id is not registered"
                case .duplicateTemplate: code = "templateRegistryError"; detail = "duplicate template"
                }
                add(&report, constraintID: "template.registry", path: rootPath, severity: .error, code: code, detail: detail)
            } catch {
                add(&report, constraintID: "template.registry", path: rootPath, severity: .error,
                    code: "templateRegistryError", detail: "template resolution failed")
            }
        }

        // Link checks are global and complement the narrativeLinked rule.  The
        // paths returned by Lot A are structural and contain no identifier text.
        for finding in document.validateLinks() {
            switch finding.kind {
            case .duplicateID:
                add(&report, constraintID: "global.uniqueID", path: finding.path,
                    severity: .error, code: "duplicateID", detail: "actual count 2")
            case .dangling:
                add(&report, constraintID: "global.narrativeLink", path: finding.path,
                    severity: .error, code: "danglingNarrativeLink", detail: "actual reference is unresolved")
            case .cycle:
                add(&report, constraintID: "global.narrativeLink", path: finding.path,
                    severity: .error, code: "narrativeLinkCycle", detail: "reference cycle")
            }
        }
        return report
    }

    private struct DiscoveredTemplate {
        let reference: CDATemplateReference
        let path: String
    }

    private struct Cursor {
        let node: XMLNode
        let path: String
    }

    private struct Match {
        let node: XMLNode
        let path: String
        let value: String?
        let isAttribute: Bool
    }

    private func cursors(in root: XMLNode, path: String) -> [Cursor] {
        var result: [Cursor] = []
        var pending: [Cursor] = [Cursor(node: root, path: path)]
        while let current = pending.popLast() {
            result.append(current)
            for (index, child) in current.node.children.enumerated().reversed() {
                pending.append(Cursor(node: child, path: current.path + "/" + child.name.localName + "[\(index + 1)]"))
            }
        }
        return result
    }

    private func templateReferences(in root: XMLNode, cursors: [Cursor]) -> [DiscoveredTemplate] {
        var result: [DiscoveredTemplate] = []
        for cursor in cursors where cursor.node.name.localName == "templateId" {
            guard let rootValue = cursor.node[attribute: "root"], !rootValue.isEmpty else { continue }
            result.append(.init(reference: .init(root: rootValue,
                                                 extension: cursor.node[attribute: "extension"],
                                                 versionDate: cursor.node[attribute: "validTime"]),
                                path: cursor.path))
        }
        return result
    }

    private func targetCursors(for template: CDATemplate, in root: XMLNode, rootPath: String, all: [Cursor]) -> [Cursor] {
        switch template.kind {
        case .document:
            return [Cursor(node: root, path: rootPath)]
        case .section:
            return all.filter { $0.node.name.localName == "section" && hasTemplate(template.id, in: $0.node) }
        case .entry:
            return all.filter {
                ["act", "observation", "substanceAdministration", "organizer", "procedure", "encounter", "supply"].contains($0.node.name.localName) &&
                    hasTemplate(template.id, in: $0.node)
            }
        }
    }

    private func hasTemplate(_ reference: CDATemplateReference, in node: XMLNode) -> Bool {
        node.elements("templateId").contains { child in
            guard let root = child[attribute: "root"] else { return false }
            let candidate = CDATemplateReference(root: root, extension: child[attribute: "extension"],
                                                 versionDate: child[attribute: "validTime"])
            return candidate.matches(reference) || reference.matches(candidate)
        }
    }

    private func evaluate(_ constraint: CDAConstraint, on context: Cursor, root: XMLNode,
                          report: inout CDAValidationReport) {
        guard isSupported(constraint.path) else {
            report.coverage.recordNotEvaluable(constraint.id)
            add(&report, constraintID: constraint.id, path: context.path, severity: .warning,
                code: "pathNotEvaluable", detail: "path is outside supported subset")
            return
        }
        if let customIdentifier = constraint.customIdentifier, constraint.custom == nil {
            report.coverage.recordNotEvaluable(constraint.id)
            add(&report, constraintID: customIdentifier, path: context.path, severity: .warning,
                code: "customRuleNotEvaluated", detail: "custom rule is not installed")
            return
        }
        report.coverage.recordEvaluated(constraint.id)

        if let conditional = constraint.conditional {
            let condition = !evaluatePath(conditional.when, from: context).isEmpty
            let branch = condition ? conditional.thenConstraints : conditional.elseConstraints
            for nested in branch { evaluate(nested, on: context, root: root, report: &report) }
        }

        let matches = evaluatePath(constraint.path, from: context)
        if let cardinality = constraint.cardinality {
            let count = matches.count
            let tooFew = count < cardinality.minimum
            let tooMany = cardinality.maximum.map { count > $0 } ?? false
            if tooFew || tooMany {
                let expected = cardinality.maximum.map { "\(cardinality.minimum)..\($0)" } ?? "\(cardinality.minimum)..*"
                add(&report, constraintID: constraint.id, path: context.path + relativePath(constraint.path),
                    severity: .error, code: "cardinalityViolation",
                    detail: "expected \(expected); actual \(count)")
            }
        }

        if let fixed = constraint.fixedValue {
            if matches.isEmpty, constraint.cardinality == nil {
                let path = context.path + relativePath(constraint.path)
                add(&report, constraintID: constraint.id, path: path, severity: .error,
                    code: "fixedValueMismatch", detail: "expected fixed value; actual missing")
            }
            for match in matches {
                let actual = actualValue(for: match)
                if actual != fixed {
                    let detail = constraint.path.rawValue.contains("@code") || match.node.name.localName == "code" || match.node.name.localName == "templateId" ?
                        "expected \(fixed); actual \(actual ?? "missing")" : "expected fixed value; actual mismatch"
                    add(&report, constraintID: constraint.id, path: match.path,
                        severity: .error, code: "fixedValueMismatch", detail: detail)
                }
            }
        }

        if let dataType = constraint.dataType {
            let expectedType = dataType.split(separator: ":").last.map(String.init) ?? dataType
            for match in matches {
                let actual = resolvedType(of: match.node)
                if actual != expectedType {
                    add(&report, constraintID: constraint.id, path: match.path,
                        severity: .error, code: "dataTypeMismatch",
                        detail: "expected \(expectedType); actual \(actual ?? "missing")")
                }
            }
        }

        if let policy = constraint.nullFlavorPolicy {
            if policy == .required && matches.isEmpty {
                add(&report, constraintID: constraint.id, path: context.path + relativePath(constraint.path),
                    severity: .error, code: "nullFlavorRequired", detail: "expected nullFlavor present; actual absent")
            }
            for match in matches {
                let nullFlavor = match.node[attribute: "nullFlavor"]
                switch policy {
                case .allowed: break
                case .forbidden where nullFlavor != nil:
                    add(&report, constraintID: constraint.id, path: match.path,
                        severity: .error, code: "nullFlavorForbidden", detail: "expected nullFlavor absent; actual present")
                case .required where nullFlavor == nil:
                    add(&report, constraintID: constraint.id, path: match.path,
                        severity: .error, code: "nullFlavorRequired", detail: "expected nullFlavor present; actual absent")
                default: break
                }
            }
        }

        if let valueSet = constraint.valueSet {
            for match in matches {
                guard let actual = codeValue(for: match) else { continue }
                let codeMatches = valueSet.codes.isEmpty || valueSet.codes.contains(actual)
                let systemMatches = valueSet.codeSystem == nil || match.node[attribute: "codeSystem"] == valueSet.codeSystem
                guard !codeMatches || !systemMatches else { continue }
                let severity: CDAValidationSeverity = valueSet.binding == .required ? .error : (valueSet.binding == .extensible ? .warning : .info)
                let code = valueSet.binding == .preferred ? "valueSetPreferredMismatch" : "valueSetViolation"
                add(&report, constraintID: constraint.id, path: match.path, severity: severity, code: code,
                    detail: "expected code set; actual \(actual)")
            }
        }

        if constraint.narrativeLinked {
            for match in matches { validateNarrativeLink(match, root: root, report: &report, constraintID: constraint.id) }
        }

        if constraint.uniqueID {
            // Global ID duplication is also checked below; this rule gives a
            // profile-specific finding at the constrained path.
            var ids = Set<String>()
            for match in matches {
                if let identifier = identity(of: match.node), !ids.insert(identifier).inserted {
                    add(&report, constraintID: constraint.id, path: match.path, severity: .error,
                        code: "duplicateID", detail: "actual count 2")
                }
            }
        }

        if let custom = constraint.customIdentifier {
            guard let closure = constraint.custom else { return }
            let candidates = matches.isEmpty ? [Match(node: context.node, path: context.path, value: nil, isAttribute: false)] : matches
            for candidate in candidates where !closure(candidate.node) {
                add(&report, constraintID: custom, path: candidate.path, severity: .error,
                    code: "customRuleFailed", detail: "custom rule returned false")
            }
        }
    }

    private func isSupported(_ path: CDAPath) -> Bool {
        guard path.rawValue.isEmpty || path.rawValue == "." || !path.steps.isEmpty else { return false }
        return path.steps.allSatisfy { step in
            guard !step.name.isEmpty else { return false }
            if step.name.hasPrefix("@") {
                guard step.name.count > 1,
                      String(step.name.dropFirst()).range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { return false }
            } else if step.name != "." && step.name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) == nil {
                return false
            }
            guard step.index == nil || step.index! > 0 else { return false }
            return step.predicates.allSatisfy { predicate in
                switch predicate {
                case .equals(let path, _), .exists(let path):
                    let value = CDAPath(path)
                    guard value.rawValue.isEmpty || value.rawValue == "." || !value.steps.isEmpty else { return false }
                    return value.steps.allSatisfy {
                        if $0.name.hasPrefix("@") {
                            return $0.name.count > 1 && String($0.name.dropFirst()).range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
                        }
                        return $0.name == "." || $0.name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
                    }
                }
            }
        }
    }

    private func relativePath(_ path: CDAPath) -> String {
        path.rawValue.isEmpty || path.rawValue == "." ? "" : "/" + path.rawValue
    }

    private func evaluatePath(_ path: CDAPath, from context: Cursor) -> [Match] {
        if path.steps.isEmpty || path.rawValue == "." { return [Match(node: context.node, path: context.path, value: nil, isAttribute: false)] }
        var steps = path.steps
        if steps.first?.name == context.node.name.localName { steps.removeFirst() }
        if steps.isEmpty { return [Match(node: context.node, path: context.path, value: nil, isAttribute: false)] }
        var current = [Match(node: context.node, path: context.path, value: nil, isAttribute: false)]
        for step in steps {
            if step.name == "." {
                current = current.filter { item in
                    step.predicates.allSatisfy { predicate in predicateMatches(predicate, node: item.node) }
                }
                continue
            }
            if step.name.hasPrefix("@") {
                let attribute = String(step.name.dropFirst())
                current = current.compactMap { item in
                    guard let value = item.node[attribute: attribute] else { return nil }
                    return Match(node: item.node, path: item.path + "/@" + attribute, value: value, isAttribute: true)
                }
                continue
            }
            var next: [Match] = []
            for parent in current {
                var candidates: [Match] = []
                for (index, child) in parent.node.children.enumerated() where child.name.localName == step.name {
                    let childPath = parent.path + "/" + child.name.localName + "[\(index + 1)]"
                    guard step.predicates.allSatisfy({ predicateMatches($0, node: child) }) else { continue }
                    candidates.append(Match(node: child, path: childPath, value: nil, isAttribute: false))
                }
                if let index = step.index {
                    if candidates.indices.contains(index - 1) { next.append(candidates[index - 1]) }
                } else { next.append(contentsOf: candidates) }
            }
            current = next
        }
        return current
    }

    private func predicateMatches(_ predicate: CDAPathPredicate, node: XMLNode) -> Bool {
        let cursor = Cursor(node: node, path: "/" + node.name.localName)
        switch predicate {
        case .equals(let path, let expected):
            return evaluatePath(CDAPath(path), from: cursor).contains { actualValue(for: $0) == expected }
        case .exists(let path):
            return !evaluatePath(CDAPath(path), from: cursor).isEmpty
        }
    }

    private func actualValue(for match: Match) -> String? {
        if match.isAttribute { return match.value }
        if let nullFlavor = match.node[attribute: "nullFlavor"] { return nullFlavor }
        for attribute in ["code", "value", "root", "extension"] where match.node[attribute: attribute] != nil {
            return match.node[attribute: attribute]
        }
        let text = match.node.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func codeValue(for match: Match) -> String? {
        if match.isAttribute { return match.value }
        return match.node[attribute: "code"] ?? match.node[attribute: "value"]
    }

    private func resolvedType(of node: XMLNode) -> String? {
        if let explicit = node.schemaTypeName?.localName { return explicit }
        switch node.name.localName {
        case "effectiveTime", "birthTime", "time", "copyTime": return "TS"
        case "versionNumber": return "INT"
        case "code": return "CD"
        case "confidentialityCode", "administrativeGenderCode": return "CE"
        case "statusCode", "languageCode", "signatureCode": return "CS"
        default: return nil
        }
    }

    private func identity(of node: XMLNode) -> String? {
        if let xmlID = node[attribute: "ID"] { return "xml:\(xmlID)" }
        guard let id = node.first("id"), let root = id[attribute: "root"] else { return nil }
        return "ii:\(root)#\(id[attribute: "extension"] ?? "")"
    }

    private func validateNarrativeLink(_ match: Match, root: XMLNode, report: inout CDAValidationReport,
                                       constraintID: String) {
        let references = Set(match.node.descendants().flatMap(CDALinks.references)).sorted()
        guard !references.isEmpty else {
            add(&report, constraintID: constraintID, path: match.path, severity: .error,
                code: "narrativeLinkMissing", detail: "expected reference count 1; actual 0")
            return
        }
        guard let section = containingSection(for: match.path, root: root) else {
            add(&report, constraintID: constraintID, path: match.path, severity: .warning,
                code: "narrativeLinkNotEvaluable", detail: "section context unavailable")
            return
        }
        let ids = Set((section.first("text")?.descendants() ?? []).compactMap { $0[attribute: "ID"] })
        for reference in references where !ids.contains(reference) {
            add(&report, constraintID: constraintID, path: match.path, severity: .error,
                code: "narrativeLinkDangling", detail: "actual reference is unresolved")
        }
    }

    private func containingSection(for path: String, root: XMLNode) -> XMLNode? {
        let components = path.split(separator: "/").map(String.init).dropFirst()
        var node = root
        for component in components {
            if component.hasPrefix("@") { break }
            let pieces = component.split(separator: "[")
            let name = String(pieces[0])
            guard let indexText = pieces.dropFirst().first?.split(separator: "]").first,
                  let index = Int(indexText) else { continue }
            guard let child = node.children.enumerated().first(where: { $0.offset + 1 == index && $0.element.name.localName == name })?.element else { return nil }
            node = child
            if node.name.localName == "section" { return node }
        }
        return node.name.localName == "section" ? node : nil
    }

    private func add(_ report: inout CDAValidationReport, constraintID: String, path: String,
                     severity: CDAValidationSeverity, code: String, detail: String) {
        report.findings.append(CDAValidationFinding(constraintID: constraintID, path: path,
                                                    severity: severity, code: code, detail: detail))
    }
}
