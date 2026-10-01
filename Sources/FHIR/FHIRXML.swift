import Foundation
import HL7v3CDA

public enum FHIRXMLError: Error, Equatable, Sendable {
    case notAResource
    case unknownResourceType(String)
    case invalidNarrative
    case unrepresentable(path: String)
    case malformed(String)
}

/// FHIR XML <-> JSON tree conversion following https://hl7.org/fhir/R4/xml.html, driven by the
/// element table: primitives become `value` attributes, element ids become attributes, resource
/// ids stay elements, extensions on primitives use the JSON `_name` convention, resources nest
/// inside their wrapper element, and `Narrative.div` is carried as XHTML text. Parsing goes
/// through `SafeXMLParser` (no DTD, no external entities, bounded).
public struct FHIRXMLConverter: Sendable {
    public static let fhirNamespace = "http://hl7.org/fhir"
    public static let xhtmlNamespace = "http://www.w3.org/1999/xhtml"

    public var limits: FHIRLimits
    public var schema: FHIRSchema
    /// Keys absent from the element table are emitted/parsed generically instead of failing.
    public var allowUnknownElements: Bool

    public init(limits: FHIRLimits = FHIRLimits(), schema: FHIRSchema = .r4, allowUnknownElements: Bool = true) {
        self.limits = limits
        self.schema = schema
        self.allowUnknownElements = allowUnknownElements
    }

    private var xmlLimits: XMLLimits {
        var xml = XMLLimits()
        xml.maxBytes = limits.maxBytes
        xml.maxDepth = limits.maxDepth
        xml.maxElements = limits.maxNodes
        xml.maxTextLength = limits.maxStringBytes
        xml.maxAttributeLength = limits.maxStringBytes
        return xml
    }

    // MARK: XML -> JSON

    public func resource(fromXML data: Data) throws -> FHIRJSONObject {
        let root = try SafeXMLParser(limits: xmlLimits).parse(data)
        return try resource(from: root)
    }

    public func resource(from node: HL7v3CDA.XMLNode) throws -> FHIRJSONObject {
        guard node.name.namespaceURI == Self.fhirNamespace, let first = node.name.localName.first, first.isUppercase else {
            throw FHIRXMLError.notAResource
        }
        guard schema.isResourceType(node.name.localName) || allowUnknownElements else {
            throw FHIRXMLError.unknownResourceType(node.name.localName)
        }
        var object = FHIRJSONObject()
        object["resourceType"] = .string(node.name.localName)
        try fill(&object, from: node, typeName: node.name.localName, isResource: true, path: node.name.localName)
        return object
    }

    private func fill(_ object: inout FHIRJSONObject, from node: HL7v3CDA.XMLNode, typeName: String, isResource: Bool, path: String) throws {
        if !isResource, let id = node[attribute: "id"] { object["id"] = .string(id) }
        if typeName == "Extension", let url = node[attribute: "url"] { object["url"] = .string(url) }
        var arrays: [String: [FHIRJSON]] = [:]
        var primitiveExtensions: [String: [FHIRJSON]] = [:]
        var arrayOrder: [String] = []
        for child in node.children {
            let name = child.name.localName
            let info = schema.element(ofType: typeName, named: name)
            if info == nil, !allowUnknownElements { throw FHIRXMLError.unrepresentable(path: path + "." + name) }
            let (value, primitiveExtension) = try convert(child, info: info, path: path + "." + name)
            let repeated = info?.isArray ?? (arrays[name] != nil || object[name] != nil)
            if repeated || arrays[name] != nil {
                if arrays[name] == nil {
                    arrayOrder.append(name)
                    arrays[name] = object[name].map { [$0] } ?? []
                    primitiveExtensions[name] = primitiveExtensions[name] ?? Array(repeating: .null, count: arrays[name]!.count - (object[name] == nil ? 0 : 1))
                    if let existing = object.removeValue(forKey: "_" + name) { primitiveExtensions[name]?.append(existing) }
                    else if object[name] != nil { primitiveExtensions[name]?.append(.null) }
                    object.removeValue(forKey: name)
                }
                arrays[name]?.append(value)
                primitiveExtensions[name]?.append(primitiveExtension.map(FHIRJSON.object) ?? .null)
            } else {
                if !value.isNull { object[name] = value }
                if let primitiveExtension { object["_" + name] = .object(primitiveExtension) }
            }
        }
        for name in arrayOrder {
            object[name] = .array(arrays[name] ?? [])
            if let extensions = primitiveExtensions[name], extensions.contains(where: { !$0.isNull }) {
                object["_" + name] = .array(extensions)
            }
        }
    }

