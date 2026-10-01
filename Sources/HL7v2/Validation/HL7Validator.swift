import Foundation

public struct HL7ValidationFinding: Equatable, Sendable {
    public enum Code: String, Sendable {
        case requiredMissing, cardinality, unexpectedSegment, segmentOrder, dataTypeInvalid, lengthExceeded
        case valueNotInSet, versionMismatch, structureUnknown, zSegmentUnexpected, conditionalUnmet
        case unknownField, deprecatedField, matchingLimitExceeded, profileInvalid
    }
    public var code: Code
    public var path: HL7Path
    public var severity: HL7Diagnostic.Severity
    public var detail: String
    /// One-based occurrence of this segment name; HL7Path.repetition refers only to field repetitions.
    public var segmentOccurrence: Int
    public init(code: Code, path: HL7Path, severity: HL7Diagnostic.Severity = .error, detail: String? = nil,
                segmentOccurrence: Int = 1) {
        self.code = code; self.path = path; self.severity = severity; self.detail = detail ?? code.rawValue
        self.segmentOccurrence = segmentOccurrence
    }
}

public struct HL7ValidationReport: Equatable, Sendable {
    public var findings: [HL7ValidationFinding]
    public var isValid: Bool { !findings.contains { $0.severity == .error } }
    public init(findings: [HL7ValidationFinding] = []) { self.findings = findings }
}

public struct HL7ValidationOptions: Sendable {
    public var maxBacktrack = 10_000
    public var includeValues = false
    public init() {}
}

public struct HL7Validator: Sendable {
    public let schema: HL7SchemaVersion
    public let profile: HL7Profile?
    public var options: HL7ValidationOptions
    public init(schema: HL7SchemaVersion, profile: HL7Profile? = nil,
                options: HL7ValidationOptions = HL7ValidationOptions()) {
        self.schema = schema; self.profile = profile; self.options = options
    }

