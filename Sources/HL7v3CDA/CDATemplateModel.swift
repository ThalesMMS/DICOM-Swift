import Foundation

/// A CDA template identifier.  The root is the OID; extension and version date
/// are optional and are kept separate so a host can select the appropriate
/// published version without losing the identifier used in the XML.
public struct CDATemplateReference: Codable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var root: String
    public var `extension`: String?
    public var versionDate: String?

    public init(root: String, extension: String? = nil, versionDate: String? = nil) {
        self.root = root
        self.extension = `extension`
        self.versionDate = versionDate
    }

    public init(_ root: String, extension: String? = nil, versionDate: String? = nil) {
        self.init(root: root, extension: `extension`, versionDate: versionDate)
    }

    public init(stringLiteral value: String) { self.init(root: value) }

    public init(id: String, extension: String? = nil, versionDate: String? = nil) {
        self.init(root: id, extension: `extension`, versionDate: versionDate)
    }

    public init(oid: String, extension: String? = nil, versionDate: String? = nil) {
        self.init(root: oid, extension: `extension`, versionDate: versionDate)
    }

    public var id: String {
        get { root }
        set { root = newValue }
    }
    public var oid: String {
        get { root }
        set { root = newValue }
    }
    public var rawValue: String { description }
    public var identifier: String {
        get { root }
        set { root = newValue }
    }
    public var version: String? {
        get { versionDate }
        set { versionDate = newValue }
    }
    public var extensionValue: String? {
        get { `extension` }
        set { `extension` = newValue }
    }
    public var description: String {
        var result = root
        if let `extension`, !`extension`.isEmpty { result += "#\(`extension`)" }
        if let versionDate, !versionDate.isEmpty { result += "@\(versionDate)" }
        return result
    }

    /// Template references with the same root are compatible when the caller
    /// did not constrain an extension or version date.
    public func matches(_ other: CDATemplateReference) -> Bool {
        guard root == other.root else { return false }
        if let `extension`, `extension` != other.extension { return false }
        if let versionDate, versionDate != other.versionDate { return false }
        return true
    }

    public static func == (lhs: CDATemplateReference, rhs: String) -> Bool { lhs.root == rhs }
    public static func == (lhs: String, rhs: CDATemplateReference) -> Bool { lhs == rhs.root }
}

public typealias CDATemplateRef = CDATemplateReference
public typealias CDATemplateID = CDATemplateReference
public typealias TemplateRef = CDATemplateReference
/// Lowercase spelling retained for profile JSON and host code that uses the
/// terminology from the CDA template literature.
public typealias templateRef = CDATemplateReference

public enum CDATemplateKind: String, Codable, CaseIterable, Sendable {
    case document
    case section
    case entry
}

public extension CDATemplate {
    typealias Kind = CDATemplateKind
}