    private func convert(_ node: HL7v3CDA.XMLNode, info: FHIRElementInfo?, path: String) throws -> (FHIRJSON, FHIRJSONObject?) {
        if info?.type == "xhtml" || (info == nil && node.name.localName == "div" && node.name.namespaceURI == Self.xhtmlNamespace) {
            guard node.name.localName == "div", node.name.namespaceURI == Self.xhtmlNamespace else { throw FHIRXMLError.invalidNarrative }
            return (.string(String(decoding: try XMLSerializer(limits: xmlLimits).serialize(node), as: UTF8.self)), nil)
        }
        if node[attribute: "value"] != nil || info?.isPrimitive == true {
            var json: FHIRJSON = .null
            if let value = node[attribute: "value"] {
                switch info?.primitiveType?.jsonKind ?? .string {
                case .bool:
                    guard FHIRPrimitiveType.boolean.isValid(value) else { throw FHIRXMLError.malformed("invalid boolean at " + path) }
                    json = .bool(value == "true")
                case .number:
                    guard info?.primitiveType?.isValid(value) == true else { throw FHIRXMLError.malformed("invalid number at " + path) }
                    json = .number(FHIRNumber(lexical: value))
                case .string: json = .string(value)
                }
            }
            var extensionObject: FHIRJSONObject? = nil
            if let id = node[attribute: "id"] {
                extensionObject = FHIRJSONObject()
                extensionObject?["id"] = .string(id)
            }
            let extensions = node.children.filter { $0.name.localName == "extension" }
            if !extensions.isEmpty {
                if extensionObject == nil { extensionObject = FHIRJSONObject() }
                var converted: [FHIRJSON] = []
                for element in extensions {
                    var object = FHIRJSONObject()
                    try fill(&object, from: element, typeName: "Extension", isResource: false, path: path + ".extension")
                    converted.append(.object(object))
                }
                extensionObject?["extension"] = .array(converted)
            }
            return (json, extensionObject)
        }
        if info?.isResource == true || (info == nil && node.children.count == 1 && (node.children[0].name.localName.first?.isUppercase ?? false)) {
            guard node.children.count == 1 else { throw FHIRXMLError.malformed("resource wrapper must hold exactly one resource") }
            return (.object(try resource(from: node.children[0])), nil)
        }
        var object = FHIRJSONObject()
        let typeName = info?.type ?? node.name.localName
        try fill(&object, from: node, typeName: typeName, isResource: false, path: path)
        return (.object(object), nil)
    }

    // MARK: JSON -> XML

    public func xml(from resource: FHIRJSONObject, indentation: Int? = nil) throws -> Data {
        try XMLSerializer(indentation: indentation, limits: xmlLimits).serialize(try node(from: resource))
    }

    public func node(from resource: FHIRJSONObject) throws -> HL7v3CDA.XMLNode {
        guard let type = resource["resourceType"]?.string, let first = type.first, first.isUppercase else { throw FHIRXMLError.notAResource }
        var root = HL7v3CDA.XMLNode(type, namespaceURI: Self.fhirNamespace)
        root.namespaces[""] = Self.fhirNamespace
        try emit(resource, into: &root, typeName: type, isResource: true, path: type)
        return root
    }

