import Foundation

/// One element of a FHIR type: name, declared type, repetition and requirement.
public struct FHIRElementInfo: Equatable, Sendable {
    public let name: String
    public let type: String
    public let isArray: Bool
    public let isRequired: Bool
    /// Choice group (`value` for `valueQuantity`), when the element is one of a `[x]` choice.
    public let choiceGroup: String?
    public let choiceRequired: Bool

    public var primitiveType: FHIRPrimitiveType? { FHIRPrimitiveType(rawValue: type) }
    public var isPrimitive: Bool { primitiveType != nil }
    public var isResource: Bool { type == "Resource" }
}

public enum FHIRTypeKind: String, Sendable { case resource, complex, backbone, primitive }

public struct FHIRTypeInfo: Equatable, Sendable {
    public let name: String
    public let kind: FHIRTypeKind
    public let elements: [FHIRElementInfo]

    public func element(named name: String) -> FHIRElementInfo? { elements.first { $0.name == name } }
    /// Elements grouped by choice: `value` -> [valueQuantity, valueString, ...].
    public var choiceGroups: [String: [FHIRElementInfo]] {
        Dictionary(grouping: elements.filter { $0.choiceGroup != nil }, by: { $0.choiceGroup! })
    }
}

/// Structural element table generated from the FHIR R4B models of the oracle environment
/// (`Scripts/interop/fhir_generate_elements.py`). It drives XML<->JSON typing, choice
/// resolution and structural validation; it carries no narrative or example content.
public final class FHIRSchema: Sendable {
    public let source: String
    public let types: [String: FHIRTypeInfo]

    public static let r4: FHIRSchema = {
        guard let url = Bundle.module.url(forResource: "FHIRElements", withExtension: "json"),
              let data = try? Data(contentsOf: url), let schema = try? FHIRSchema(data: data) else {
            preconditionFailure("Bundled FHIRElements.json is missing, unreadable, or invalid")
        }
        return schema
    }()

    public init(source: String, types: [String: FHIRTypeInfo]) {
        self.source = source
        self.types = types
    }

    public convenience init(data: Data) throws {
        let root = try FHIRJSONParser().parseObject(data)
        var types: [String: FHIRTypeInfo] = [:]
        for (name, value) in root["types"]?.object?.pairs ?? [] {
            guard let object = value.object, let kind = FHIRTypeKind(rawValue: object["kind"]?.string ?? "") else { continue }
            let elements = (object["elements"]?.array ?? []).compactMap { item -> FHIRElementInfo? in
                guard let element = item.object, let elementName = element["name"]?.string, let type = element["type"]?.string else { return nil }
                return FHIRElementInfo(name: elementName, type: type, isArray: element["array"]?.bool ?? false,
                                       isRequired: element["required"]?.bool ?? false,
                                       choiceGroup: element["choice"]?.string, choiceRequired: element["choiceRequired"]?.bool ?? false)
            }
            types[name] = FHIRTypeInfo(name: name, kind: kind, elements: elements)
        }
        self.init(source: root["source"]?.string ?? "unknown", types: types)
    }

    public func type(_ name: String) -> FHIRTypeInfo? { types[name] }
    public var resourceTypes: [String] { types.values.filter { $0.kind == .resource }.map(\.name).sorted() }
    public func isResourceType(_ name: String) -> Bool { types[name]?.kind == .resource }

    /// Element lookup that follows the `_name` primitive-extension convention and choice suffixes.
    public func element(ofType typeName: String, named name: String) -> FHIRElementInfo? {
        guard let info = types[typeName] else { return nil }
        if let direct = info.element(named: name) { return direct }
        if name.hasPrefix("_") { return info.element(named: String(name.dropFirst())) }
        return nil
    }
}