/// A supported, intentionally small XPath-like path.  It is not an XPath
/// implementation: only child steps, attribute steps, predicates, and indexes
/// are accepted.  Keeping the parsed form in the model makes evaluation
/// deterministic and permits profiles to be encoded as JSON.
public struct CDAPath: Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var rawValue: String
    public var steps: [CDAPathStep]

    public init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed
        self.steps = CDAPath.parse(trimmed)
    }

    public init(stringLiteral value: String) { self.init(value) }

    public init(path: String) { self.init(path) }

    public init(steps: [CDAPathStep]) {
        self.steps = steps
        self.rawValue = steps.map(\.description).joined(separator: "/")
    }

    public init(_ steps: [CDAPathStep]) { self.init(steps: steps) }

    public var description: String { rawValue }
    public var isEmpty: Bool { steps.isEmpty }

    public static func child(_ names: String...) -> CDAPath {
        CDAPath(names.joined(separator: "/"))
    }

    private static func parse(_ path: String) -> [CDAPathStep] {
        guard !path.isEmpty else { return [] }
        var pieces: [String] = []
        var current = ""
        var bracketDepth = 0
        var quote: Character?
        for character in path {
            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                current.append(character)
            } else if character == "[" {
                bracketDepth += 1
                current.append(character)
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                current.append(character)
            } else if character == "/" && bracketDepth == 0 {
                if !current.isEmpty { pieces.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.compactMap(CDAPathStep.init)
    }

}

public indirect enum CDAPathPredicate: Codable, Hashable, Sendable {
    case equals(path: String, value: String)
    case exists(path: String)

    public static func attributeEquals(_ attribute: String, _ value: String) -> CDAPathPredicate {
        .equals(path: attribute.hasPrefix("@") ? attribute : "@\(attribute)", value: value)
    }

    public static func codeEquals(_ value: String) -> CDAPathPredicate {
        .equals(path: "@code", value: value)
    }

    public static func templateIDEquals(_ root: String) -> CDAPathPredicate {
        .equals(path: "@root", value: root)
    }

    public static func nullFlavor(_ value: String) -> CDAPathPredicate {
        .equals(path: "@nullFlavor", value: value)
    }
}

public extension CDAPath {
    typealias Step = CDAPathStep
    typealias Predicate = CDAPathPredicate
}

public struct CDAPathStep: Codable, Hashable, Sendable, CustomStringConvertible {
    public var name: String
    public var index: Int?
    public var predicates: [CDAPathPredicate]

    public init(name: String, index: Int? = nil, predicate: CDAPathPredicate? = nil,
                predicates: [CDAPathPredicate] = []) {
        self.name = name
        self.index = index
        self.predicates = predicate.map { [$0] } ?? predicates
    }

    public init(_ element: String, index: Int? = nil, predicate: CDAPathPredicate? = nil,
                predicates: [CDAPathPredicate] = []) {
        self.init(name: element, index: index, predicate: predicate, predicates: predicates)
    }

    public var element: String { name }
    public var predicate: CDAPathPredicate? { predicates.first }
    public var description: String {
        var result = name
        if let index { result += "[\(index)]" }
        for predicate in predicates {
            switch predicate {
            case .equals(let path, let value):
                result += "[\(path)='\(value)']"
            case .exists(let path): result += "[\(path)]"
            }
        }
        return result
    }

    fileprivate init?(_ source: String) {
        var token = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        var index: Int?
        var predicates: [CDAPathPredicate] = []
        while let open = token.lastIndex(of: "[") {
            guard token.last == "]", let close = token.lastIndex(of: "]"), open < close else { break }
            let expression = String(token[token.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
            token = String(token[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsedIndex = Int(expression), parsedIndex > 0, index == nil {
                index = parsedIndex
                continue
            }
            if let equals = expression.firstIndex(of: "=") {
                let left = String(expression[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                var right = String(expression[expression.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if right.count >= 2, (right.first == "'" && right.last == "'") || (right.first == "\"" && right.last == "\"") {
                    right.removeFirst(); right.removeLast()
                }
                guard !left.isEmpty else { return nil }
                predicates.insert(.equals(path: left, value: right), at: 0)
            } else if !expression.isEmpty {
                predicates.insert(.exists(path: expression), at: 0)
            }
        }
        guard !token.isEmpty, !token.contains("[") else { return nil }
        self.name = token
        self.index = index
        self.predicates = predicates
    }
}

public struct CDACardinality: Codable, Hashable, Sendable, CustomStringConvertible {
    public var minimum: Int
    public var maximum: Int?

    public init(minimum: Int = 0, maximum: Int? = nil) {
        self.minimum = Swift.max(0, minimum)
        self.maximum = maximum.map { Swift.max(0, $0) }
    }

    public init(min: Int, max: Int? = nil) { self.init(minimum: min, maximum: max) }
    public init(_ range: ClosedRange<Int>) { self.init(minimum: range.lowerBound, maximum: range.upperBound) }
    public init(_ range: Range<Int>) { self.init(minimum: range.lowerBound, maximum: range.upperBound == 0 ? 0 : range.upperBound - 1) }

    public var min: Int { minimum }
    public var max: Int? { maximum }
    public var description: String { "[\(minimum)..\(maximum.map(String.init) ?? "*")]" }
}

public enum CDAValueSetBindingKind: String, Codable, CaseIterable, Sendable {
    case required
    case extensible
    case preferred
}

public struct CDAValueSet: Codable, Hashable, Sendable {
    public var binding: CDAValueSetBindingKind
    public var codes: [String]
    public var codeSystem: String?

    public init(binding: CDAValueSetBindingKind, codes: [String] = [], codeSystem: String? = nil) {
        self.binding = binding
        self.codes = Array(Set(codes)).sorted()
        self.codeSystem = codeSystem
    }

    public init(binding: CDAValueSetBindingKind, codes: Set<String>, codeSystem: String? = nil) {
        self.init(binding: binding, codes: Array(codes), codeSystem: codeSystem)
    }
}

public typealias CDAValueSetBinding = CDAValueSet
public typealias CDAValueSetBindingType = CDAValueSetBindingKind

public enum CDANullFlavorPolicy: String, Codable, CaseIterable, Sendable {
    case allowed
    case forbidden
    case required
}

public extension CDAConstraint {
    typealias NullFlavorPolicy = CDANullFlavorPolicy
    typealias ValueSetBinding = CDAValueSetBindingKind
    typealias Cardinality = CDACardinality
}

public struct CDAConditionalConstraint: Codable, Hashable, Sendable {
    public var when: CDAPath
    public var thenConstraints: [CDAConstraint]
    public var elseConstraints: [CDAConstraint]

    public init(when: CDAPath, then: [CDAConstraint] = [], else: [CDAConstraint] = []) {
        self.when = when
        self.thenConstraints = then
        self.elseConstraints = `else`
    }

    public init(when predicate: CDAPathPredicate, then: [CDAConstraint] = [], else: [CDAConstraint] = []) {
        self.init(when: CDAPath(steps: [CDAPathStep(name: ".", predicates: [predicate])]),
                  then: then, else: `else`)
    }

    public var then: [CDAConstraint] {
        get { thenConstraints }
        set { thenConstraints = newValue }
    }
    public var `else`: [CDAConstraint] {
        get { elseConstraints }
        set { elseConstraints = newValue }
    }
}

public typealias CDACustomConstraintRule = @Sendable (XMLNode) -> Bool

/// A structural rule attached to a template.  Custom closures intentionally
/// are not serialized; their identifier is serialized so a host can reinstall
/// the rule after loading a profile JSON document.
public struct CDAConstraint: Codable, Hashable, @unchecked Sendable {
    public var id: String
    public var path: CDAPath
    public var cardinality: CDACardinality?
    public var valueSet: CDAValueSet?
    public var fixedValue: String?
    public var dataType: String?
    public var nullFlavorPolicy: CDANullFlavorPolicy?
    public var conditional: CDAConditionalConstraint?
    public var narrativeLinked: Bool
    public var uniqueID: Bool
    public var customIdentifier: String?
    private var customRule: CDACustomConstraintRule?

    public init(id: String, path: CDAPath, cardinality: CDACardinality? = nil,
                valueSet: CDAValueSet? = nil, fixedValue: String? = nil,
                dataType: String? = nil, nullFlavorPolicy: CDANullFlavorPolicy? = nil,
                conditional: CDAConditionalConstraint? = nil, narrativeLinked: Bool = false,
                uniqueID: Bool = false, customIdentifier: String? = nil,
                customRule: CDACustomConstraintRule? = nil) {
        self.id = id
        self.path = path
        self.cardinality = cardinality
        self.valueSet = valueSet
        self.fixedValue = fixedValue
        self.dataType = dataType
        self.nullFlavorPolicy = nullFlavorPolicy
        self.conditional = conditional
        self.narrativeLinked = narrativeLinked
        self.uniqueID = uniqueID
        self.customIdentifier = customIdentifier
        self.customRule = customRule
    }

    public init(id: String, path: CDAPath, cardinality: ClosedRange<Int>,
                valueSet: CDAValueSet? = nil, fixedValue: String? = nil, dataType: String? = nil,
                nullFlavorPolicy: CDANullFlavorPolicy? = nil, narrativeLinked: Bool = false,
                uniqueID: Bool = false) {
        self.init(id: id, path: path, cardinality: CDACardinality(cardinality), valueSet: valueSet,
                  fixedValue: fixedValue, dataType: dataType, nullFlavorPolicy: nullFlavorPolicy,
                  narrativeLinked: narrativeLinked, uniqueID: uniqueID)
    }

    public var constraintID: String {
        get { id }
        set { id = newValue }
    }
    public var custom: CDACustomConstraintRule? { customRule }

    public static func cardinality(id: String, path: CDAPath, min: Int, max: Int? = nil) -> CDAConstraint {
        .init(id: id, path: path, cardinality: CDACardinality(minimum: min, maximum: max))
    }
    public static func cardinality(id: String, path: CDAPath, cardinality: CDACardinality) -> CDAConstraint {
        .init(id: id, path: path, cardinality: cardinality)
    }
    public static func cardinality(id: String, path: CDAPath, _ range: ClosedRange<Int>) -> CDAConstraint {
        .init(id: id, path: path, cardinality: CDACardinality(range))
    }
    public static func valueSet(id: String, path: CDAPath, binding: CDAValueSetBindingKind,
                                codes: [String] = [], codeSystem: String? = nil) -> CDAConstraint {
        .init(id: id, path: path, valueSet: CDAValueSet(binding: binding, codes: codes, codeSystem: codeSystem))
    }
    public static func fixedValue(id: String, path: CDAPath, value: String) -> CDAConstraint {
        .init(id: id, path: path, fixedValue: value)
    }
    public static func dataType(id: String, path: CDAPath, xsiType: String) -> CDAConstraint {
        .init(id: id, path: path, dataType: xsiType)
    }
    public static func nullFlavorPolicy(id: String, path: CDAPath, policy: CDANullFlavorPolicy) -> CDAConstraint {
        .init(id: id, path: path, nullFlavorPolicy: policy)
    }
    public static func conditional(id: String, path: CDAPath = CDAPath("."), when: CDAPath,
                                  then: [CDAConstraint], else: [CDAConstraint] = []) -> CDAConstraint {
        .init(id: id, path: path, conditional: .init(when: when, then: then, else: `else`))
    }
    public static func conditional(id: String, path: CDAPath = CDAPath("."), when: CDAPathPredicate,
                                  then: [CDAConstraint], else: [CDAConstraint] = []) -> CDAConstraint {
        .init(id: id, path: path, conditional: .init(when: when, then: then, else: `else`))
    }
    public static func narrativeLinked(id: String, path: CDAPath) -> CDAConstraint {
        .init(id: id, path: path, narrativeLinked: true)
    }
    public static func uniqueID(id: String, path: CDAPath) -> CDAConstraint {
        .init(id: id, path: path, uniqueID: true)
    }
    public static func custom(id: String, path: CDAPath = CDAPath("."),
                              _ closure: @escaping CDACustomConstraintRule) -> CDAConstraint {
        .init(id: id, path: path, customIdentifier: id, customRule: closure)
    }
    public static func custom(id: String, path: CDAPath = CDAPath("."),
                              closure: @escaping CDACustomConstraintRule) -> CDAConstraint {
        .init(id: id, path: path, customIdentifier: id, customRule: closure)
    }

    public static func == (lhs: CDAConstraint, rhs: CDAConstraint) -> Bool {
        lhs.id == rhs.id && lhs.path == rhs.path && lhs.cardinality == rhs.cardinality &&
            lhs.valueSet == rhs.valueSet && lhs.fixedValue == rhs.fixedValue && lhs.dataType == rhs.dataType &&
            lhs.nullFlavorPolicy == rhs.nullFlavorPolicy && lhs.conditional == rhs.conditional &&
            lhs.narrativeLinked == rhs.narrativeLinked && lhs.uniqueID == rhs.uniqueID &&
            lhs.customIdentifier == rhs.customIdentifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(path); hasher.combine(cardinality); hasher.combine(valueSet)
        hasher.combine(fixedValue); hasher.combine(dataType); hasher.combine(nullFlavorPolicy)
        hasher.combine(conditional); hasher.combine(narrativeLinked); hasher.combine(uniqueID)
        hasher.combine(customIdentifier)
    }

    enum CodingKeys: String, CodingKey {
        case id, path, cardinality, valueSet, fixedValue, dataType, nullFlavorPolicy, conditional
        case narrativeLinked, uniqueID, customIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decode(CDAPath.self, forKey: .path)
        cardinality = try container.decodeIfPresent(CDACardinality.self, forKey: .cardinality)
        valueSet = try container.decodeIfPresent(CDAValueSet.self, forKey: .valueSet)
        fixedValue = try container.decodeIfPresent(String.self, forKey: .fixedValue)
        dataType = try container.decodeIfPresent(String.self, forKey: .dataType)
        nullFlavorPolicy = try container.decodeIfPresent(CDANullFlavorPolicy.self, forKey: .nullFlavorPolicy)
        conditional = try container.decodeIfPresent(CDAConditionalConstraint.self, forKey: .conditional)
        narrativeLinked = try container.decodeIfPresent(Bool.self, forKey: .narrativeLinked) ?? false
        uniqueID = try container.decodeIfPresent(Bool.self, forKey: .uniqueID) ?? false
        customIdentifier = try container.decodeIfPresent(String.self, forKey: .customIdentifier)
        customRule = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(cardinality, forKey: .cardinality)
        try container.encodeIfPresent(valueSet, forKey: .valueSet)
        try container.encodeIfPresent(fixedValue, forKey: .fixedValue)
        try container.encodeIfPresent(dataType, forKey: .dataType)
        try container.encodeIfPresent(nullFlavorPolicy, forKey: .nullFlavorPolicy)
        try container.encodeIfPresent(conditional, forKey: .conditional)
        try container.encode(narrativeLinked, forKey: .narrativeLinked)
        try container.encode(uniqueID, forKey: .uniqueID)
        try container.encodeIfPresent(customIdentifier, forKey: .customIdentifier)
    }
}

public struct CDATemplate: Codable, Hashable, Sendable {
    public var id: CDATemplateReference
    public var name: String
    public var kind: CDATemplateKind
    public var inherits: [CDATemplateReference]
    public var constraints: [CDAConstraint]

    public init(id: CDATemplateReference, name: String, kind: CDATemplateKind,
                inherits: [CDATemplateReference] = [], constraints: [CDAConstraint] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.inherits = inherits
        self.constraints = constraints
    }

    public init(root: String, extension: String? = nil, versionDate: String? = nil,
                name: String, kind: CDATemplateKind, inherits: [CDATemplateReference] = [],
                constraints: [CDAConstraint] = []) {
        self.init(id: CDATemplateReference(root: root, extension: `extension`, versionDate: versionDate),
                  name: name, kind: kind, inherits: inherits, constraints: constraints)
    }

    public init(id root: String, name: String, kind: CDATemplateKind,
                extension: String? = nil, versionDate: String? = nil,
                inherits: [CDATemplateReference] = [], constraints: [CDAConstraint] = []) {
        self.init(root: root, extension: `extension`, versionDate: versionDate, name: name, kind: kind,
                  inherits: inherits, constraints: constraints)
    }

    public var templateRef: CDATemplateReference {
        get { id }
        set { id = newValue }
    }
    public var root: String {
        get { id.root }
        set { id.root = newValue }
    }
    public var oid: String {
        get { id.root }
        set { id.root = newValue }
    }
    public var identifier: String {
        get { id.root }
        set { id.root = newValue }
    }
    public var idString: String {
        get { id.root }
        set { id.root = newValue }
    }
    public var versionDate: String? {
        get { id.versionDate }
        set { id.versionDate = newValue }
    }
}

public enum CDATemplateRegistryError: Error, Equatable, Sendable {
    case duplicateTemplate(String)
    case unknownTemplate(String)
    case inheritanceCycle([String])
}

/// Mutable profile registry used by validators and builders.  Registration is
/// explicit so a host can load Codable profiles without changing the built-in
/// library.
public struct CDATemplateRegistry: Codable, Sendable {
    private var storage: [CDATemplateReference: CDATemplate]

    public init(templates: [CDATemplate] = []) {
        storage = [:]
        for template in templates { storage[template.id] = template }
    }

    public init(_ templates: [CDATemplate]) { self.init(templates: templates) }

    public init(validating templates: [CDATemplate]) throws {
        var identifiers = Set<CDATemplateReference>()
        for template in templates where !identifiers.insert(template.id).inserted {
            throw CDATemplateRegistryError.duplicateTemplate(template.id.description)
        }
        self.init(templates: templates)
        try validateInheritance()
    }

    public init(from decoder: Decoder) throws {
        self.init(templates: try decoder.singleValueContainer().decode([CDATemplate].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(templates)
    }

    public var templates: [CDATemplate] {
        storage.values.sorted {
            let left = [$0.id.root, $0.id.extension ?? "", $0.id.versionDate ?? ""]
            let right = [$1.id.root, $1.id.extension ?? "", $1.id.versionDate ?? ""]
            return left.lexicographicallyPrecedes(right)
        }
    }
    public var allTemplates: [CDATemplate] { templates }
    public var count: Int { storage.count }

    public subscript(_ reference: CDATemplateReference) -> CDATemplate? {
        template(for: reference)
    }

    public mutating func register(_ template: CDATemplate, replacingExisting: Bool = false) throws {
        if storage[template.id] != nil && !replacingExisting {
            throw CDATemplateRegistryError.duplicateTemplate(template.id.description)
        }
        storage[template.id] = template
    }

    public mutating func add(_ template: CDATemplate, replacingExisting: Bool = false) throws {
        try register(template, replacingExisting: replacingExisting)
    }

    public func registering(_ template: CDATemplate, replacingExisting: Bool = false) throws -> CDATemplateRegistry {
        var result = self
        try result.register(template, replacingExisting: replacingExisting)
        return result
    }

    public func template(for reference: CDATemplateReference) -> CDATemplate? {
        if let exact = storage[reference] { return exact }
        return templates.first { $0.id.matches(reference) || reference.matches($0.id) }
    }

    public func template(root: String, extension: String? = nil, versionDate: String? = nil) -> CDATemplate? {
        template(for: .init(root: root, extension: `extension`, versionDate: versionDate))
    }

    public func contains(_ reference: CDATemplateReference) -> Bool { template(for: reference) != nil }

    public func composedTemplate(for reference: CDATemplateReference) throws -> CDATemplate {
        var visiting: [CDATemplateReference] = []
        return try compose(reference, visiting: &visiting)
    }

    public func composedConstraints(for reference: CDATemplateReference) throws -> [CDAConstraint] {
        try composedTemplate(for: reference).constraints
    }

    public func validateInheritance() throws {
        for template in templates { _ = try composedTemplate(for: template.id) }
    }

    public func resolve(_ reference: CDATemplateReference) throws -> CDATemplate {
        try composedTemplate(for: reference)
    }

    private func compose(_ reference: CDATemplateReference, visiting: inout [CDATemplateReference]) throws -> CDATemplate {
        guard let template = template(for: reference) else {
            throw CDATemplateRegistryError.unknownTemplate(reference.description)
        }
        guard !visiting.contains(where: { $0.matches(template.id) || template.id.matches($0) }) else {
            let cycle = (visiting + [template.id]).map(\.description)
            throw CDATemplateRegistryError.inheritanceCycle(cycle)
        }
        visiting.append(template.id)
        defer { _ = visiting.popLast() }
        var merged: [CDAConstraint] = []
        for parent in template.inherits {
            let parentTemplate = try compose(parent, visiting: &visiting)
            for constraint in parentTemplate.constraints {
                if let index = merged.firstIndex(where: { $0.id == constraint.id }) { merged[index] = constraint }
                else { merged.append(constraint) }
            }
        }
        for constraint in template.constraints {
            if let index = merged.firstIndex(where: { $0.id == constraint.id }) { merged[index] = constraint }
            else { merged.append(constraint) }
        }
        return CDATemplate(id: template.id, name: template.name, kind: template.kind,
                           inherits: template.inherits, constraints: merged)
    }

    public static var builtIn: CDATemplateRegistry { CDATemplateLibrary.registry }
    public static var `default`: CDATemplateRegistry { builtIn }
}