    public func validate(_ message: HL7Message) -> HL7ValidationReport {
        var effective = schema
        var findings = schema.diagnostics
        if message.version != schema.version {
            findings.append(.init(code: .versionMismatch, path: .init(segment: "MSH", field: 12)))
        }
        if let profile {
            if profile.baseVersion != schema.version {
                findings.append(.init(code: .versionMismatch, path: .init(segment: "MSH", field: 12)))
            }
            effective.valueSets.merge(profile.valueSets) { _, local in local }
            for override in profile.overrides {
                guard let i = effective.segments[override.segment]?.fields.firstIndex(where: { $0.index == override.field }),
                      override.length.map({ $0 >= 0 }) ?? true else {
                    findings.append(.init(code: .profileInvalid, path: .init(segment: override.segment, field: override.field)))
                    continue
                }
                if let value = override.optionality { effective.segments[override.segment]?.fields[i].optionality = value }
                if let value = override.length { effective.segments[override.segment]?.fields[i].length = value }
                if let value = override.valueSetID { effective.segments[override.segment]?.fields[i].valueSetID = value }
            }
            for placement in profile.zSegments {
                guard placement.definition.name.hasPrefix("Z"), HL7Path.validName(placement.definition.name),
                      placement.min >= 0, placement.max.map({ $0 >= placement.min }) ?? true,
                      var structure = effective.structures[placement.structure],
                      insert(placement, into: &structure.children) else {
                    findings.append(.init(code: .profileInvalid, path: .init(segment: placement.definition.name)))
                    continue
                }
                effective.structures[placement.structure] = structure
                effective.segments[placement.definition.name] = placement.definition
            }
        }
        let type = message.messageType
        let key = type.code == "ACK" ? "ACK" : (type.code ?? "") + "^" + (type.triggerEvent ?? "")
        if let structureID = effective.messageTypeToStructure[key], let structure = effective.structures[structureID] {
            if let declared = type.structure, !declared.isEmpty, declared != structureID {
                findings.append(.init(code: .structureUnknown, path: .init(segment: "MSH", field: 9, component: 3)))
            }
            let allowed = segmentNames(structure.children)
            var names: [String] = []
            for segment in message.segments {
                if allowed.contains(segment.name) { names.append(segment.name) }
                else {
                    let policy = profile?.unknownSegmentPolicy ?? .error
                    if policy != .allow {
                        findings.append(.init(code: segment.name.hasPrefix("Z") ? .zSegmentUnexpected : .unexpectedSegment,
                            path: .init(segment: segment.name), severity: policy == .warn ? .warning : .error))
                    }
                }
            }
            var matcher = HL7GroupMatcher(names: names, budget: max(0, options.maxBacktrack))
            let ends = matcher.sequence(structure.children, at: 0)
            if !ends.contains(names.count) {
                if matcher.exhausted {
                    findings.append(.init(code: .matchingLimitExceeded, path: .init()))
                } else {
                    let consumed = ends.max() ?? matcher.farthest
                    let expected = matcher.expected
                    let current = consumed < names.count ? names[consumed] : nil
                    let missing = ends.isEmpty ? expected.flatMap { names.contains($0) ? nil : $0 } : nil
                    let code: HL7ValidationFinding.Code
                    let name: String
                    if let missing { code = .requiredMissing; name = missing }
                    else if let current, names.prefix(consumed).contains(current) {
                        code = .cardinality; name = current
                    } else if let current { code = .segmentOrder; name = current }
                    else { code = .requiredMissing; name = expected ?? "" }
                    findings.append(.init(code: code, path: .init(segment: name),
                        segmentOccurrence: names.prefix(consumed).filter { $0 == name }.count + 1))
                }
            }
        } else {
            findings.append(.init(code: .structureUnknown, path: .init(segment: "MSH", field: 9)))
        }
        if message["MSH"] == nil { findings.append(.init(code: .requiredMissing, path: .init(segment: "MSH"))) }
        var occurrences: [String: Int] = [:]
        for segment in message.segments {
            occurrences[segment.name, default: 0] += 1
            guard let definition = effective.segments[segment.name] else { continue }
            let occurrence = occurrences[segment.name]!
            func add(_ code: HL7ValidationFinding.Code, _ path: HL7Path, _ detail: String = "",
                     _ severity: HL7Diagnostic.Severity = .error) {
                findings.append(.init(code: code, path: path, severity: severity,
                    detail: code.rawValue + (detail.isEmpty ? "" : " " + detail), segmentOccurrence: occurrence))
            }
            for field in definition.fields {
                let path = HL7Path(segment: segment.name, field: field.index)
                let value = segment[field.index]
                let present = hl7HasValue(value)
                let condition = field.condition.map { $0.values.contains(segment[$0.field][1][1][1].text ?? "") } ?? false
                if !present {
                    if field.optionality == .R { add(.requiredMissing, path) }
                    else if field.optionality == .C && condition { add(.conditionalUnmet, path) }
                    continue
                }
                if field.optionality == .X { add(.unknownField, path); continue }
                if field.optionality == .B { add(.deprecatedField, path, "", .warning) }
                let maximum = field.repeatable ? field.maxRepetitions : 1
                if let maximum, value.repetitions.count > maximum {
                    add(.cardinality, path, "expectedMax=\(maximum) actual=\(value.repetitions.count)")
                }
                for (r, repetition) in value.repetitions.enumerated() {
                    let repPath = HL7Path(segment: segment.name, field: field.index, repetition: r + 1)
                    let length = repetition.components.map { component in
                        component.subcomponents.reduce(0) { $0 + ($1.text?.count ?? ($1 == .null ? 2 : 0)) }
                            + max(0, component.subcomponents.count - 1)
                    }.reduce(0, +) + max(0, repetition.components.count - 1)
                    if let limit = field.length, length > limit { add(.lengthExceeded, repPath, "expectedMax=\(limit) actual=\(length)") }
                    var dataType = field.dataType
                    if let selector = field.dataTypeField {
                        guard let selected = segment[selector][1][1][1].text,
                              let selectedType = HL7DataTypeName(rawValue: selected),
                              effective.dataTypes[selectedType] != nil else {
                            add(.conditionalUnmet, .init(segment: segment.name, field: selector)); continue
                        }
                        dataType = selectedType
                    }
                    for issue in typeFindings(repetition, type: dataType, definitions: effective.dataTypes, path: repPath) {
                        add(issue.code, issue.path, issue.detail == issue.code.rawValue ? "" : issue.detail)
                    }
                    if let table = field.valueSetID, let codes = effective.valueSets[table],
                       let text = repetition[1][1].text, !text.isEmpty, !codes.contains(text) {
                        add(.valueNotInSet, repPath, "set=" + table + (options.includeValues ? " value=" + text : ""))
                    }
                }
            }
            for index in segment.fields.indices where definition[index + 1] == nil && hl7HasValue(segment[index + 1]) {
                let policy = profile?.unknownFieldPolicy ?? .error
                if policy != .allow { add(.unknownField, .init(segment: segment.name, field: index + 1), "",
                                         policy == .warn ? .warning : .error) }
            }
        }
        return .init(findings: findings)
    }

    private func insert(_ placement: HL7ZSegmentPlacement, into nodes: inout [HL7StructureNode]) -> Bool {
        for i in nodes.indices {
            if nodes[i].segment == placement.afterSegment {
                nodes.insert(.init(segment: placement.definition.name, min: placement.min, max: placement.max), at: i + 1)
                return true
            }
            if insert(placement, into: &nodes[i].children) { return true }
        }
        return false
    }
}

private func segmentNames(_ nodes: [HL7StructureNode]) -> Set<String> {
    Set(nodes.flatMap { node in node.segment.map { [$0] } ?? Array(segmentNames(node.children)) })
}

