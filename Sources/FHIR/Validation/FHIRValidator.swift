import Foundation
import HL7v3CDA

public enum FHIRIssueSeverity: String, Sendable, Comparable {
    case information, warning, error, fatal
    public static func < (lhs: FHIRIssueSeverity, rhs: FHIRIssueSeverity) -> Bool {
        let order: [FHIRIssueSeverity] = [.information, .warning, .error, .fatal]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// A validation finding: FHIRPath-style location, issue-type code and a content-free detail.
public struct FHIRValidationIssue: Equatable, Sendable {
    public let severity: FHIRIssueSeverity
    public let code: String
    public let path: String
    public let detail: String

    public init(severity: FHIRIssueSeverity, code: String, path: String, detail: String) {
        self.severity = severity
        self.code = code
        self.path = path
        self.detail = detail
    }
}

public struct FHIRValidationReport: Equatable, Sendable {
    public var issues: [FHIRValidationIssue]
    /// Profiles that were actually applied (declared and resolvable, or requested).
    public var appliedProfiles: [String]
    /// Constraint keys evaluated; a key listed here was checked, others were not.
    public var evaluatedInvariants: [String]

    public init(issues: [FHIRValidationIssue] = [], appliedProfiles: [String] = [], evaluatedInvariants: [String] = []) {
        self.issues = issues
        self.appliedProfiles = appliedProfiles
        self.evaluatedInvariants = evaluatedInvariants
    }

    public var errors: [FHIRValidationIssue] { issues.filter { $0.severity >= .error } }
    public var warnings: [FHIRValidationIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { errors.isEmpty }

    public func operationOutcome() -> FHIROperationOutcome {
        FHIROperationOutcome(issues: issues.map { FHIROperationOutcomeIssue(severity: $0.severity.rawValue, code: $0.code, diagnostics: $0.detail, expression: [$0.path]) })
    }
}

public struct FHIRValidatorOptions: Sendable {
    /// Unknown elements are errors by default (`unknown-element`); lenient mode downgrades them to warnings.
    public var allowUnknownElements: Bool
    /// Evaluate the built-in base invariants and profile constraints with the FHIRPath subset.
    public var evaluateInvariants: Bool
    /// Bindings of the base specification for the validated subset.
    public var checkBaseBindings: Bool
    public var limits: FHIRLimits

    public init(allowUnknownElements: Bool = false, evaluateInvariants: Bool = true, checkBaseBindings: Bool = true, limits: FHIRLimits = FHIRLimits()) {
        self.allowUnknownElements = allowUnknownElements
        self.evaluateInvariants = evaluateInvariants
        self.checkBaseBindings = checkBaseBindings
        self.limits = limits
    }
}

/// Structural + profile validator. Capabilities (explicit, see the QA document): element table
/// structure (unknown elements, repetition shape, required elements, primitive lexical rules and
/// JSON kinds, choice exclusivity, primitive-extension companions), contained resources, reference
/// syntax, narrative XHTML, base required bindings via the terminology provider, profile
/// cardinality/type/fixed/pattern/binding/invariants, and the built-in base invariant subset.
/// Not covered: slicing/discriminators, extension definitions, `resolve()`, `memberOf()`,
/// terminology expansion, and invariants outside the built-in list unless supplied by a profile.
public struct FHIRValidator: Sendable {
    public var schema: FHIRSchema
    public var options: FHIRValidatorOptions
    public var terminology: any FHIRTerminologyProvider
    public var profiles: FHIRProfileRegistry
    public var evaluator: FHIRPathEvaluator

    public init(schema: FHIRSchema = .r4, options: FHIRValidatorOptions = .init(),
                terminology: any FHIRTerminologyProvider = FHIRInMemoryTerminology.r4Required,
                profiles: FHIRProfileRegistry = .init()) {
        self.schema = schema
        self.options = options
        self.terminology = terminology
        self.profiles = profiles
        evaluator = FHIRPathEvaluator(schema: schema)
    }

    /// Validates the resource against structure, base bindings, base invariants, the profiles declared
    /// in `meta.profile` (when registered) and any explicitly requested profile URLs.
    public func validate(_ resource: FHIRResource, profiles requested: [String] = []) async -> FHIRValidationReport {
        var report = FHIRValidationReport()
        let context = Context(resource: resource)
        validateResource(resource.json, typeName: resource.resourceType, path: resource.resourceType, nested: false, context: context, report: &report)
        if options.checkBaseBindings { await checkBaseBindings(resource.json, typeName: resource.resourceType, path: resource.resourceType, report: &report) }
        if options.evaluateInvariants { evaluateBaseInvariants(resource, report: &report) }
        var applied: [FHIRProfile] = []
        for url in (resource.meta?.profiles ?? []) + requested {
            if let profile = profiles.profile(url: url) {
                applied.append(contentsOf: profiles.chain(for: profile).filter { candidate in !applied.contains { $0.url == candidate.url } })
            } else if requested.contains(url) {
                report.issues.append(.init(severity: .error, code: "not-supported", path: resource.resourceType + ".meta.profile", detail: "profile not registered"))
            } else {
                report.issues.append(.init(severity: .warning, code: "not-supported", path: resource.resourceType + ".meta.profile", detail: "declared profile not registered"))
            }
        }
        for profile in applied {
            report.appliedProfiles.append(profile.url)
            await validate(resource, against: profile, report: &report)
        }
        return report
    }

    final class Context {
        let resource: FHIRResource
        init(resource: FHIRResource) { self.resource = resource }
    }

    // MARK: structure

    private func validateResource(_ object: FHIRJSONObject, typeName: String, path: String, nested: Bool, context: Context, report: inout FHIRValidationReport) {
        guard let info = schema.type(typeName), info.kind == .resource else {
            report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "unknown resource type"))
            return
        }
        if nested, object["contained"]?.array?.isEmpty == false {
            report.issues.append(.init(severity: .error, code: "invariant", path: path + ".contained", detail: "dom-2: contained resources must not contain resources"))
        }
        if nested, object["id"]?.string == nil {
            report.issues.append(.init(severity: .error, code: "required", path: path + ".id", detail: "contained resources need an id"))
        }
        validateElement(object, info: info, path: path, context: context, report: &report)
    }

    private func validateElement(_ object: FHIRJSONObject, info: FHIRTypeInfo, path: String, context: Context, report: inout FHIRValidationReport) {
        if object.isEmpty || object.pairs.allSatisfy({ $0.key == "resourceType" }) {
            report.issues.append(.init(severity: .error, code: "invariant", path: path, detail: "ele-1: element must have a value or children"))
        }
        var seenChoiceGroups: [String: [String]] = [:]
        for (key, value) in object.pairs {
            if key == "resourceType" { continue }
            let isCompanion = key.hasPrefix("_")
            let elementName = isCompanion ? String(key.dropFirst()) : key
            guard let element = info.element(named: elementName) else {
                let severity: FHIRIssueSeverity = options.allowUnknownElements ? .warning : .error
                report.issues.append(.init(severity: severity, code: "unknown-element", path: path + "." + key, detail: "element not defined for " + info.name))
                continue
            }
            if let group = element.choiceGroup { seenChoiceGroups[group, default: []].append(elementName) }
            if isCompanion {
                validateCompanion(value, element: element, base: object[elementName], path: path + "." + key, report: &report)
                continue
            }
            if element.isArray {
                guard case .array(let items) = value else {
                    report.issues.append(.init(severity: .error, code: "structure", path: path + "." + key, detail: "repeating element must be an array"))
                    continue
                }
                if items.isEmpty { report.issues.append(.init(severity: .error, code: "structure", path: path + "." + key, detail: "empty arrays are not allowed")) }
                for (index, item) in items.enumerated() {
                    validateValue(item, element: element, path: path + "." + key + "[\(index)]", context: context, report: &report)
                }
            } else {
                if case .array = value {
                    report.issues.append(.init(severity: .error, code: "structure", path: path + "." + key, detail: "element does not repeat"))
                    continue
                }
                validateValue(value, element: element, path: path + "." + key, context: context, report: &report)
            }
        }
        for element in info.elements where element.isRequired && element.choiceGroup == nil && object[element.name] == nil && object["_" + element.name] == nil {
            report.issues.append(.init(severity: .error, code: "required", path: path + "." + element.name, detail: "minimum cardinality 1"))
        }
        for (group, members) in info.choiceGroups {
            let present = seenChoiceGroups[group] ?? []
            if Set(present).count > 1 {
                report.issues.append(.init(severity: .error, code: "structure", path: path + "." + group + "[x]", detail: "only one choice type may be present"))
            }
            if present.isEmpty, members.contains(where: { $0.choiceRequired }) {
                report.issues.append(.init(severity: .error, code: "required", path: path + "." + group + "[x]", detail: "a choice value is required"))
            }
        }
    }

    private func validateCompanion(_ value: FHIRJSON, element: FHIRElementInfo, base: FHIRJSON?, path: String, report: inout FHIRValidationReport) {
        guard element.isPrimitive else {
            report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "primitive extension companion on a non-primitive element"))
            return
        }
        if element.isArray {
            guard case .array(let items) = value else {
                report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "companion of a repeating primitive must be an array"))
                return
            }
            if let baseItems = base?.array, baseItems.count != items.count {
                report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "companion array length differs from the value array"))
            }
            for (index, item) in items.enumerated() where !item.isNull {
                guard let object = item.object else {
                    report.issues.append(.init(severity: .error, code: "structure", path: path + "[\(index)]", detail: "companion entries must be objects or null")); continue
                }
                if let extensionInfo = schema.type("Element") { validateElement(object, info: extensionInfo, path: path + "[\(index)]", context: Context(resource: FHIRResource(resourceType: "Element")), report: &report) }
            }
        } else {
            guard let object = value.object else {
                report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "companion must be an object")); return
            }
            if let extensionInfo = schema.type("Element") { validateElement(object, info: extensionInfo, path: path, context: Context(resource: FHIRResource(resourceType: "Element")), report: &report) }
        }
    }

    private func validateValue(_ value: FHIRJSON, element: FHIRElementInfo, path: String, context: Context, report: inout FHIRValidationReport) {
        if let primitive = element.primitiveType {
            switch (primitive.jsonKind, value) {
            case (.bool, .bool): return
            case (.number, .number(let number)):
                if !primitive.isValid(number.lexical) { report.issues.append(.init(severity: .error, code: "value", path: path, detail: "invalid \(primitive.rawValue) value")) }
            case (.string, .string(let text)):
                if primitive == .xhtml {
                    if (try? SafeXMLParser(limits: xmlLimits).parse(Data(text.utf8))).map({ $0.name.localName != "div" || $0.name.namespaceURI != FHIRXMLConverter.xhtmlNamespace }) ?? true {
                        report.issues.append(.init(severity: .error, code: "invalid", path: path, detail: "narrative must be an XHTML div"))
                    }
                } else if !primitive.isValid(text) {
                    report.issues.append(.init(severity: .error, code: "value", path: path, detail: "invalid \(primitive.rawValue) value"))
                }
            case (_, .null):
                report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "null is only allowed inside repeating primitive arrays with companions"))
            default:
                report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "JSON type does not match \(primitive.rawValue)"))
            }
            return
        }
        guard let object = value.object else {
            report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "complex element must be an object"))
            return
        }
        if element.isResource {
            guard let type = object["resourceType"]?.string else {
                report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "nested resource without resourceType")); return
            }
            validateResource(object, typeName: type, path: path, nested: element.name == "contained", context: context, report: &report)
            return
        }
        guard let info = schema.type(element.type) else {
            report.issues.append(.init(severity: .warning, code: "not-supported", path: path, detail: "type not in the element table")); return
        }
        validateElement(object, info: info, path: path, context: context, report: &report)
        if element.type == "Reference", let reference = object["reference"]?.string, FHIRReferenceTarget(reference) == nil, !reference.hasPrefix("http") {
            report.issues.append(.init(severity: .error, code: "value", path: path + ".reference", detail: "reference is not Type/id, #id, urn: or absolute"))
        }
        if element.type == "Reference", let reference = object["reference"]?.string, reference.hasPrefix("#") {
            let id = String(reference.dropFirst())
            if !context.resource.contained.contains(where: { $0.id == id }) {
                report.issues.append(.init(severity: .error, code: "invariant", path: path + ".reference", detail: "contained reference has no matching contained resource"))
            }
        }
    }

    private var xmlLimits: XMLLimits {
        var limits = XMLLimits()
        limits.maxBytes = options.limits.maxBytes
        limits.maxDepth = options.limits.maxDepth
        return limits
    }

    // MARK: bindings

    private func checkBaseBindings(_ object: FHIRJSONObject, typeName: String, path: String, report: inout FHIRValidationReport) async {
        guard let info = schema.type(typeName) else { return }
        for (key, value) in object.pairs where !key.hasPrefix("_") && key != "resourceType" {
            guard let element = info.element(named: key) else { continue }
            let items = value.array ?? [value]
            for (index, item) in items.enumerated() {
                let itemPath = element.isArray ? path + "." + key + "[\(index)]" : path + "." + key
                if element.primitiveType == .code, let code = item.string, let valueSet = FHIRBaseBindings.required[typeName + "." + key] {
                    switch await terminology.validate(system: nil, code: code, valueSet: valueSet) {
                    case .valid: break
                    case .invalid: report.issues.append(.init(severity: .error, code: "code-invalid", path: itemPath, detail: "code not in required value set"))
                    case .unknownValueSet: report.issues.append(.init(severity: .warning, code: "not-supported", path: itemPath, detail: "value set not available to the terminology provider"))
                    }
                } else if let nested = item.object, !element.isPrimitive {
                    let nestedType = nested["resourceType"]?.string ?? element.type
                    await checkBaseBindings(nested, typeName: nestedType, path: itemPath, report: &report)
                }
            }
        }
    }

    // MARK: invariants

    /// Base R4 invariants encoded as FHIRPath (subset the evaluator supports); keys follow the specification.
    public static let baseInvariants: [String: [FHIRInvariant]] = [
        "Resource": [
            FHIRInvariant(key: "dom-3", expression: "contained.all(('#' & id) in (%resource.descendants().reference | %resource.descendants().as(canonical) | %resource.descendants().as(uri) | %resource.descendants().as(url)))", human: "contained resources must be referenced"),
            FHIRInvariant(key: "dom-6", severity: "warning", expression: "text.div.exists()", human: "a resource should have narrative")
        ],
        "Period": [FHIRInvariant(key: "per-1", expression: "start.hasValue().not() or end.hasValue().not() or (start <= end)", human: "start before end")],
        "Reference": [FHIRInvariant(key: "ref-1", expression: "reference.exists() implies (reference.startsWith('#').not() or (reference.substring(1).trace('url') in %rootResource.contained.id.trace('ids')))", human: "contained references must exist")],
        "Quantity": [FHIRInvariant(key: "qty-3", expression: "code.empty() or system.exists()", human: "code needs a system")],
        "Coding": [FHIRInvariant(key: "cod-1", expression: "code.exists() or display.exists() or userSelected.exists() or system.exists() or version.exists() or extension.exists()", human: "coding needs content")],
        "Observation": [
            FHIRInvariant(key: "obs-6", expression: "dataAbsentReason.empty() or value.empty()", human: "dataAbsentReason only when value is absent"),
            FHIRInvariant(key: "obs-7", expression: "value.empty() or component.code.where(coding.intersect(%resource.code.coding).exists()).empty()", human: "component code differs from observation code")
        ],
        "Bundle": [
            FHIRInvariant(key: "bdl-1", expression: "total.empty() or (type = 'searchset') or (type = 'history')", human: "total only for searchset/history"),
            FHIRInvariant(key: "bdl-2", expression: "entry.search.empty() or (type = 'searchset')", human: "entry.search only for searchset"),
            FHIRInvariant(key: "bdl-3", expression: "entry.all(request.exists() = (%resource.type = 'batch' or %resource.type = 'transaction' or %resource.type = 'history'))", human: "request presence by type"),
            FHIRInvariant(key: "bdl-4", expression: "entry.all(response.exists() = (%resource.type = 'batch-response' or %resource.type = 'transaction-response' or %resource.type = 'history'))", human: "response presence by type"),
            FHIRInvariant(key: "bdl-7", expression: "(type = 'history') or entry.where(fullUrl.exists()).select(fullUrl & resource.meta.versionId).isDistinct()", human: "fullUrl unique"),
            FHIRInvariant(key: "bdl-9", expression: "type = 'document' implies (identifier.system.exists() and identifier.value.exists())", human: "documents need an identifier"),
            FHIRInvariant(key: "bdl-10", expression: "type = 'document' implies (timestamp.hasValue())", human: "documents need a timestamp"),
            FHIRInvariant(key: "bdl-11", expression: "type = 'document' implies entry.first().resource.is(Composition)", human: "documents start with a Composition"),
            FHIRInvariant(key: "bdl-12", expression: "type = 'message' implies entry.first().resource.is(MessageHeader)", human: "messages start with a MessageHeader")
        ],
        "Patient": [FHIRInvariant(key: "pat-1", expression: "contact.all(name.exists() or telecom.exists() or address.exists() or organization.exists())", human: "contact needs details")],
        "ImagingStudy": [FHIRInvariant(key: "isis-img-1", severity: "warning", expression: "numberOfSeries.empty() or numberOfSeries >= series.count()", human: "numberOfSeries is not smaller than the listed series")]
    ]

    private func evaluateBaseInvariants(_ resource: FHIRResource, report: inout FHIRValidationReport) {
        var pending: [(FHIRInvariant, String, FHIRPathValue)] = []
        let root = FHIRPathValue.element(.object(resource.json), type: resource.resourceType)
        for invariant in (Self.baseInvariants["Resource"] ?? []) + (Self.baseInvariants[resource.resourceType] ?? []) {
            pending.append((invariant, resource.resourceType, root))
        }
        collectTypedInvariants(resource.json, typeName: resource.resourceType, path: resource.resourceType, into: &pending)
        for (invariant, path, target) in pending {
            let expression = invariant.expression.replacingOccurrences(of: ".trace('url')", with: "").replacingOccurrences(of: ".trace('ids')", with: "")
            do {
                let result = try evaluator.evaluate(expression, context: [target], resource: root)
                report.evaluatedInvariants.append(invariant.key)
                let passed = result.isEmpty || result.allSatisfy { $0.primitive == .boolean(true) || ($0.primitive != .boolean(false)) }
                if !passed || result.contains(where: { $0.primitive == .boolean(false) }) {
                    report.issues.append(.init(severity: invariant.severity == "warning" ? .warning : .error, code: "invariant", path: path, detail: invariant.key + ": " + invariant.human))
                }
            } catch {
                report.issues.append(.init(severity: .information, code: "not-supported", path: path, detail: invariant.key + ": expression outside the supported FHIRPath subset"))
            }
        }
    }

    private func collectTypedInvariants(_ object: FHIRJSONObject, typeName: String, path: String, into pending: inout [(FHIRInvariant, String, FHIRPathValue)]) {
        guard let info = schema.type(typeName) else { return }
        for (key, value) in object.pairs where !key.hasPrefix("_") && key != "resourceType" {
            guard let element = info.element(named: key), !element.isPrimitive else { continue }
            let items = value.array ?? [value]
            for (index, item) in items.enumerated() {
                guard let nested = item.object else { continue }
                let itemPath = element.isArray ? path + "." + key + "[\(index)]" : path + "." + key
                let nestedType = nested["resourceType"]?.string ?? element.type
                for invariant in Self.baseInvariants[nestedType] ?? [] where !element.isResource {
                    pending.append((invariant, itemPath, .element(item, type: nestedType)))
                }
                if !element.isResource { collectTypedInvariants(nested, typeName: nestedType, path: itemPath, into: &pending) }
            }
        }
    }

    // MARK: profiles

    private func validate(_ resource: FHIRResource, against profile: FHIRProfile, report: inout FHIRValidationReport) async {
        guard profile.resourceType == resource.resourceType else {
            report.issues.append(.init(severity: .error, code: "structure", path: resource.resourceType, detail: "profile \(profile.name) targets \(profile.resourceType)"))
            return
        }
        let root = FHIRPathValue.element(.object(resource.json), type: resource.resourceType)
        for element in profile.elements {
            let relative = element.path.split(separator: ".").dropFirst().map(String.init)
            let segments = relative.map { $0.hasSuffix("[x]") ? String($0.dropLast(3)) : $0 }
            let expression = segments.isEmpty ? nil : segments.joined(separator: ".")
            let values: [FHIRPathValue]
            let counts: [Int]
            do {
                values = try expression.map { try evaluator.evaluate($0, context: [root], resource: root) } ?? [root]
                if segments.count > 1, let leaf = segments.last {
                    let parents = try evaluator.evaluate(segments.dropLast().joined(separator: "."), context: [root], resource: root)
                    counts = try parents.map { try evaluator.evaluate(leaf, context: [$0], resource: root).count }
                } else {
                    counts = [values.count]
                }
            } catch { continue }
            let path = element.path
            if counts.contains(where: { $0 < element.min }) {
                report.issues.append(.init(severity: .error, code: "required", path: path, detail: "profile \(profile.name): minimum \(element.min)"))
            }
            if let max = element.max, counts.contains(where: { $0 > max }) {
                report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "profile \(profile.name): maximum \(max)"))
            }
            if !element.types.isEmpty, element.path.hasSuffix("[x]") {
                for value in values where !element.types.contains(where: { evaluator.matchesType(value, $0) }) {
                    report.issues.append(.init(severity: .error, code: "structure", path: path, detail: "profile \(profile.name): type not allowed"))
                }
            }
            if let fixed = element.fixed {
                for value in values where value.json != fixed {
                    report.issues.append(.init(severity: .error, code: "value", path: path, detail: "profile \(profile.name): fixed value mismatch"))
                }
            }
            if let pattern = element.pattern {
                for value in values where !Self.matches(pattern: pattern, value: value.json) {
                    report.issues.append(.init(severity: .error, code: "value", path: path, detail: "profile \(profile.name): pattern mismatch"))
                }
            }
            if let binding = element.binding {
                for value in values {
                    let codes = Self.codes(in: value)
                    guard !codes.isEmpty else { continue }
                    var anyValid = false
                    var unknown = false
                    for (system, code) in codes {
                        switch await terminology.validate(system: system, code: code, valueSet: binding.valueSet) {
                        case .valid: anyValid = true
                        case .unknownValueSet: unknown = true
                        case .invalid: break
                        }
                    }
                    if unknown {
                        report.issues.append(.init(severity: .warning, code: "not-supported", path: path, detail: "profile \(profile.name): value set unavailable"))
                    } else if !anyValid {
                        let severity: FHIRIssueSeverity = binding.strength == .required ? .error : .warning
                        report.issues.append(.init(severity: severity, code: "code-invalid", path: path, detail: "profile \(profile.name): code not in \(binding.strength.rawValue) binding"))
                    }
                }
            }
            for invariant in element.constraints {
                for value in values.isEmpty ? [] : values {
                    do {
                        let result = try evaluator.evaluate(invariant.expression, context: [value], resource: root)
                        report.evaluatedInvariants.append(invariant.key)
                        if result.contains(where: { $0.primitive == .boolean(false) }) {
                            report.issues.append(.init(severity: invariant.severity == "warning" ? .warning : .error, code: "invariant", path: path, detail: invariant.key + ": " + invariant.human))
                        }
                    } catch {
                        report.issues.append(.init(severity: .information, code: "not-supported", path: path, detail: invariant.key + ": expression outside the supported FHIRPath subset"))
                    }
                }
            }
        }
    }

    /// Pattern semantics: every pattern key must be present with an equal (recursively pattern-matched) value.
    static func matches(pattern: FHIRJSON, value: FHIRJSON) -> Bool {
        switch (pattern, value) {
        case (.object(let expected), .object(let actual)):
            return expected.pairs.allSatisfy { pair in actual[pair.key].map { matches(pattern: pair.value, value: $0) } ?? false }
        case (.array(let expected), .array(let actual)):
            return expected.allSatisfy { item in actual.contains { matches(pattern: item, value: $0) } }
        default: return pattern == value
        }
    }

    static func codes(in value: FHIRPathValue) -> [(String?, String)] {
        switch value.primitive {
        case .string(let code): return [(nil, code)]
        case .element(let json, _, _):
            guard let object = json.object else { return [] }
            if let code = object["code"]?.string { return [(object["system"]?.string, code)] }
            return object["coding"]?.array?.compactMap { coding in coding.object?["code"]?.string.map { (coding.object?["system"]?.string, $0) } } ?? []
        default: return []
        }
    }
}
