import Foundation

public enum FHIRBindingStrength: String, Codable, Sendable { case required, extensible, preferred, example }

public struct FHIRProfileBinding: Equatable, Sendable {
    public var strength: FHIRBindingStrength
    public var valueSet: String
    public init(strength: FHIRBindingStrength, valueSet: String) {
        self.strength = strength
        self.valueSet = valueSet
    }
}

/// A FHIRPath invariant attached to an element path.
public struct FHIRInvariant: Equatable, Sendable {
    public var key: String
    public var severity: String   // error | warning
    public var expression: String
    public var human: String
    public init(key: String, severity: String = "error", expression: String, human: String = "") {
        self.key = key
        self.severity = severity
        self.expression = expression
        self.human = human
    }
}

/// One element constraint of a profile, addressed by dotted path (`Observation.value[x]`, `Patient.name.family`).
public struct FHIRProfileElement: Equatable, Sendable {
    public var path: String
    public var min: Int
    /// nil = unbounded (`*`).
    public var max: Int?
    public var types: [String]
    public var fixed: FHIRJSON?
    public var pattern: FHIRJSON?
    public var binding: FHIRProfileBinding?
    public var constraints: [FHIRInvariant]
    public var mustSupport: Bool

    public init(path: String, min: Int = 0, max: Int? = nil, types: [String] = [], fixed: FHIRJSON? = nil, pattern: FHIRJSON? = nil,
                binding: FHIRProfileBinding? = nil, constraints: [FHIRInvariant] = [], mustSupport: Bool = false) {
        self.path = path
        self.min = min
        self.max = max
        self.types = types
        self.fixed = fixed
        self.pattern = pattern
        self.binding = binding
        self.constraints = constraints
        self.mustSupport = mustSupport
    }
}

/// A profile: the toolkit's own constraint model, loadable from a `StructureDefinition` resource
/// (snapshot or differential `element` list) or built in code.
public struct FHIRProfile: Equatable, Sendable {
    public var url: String
    public var name: String
    public var resourceType: String
    public var baseDefinition: String?
    public var elements: [FHIRProfileElement]

    public init(url: String, name: String, resourceType: String, baseDefinition: String? = nil, elements: [FHIRProfileElement]) {
        self.url = url
        self.name = name
        self.resourceType = resourceType
        self.baseDefinition = baseDefinition
        self.elements = elements
    }

    public enum LoadError: Error, Equatable, Sendable { case notAStructureDefinition, missingType, noElements }

    /// Reads `StructureDefinition.snapshot.element` (falls back to `differential`) into profile elements.
    /// Slicing, discriminators and extension definitions beyond cardinality are not interpreted.
    public init(structureDefinition resource: FHIRResource) throws {
        guard resource.resourceType == "StructureDefinition" else { throw LoadError.notAStructureDefinition }
        guard let type = resource.string("type") else { throw LoadError.missingType }
        let list = resource.object("snapshot")?["element"]?.array ?? resource.object("differential")?["element"]?.array ?? []
        guard !list.isEmpty else { throw LoadError.noElements }
        var elements: [FHIRProfileElement] = []
        for item in list {
            guard let object = item.object, let path = object["path"]?.string else { continue }
            if object["sliceName"] != nil { continue }
            var element = FHIRProfileElement(path: path)
            element.min = object["min"]?.number?.intValue ?? 0
            if let max = object["max"]?.string { element.max = max == "*" ? nil : Int(max) }
            element.types = object["type"]?.array?.compactMap { $0.object?["code"]?.string } ?? []
            for key in object.keys where key.hasPrefix("fixed") && key.count > 5 { element.fixed = object[key] }
            for key in object.keys where key.hasPrefix("pattern") && key.count > 7 { element.pattern = object[key] }
            if let binding = object["binding"]?.object, let strength = binding["strength"]?.string.flatMap(FHIRBindingStrength.init(rawValue:)),
               let valueSet = binding["valueSet"]?.string {
                element.binding = FHIRProfileBinding(strength: strength, valueSet: valueSet.split(separator: "|").first.map(String.init) ?? valueSet)
            }
            element.constraints = object["constraint"]?.array?.compactMap { constraint -> FHIRInvariant? in
                guard let c = constraint.object, let key = c["key"]?.string, let expression = c["expression"]?.string else { return nil }
                return FHIRInvariant(key: key, severity: c["severity"]?.string ?? "error", expression: expression, human: c["human"]?.string ?? "")
            } ?? []
            element.mustSupport = object["mustSupport"]?.bool ?? false
            elements.append(element)
        }
        self.init(url: resource.string("url") ?? "", name: resource.string("name") ?? "", resourceType: type,
                  baseDefinition: resource.string("baseDefinition"), elements: elements)
    }
}

/// Profiles by canonical URL; `meta.profile` declarations are resolved here.
public struct FHIRProfileRegistry: Sendable {
    public private(set) var profiles: [String: FHIRProfile] = [:]
    public init(_ profiles: [FHIRProfile] = []) { for profile in profiles { self.profiles[profile.url] = profile } }
    public mutating func register(_ profile: FHIRProfile) { profiles[profile.url] = profile }
    public func profile(url: String) -> FHIRProfile? { profiles[url.split(separator: "|").first.map(String.init) ?? url] }

    /// The profile plus its base chain (most specific first), stopping at unknown bases.
    public func chain(for profile: FHIRProfile) -> [FHIRProfile] {
        var result = [profile]
        var current = profile
        var guardCount = 0
        while let base = current.baseDefinition, let parent = self.profile(url: base), guardCount < 16 {
            result.append(parent)
            current = parent
            guardCount += 1
        }
        return result
    }
}