    private func emit(_ object: FHIRJSONObject, into node: inout HL7v3CDA.XMLNode, typeName: String, isResource: Bool, path: String) throws {
        let info = schema.type(typeName)
        var ordered: [String] = info?.elements.map(\.name) ?? []
        let known = Set(ordered)
        ordered += object.keys.filter { !known.contains($0) && !$0.hasPrefix("_") && $0 != "resourceType" }
        for key in object.keys where key.hasPrefix("_") {
            let name = String(key.dropFirst())
            if !ordered.contains(name) { ordered.append(name) }
        }
        if !isResource, let id = object["id"]?.string {
            node.attributes[XMLName("id")] = id
        }
        if typeName == "Extension", let url = object["url"]?.string { node.attributes[XMLName("url")] = url }
        for name in ordered {
            let extensions = object["_" + name]
            guard let value = object[name] ?? extensions.map({ companion in
                companion.array.map { FHIRJSON.array(Array(repeating: .null, count: $0.count)) } ?? .null
            }) else { continue }
            if name == "resourceType" { continue }
            if name == "id", !isResource { continue }
            if name == "url", typeName == "Extension" { continue }
            let element = info?.element(named: name)
            guard element != nil || allowUnknownElements else { throw FHIRXMLError.unrepresentable(path: path + "." + name) }
            switch value {
            case .array(let items):
                for index in 0..<max(items.count, extensions?.array?.count ?? 0) {
                    let item = index < items.count ? items[index] : .null
                    let companion = extensions?[index]?.object
                    if let child = try child(named: name, value: item, primitiveExtension: companion, element: element, path: path + "." + name) {
                        node.content.append(.element(child))
                    }
                }
            default:
                if let child = try child(named: name, value: value, primitiveExtension: extensions?.object, element: element, path: path + "." + name) {
                    node.content.append(.element(child))
                }
            }
        }
    }

    private func child(named name: String, value: FHIRJSON, primitiveExtension: FHIRJSONObject?, element: FHIRElementInfo?, path: String) throws -> HL7v3CDA.XMLNode? {
        var child = HL7v3CDA.XMLNode(name, namespaceURI: Self.fhirNamespace)
        if element?.type == "xhtml" {
            guard let text = value.string else { throw FHIRXMLError.invalidNarrative }
            let div = try SafeXMLParser(limits: xmlLimits).parse(Data(text.utf8))
            guard div.name.localName == "div", div.name.namespaceURI == Self.xhtmlNamespace else { throw FHIRXMLError.invalidNarrative }
            return div
        }
        switch value {
        case .null:
            guard let primitiveExtension else { return nil }
            try applyPrimitiveExtension(primitiveExtension, to: &child, path: path)
            return child
        case .string(let text):
            child.attributes[XMLName("value")] = text
        case .number(let number):
            child.attributes[XMLName("value")] = number.lexical
        case .bool(let flag):
            child.attributes[XMLName("value")] = flag ? "true" : "false"
        case .object(let object):
            if let type = object["resourceType"]?.string, element?.isResource == true || element == nil, type.first?.isUppercase == true {
                child.content.append(.element(try node(from: object)))
                return child
            }
            try emit(object, into: &child, typeName: element?.type ?? name, isResource: false, path: path)
            return child
        case .array:
            throw FHIRXMLError.unrepresentable(path: path)
        }
        if let primitiveExtension { try applyPrimitiveExtension(primitiveExtension, to: &child, path: path) }
        return child
    }

    private func applyPrimitiveExtension(_ object: FHIRJSONObject, to child: inout HL7v3CDA.XMLNode, path: String) throws {
        if let id = object["id"]?.string { child.attributes[XMLName("id")] = id }
        for item in object["extension"]?.array ?? [] {
            guard let extensionObject = item.object else { throw FHIRXMLError.unrepresentable(path: path) }
            var element = HL7v3CDA.XMLNode("extension", namespaceURI: Self.fhirNamespace)
            try emit(extensionObject, into: &element, typeName: "Extension", isResource: false, path: path + ".extension")
            child.content.append(.element(element))
        }
    }
}