/// Greedy ordered group matching with bounded backtracking. Every branch consumes budget, including empty groups.
private struct HL7GroupMatcher {
    let names: [String]
    var budget: Int
    var exhausted = false
    var farthest = 0
    var expected: String?
    mutating func sequence(_ nodes: [HL7StructureNode], at start: Int) -> [Int] {
        var positions = [start]
        for node in nodes {
            var next: [Int] = []
            for position in positions { next += repeated(node, at: position) }
            positions = Array(Set(next)).sorted(by: >)
            if positions.isEmpty { break }
        }
        return positions
    }
    mutating func repeated(_ node: HL7StructureNode, at start: Int) -> [Int] {
        guard budget > 0 else { exhausted = true; return [] }
        budget -= 1
        var levels = [[start]]
        let limit = min(node.max ?? (names.count + 1), names.count + 1)
        if limit > 0 {
            for _ in 0..<limit {
                var next: [Int] = []
                for position in levels.last! {
                    if let segment = node.segment {
                        if position < names.count, names[position] == segment { next.append(position + 1) }
                        else if levels.count - 1 < node.min, position >= farthest {
                            farthest = position; expected = segment
                        }
                    } else { next += sequence(node.children, at: position).filter { $0 > position } }
                }
                if next.isEmpty { break }
                levels.append(Array(Set(next)).sorted(by: >))
                guard budget > 0 else { exhausted = true; break }
                budget -= 1
            }
        }
        guard node.min < levels.count else { return [] }
        return Array(Set(levels.dropFirst(node.min).flatMap { $0 })).sorted(by: >)
    }
}

func typeFindings(_ value: HL7Repetition, type: HL7DataTypeName,
                  definitions: [HL7DataTypeName: HL7DataTypeDefinition], path: HL7Path) -> [HL7ValidationFinding] {
    var result: [HL7ValidationFinding] = []
    func invalid(_ path: HL7Path) { result.append(.init(code: .dataTypeInvalid, path: path)) }
    // TS uses DTM lexical rules even in versions which predate the named DTM data type.
    if type == .TS {
        if let text = value[1][1].text, !text.isEmpty, HL7Timestamp(text) == nil {
            invalid(path)
        }
    }
    guard let definition = definitions[type] else { invalid(path); return result }
    if definition.components.isEmpty {
        if value.components.count > 1 || value[1].subcomponents.count > 1 { invalid(path); return result }
        guard let text = value[1][1].text, !text.isEmpty else { return result }
        switch type {
        case .NM, .SI:
            if HL7Number(.text(text), definition: definition) == nil { invalid(path) }
        case .DT:
            if ![4, 6, 8].contains(text.count) || HL7Timestamp(text) == nil { invalid(path) }
        case .DTM:
            if HL7Timestamp(text) == nil { invalid(path) }
        case .TM:
            if text.range(of: #"^[0-9]{2}([0-9]{2}){0,2}(\.[0-9]{1,4})?([+-][0-9]{4})?$"#,
                          options: .regularExpression) == nil || HL7Timestamp("20000101" + text) == nil { invalid(path) }
        default: break
        }
        return result
    }
    if value.components.count > definition.components.count { invalid(path) }
    for (index, component) in definition.components.enumerated() {
        let content = value[index + 1]
        let componentPath = HL7Path(segment: path.segment, field: path.field, component: index + 1,
                                    repetition: path.repetition)
        if !content.subcomponents.contains(where: { !($0.text ?? "").isEmpty }) {
            if component.optionality == .R { result.append(.init(code: .requiredMissing, path: componentPath)) }
            continue
        }
        if component.dataType == .withdrawn {
            result.append(.init(code: .unknownField, path: componentPath))
            continue
        }
        if let length = component.maxLength {
            let actual = content.subcomponents.reduce(0) { $0 + ($1.text?.count ?? 0) } + content.subcomponents.count - 1
            if actual > length { result.append(.init(code: .lengthExceeded, path: componentPath,
                detail: "expectedMax=\(length) actual=\(actual)")) }
        }
        guard let nested = definitions[component.dataType] else { invalid(componentPath); continue }
        if nested.components.isEmpty {
            result += typeFindings(HL7Repetition(components: [content]), type: component.dataType,
                                   definitions: definitions, path: componentPath)
        } else {
            // HL7 permits components and subcomponents, not an unbounded recursive encoding tree.
            if content.subcomponents.count > nested.components.count { invalid(componentPath) }
            for (subindex, subdefinition) in nested.components.enumerated() {
                let subpath = HL7Path(segment: path.segment, field: path.field, component: index + 1,
                                      subcomponent: subindex + 1, repetition: path.repetition)
                let leaf = content[subindex + 1]
                if (leaf.text ?? "").isEmpty {
                    if subdefinition.optionality == .R { result.append(.init(code: .requiredMissing, path: subpath)) }
                } else if subdefinition.dataType == .withdrawn {
                    result.append(.init(code: .unknownField, path: subpath))
                } else if definitions[subdefinition.dataType]?.components.isEmpty == true {
                    result += typeFindings(hl7Scalar(leaf), type: subdefinition.dataType, definitions: definitions, path: subpath)
                }
            }
        }
    }
    return result
}
