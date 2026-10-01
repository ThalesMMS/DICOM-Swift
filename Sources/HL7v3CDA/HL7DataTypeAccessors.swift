import Foundation

extension II {
    public init(root: String, extension identifier: String? = nil, assigningAuthorityName: String? = nil) throws {
        var node = XMLNode("II", attributes: ["root": root])
        node[attribute: "extension"] = identifier
        node[attribute: "assigningAuthorityName"] = assigningAuthorityName
        try self.init(node: node)
    }
    public var root: String? { node[attribute: "root"] }
    public var `extension`: String? { node[attribute: "extension"] }
    public var assigningAuthorityName: String? { node[attribute: "assigningAuthorityName"] }
}

public protocol CodedDataType: HL7DataType {}
extension CD: CodedDataType {}
extension CE: CodedDataType {}
extension CS: CodedDataType {}
extension CV: CodedDataType {}
extension CodedDataType {
    public init(code: String, codeSystem: String? = nil, codeSystemName: String? = nil,
                codeSystemVersion: String? = nil, displayName: String? = nil,
                originalText: ED? = nil, translations: [CD] = [], qualifiers: [XMLNode] = []) throws {
        var node = XMLNode(Self.typeName, attributes: ["code": code])
        node[attribute: "codeSystem"] = codeSystem
        node[attribute: "codeSystemName"] = codeSystemName
        node[attribute: "codeSystemVersion"] = codeSystemVersion
        node[attribute: "displayName"] = displayName
        node.children = (originalText.map { [$0.xml(named: "originalText")] } ?? []) + qualifiers + translations.map { $0.xml(named: "translation") }
        try self.init(node: node)
    }
    public var code: String? { node[attribute: "code"] }
    public var codeSystem: String? { node[attribute: "codeSystem"] }
    public var codeSystemName: String? { node[attribute: "codeSystemName"] }
    public var codeSystemVersion: String? { node[attribute: "codeSystemVersion"] }
    public var displayName: String? { node[attribute: "displayName"] }
    public var originalText: ED? { node.first("originalText").flatMap { try? ED(node: $0) } }
    public var translations: [CD] { node.elements("translation").compactMap { try? CD(node: $0) } }
    public var qualifiers: [XMLNode] { node.elements("qualifier") }
}

extension ST {
    public init(_ text: String) { self.node = XMLNode("ST", text: text) }
    public var text: String? { nullFlavor == nil ? node.textContent : nil }
}

extension ED {
    public enum Representation: String, Sendable { case B64, TXT }
    public init(text: String = "", mediaType: String? = nil, representation: Representation = .TXT,
                reference: String? = nil, compression: String? = nil) throws {
        var node = XMLNode("ED", attributes: ["representation": representation.rawValue], text: text.isEmpty ? nil : text)
        node[attribute: "mediaType"] = mediaType
        node[attribute: "compression"] = compression
        if let reference { node.content.append(.element(XMLNode("reference", attributes: ["value": reference]))) }
        try self.init(node: node)
    }
    public var mediaType: String? { node[attribute: "mediaType"] }
    public var representation: Representation? { node[attribute: "representation"].flatMap(Representation.init(rawValue:)) }
    public var reference: String? { node.first("reference")?[attribute: "value"] }
    public var compression: String? { node[attribute: "compression"] }
    public var text: String? { nullFlavor == nil ? node.textContent : nil }
}

public protocol ScalarDataType: HL7DataType {}
extension TS: ScalarDataType {}
extension INT: ScalarDataType {}
extension REAL: ScalarDataType {}
extension BL: ScalarDataType {}
extension ScalarDataType {
    public init(_ value: String) throws { try self.init(node: XMLNode(Self.typeName, attributes: ["value": value])) }
    public var value: String? { node[attribute: "value"] }
}
extension BL {
    public init(_ value: Bool) { self.node = XMLNode("BL", attributes: ["value": value ? "true" : "false"]) }
    public var boolValue: Bool? { value.map { $0 == "true" || $0 == "1" } }
}
extension TS {
    public enum Precision: Int, Sendable { case year = 4, month = 6, day = 8, hour = 10, minute = 12, second = 14, fraction = 15 }
    public var precision: Precision? {
        guard let value else { return nil }
        if value.contains(".") { return .fraction }
        return Precision(rawValue: value.prefix(while: { $0.isNumber }).count)
    }
    public var timeZoneOffsetMinutes: Int? {
        guard let value, let index = value.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        let zone = value[value.index(after: index)...]
        return ((Int(zone.prefix(2)) ?? 0) * 60 + (Int(zone.suffix(2)) ?? 0)) * (value[index] == "-" ? -1 : 1)
    }
}
extension PQ {
    public init(value: String, unit: String) throws { try self.init(node: XMLNode("PQ", attributes: ["value": value, "unit": unit])) }
    public var value: String? { node[attribute: "value"] }
    public var unit: String? { node[attribute: "unit"] }
}
extension TEL {
    public init(value: String, use: [String] = []) throws {
        var node = XMLNode("TEL", attributes: ["value": value])
        if !use.isEmpty { node[attribute: "use"] = use.joined(separator: " ") }
        try self.init(node: node)
    }
    public var value: String? { node[attribute: "value"] }
    public var use: [String] { (node[attribute: "use"] ?? "").split(separator: " ").map(String.init) }
}

extension IVL_TS {
    public init(low: TS? = nil, high: TS? = nil, width: PQ? = nil, center: TS? = nil) throws {
        try self.init(node: XMLNode("IVL_TS", children: [low?.xml(named: "low"), center?.xml(named: "center"),
            width?.xml(named: "width"), high?.xml(named: "high")].compactMap { $0 }))
    }
    public var low: TS? { node.first("low").flatMap { try? TS(node: $0) } }
    public var high: TS? { node.first("high").flatMap { try? TS(node: $0) } }
    public var center: TS? { node.first("center").flatMap { try? TS(node: $0) } }
    public var width: PQ? { node.first("width").flatMap { try? PQ(node: $0) } }
}
extension IVL_PQ {
    public init(low: PQ? = nil, high: PQ? = nil, width: PQ? = nil, center: PQ? = nil) throws {
        try self.init(node: XMLNode("IVL_PQ", children: [low?.xml(named: "low"), center?.xml(named: "center"),
            width?.xml(named: "width"), high?.xml(named: "high")].compactMap { $0 }))
    }
    public var low: PQ? { node.first("low").flatMap { try? PQ(node: $0) } }
    public var high: PQ? { node.first("high").flatMap { try? PQ(node: $0) } }
    public var center: PQ? { node.first("center").flatMap { try? PQ(node: $0) } }
    public var width: PQ? { node.first("width").flatMap { try? PQ(node: $0) } }
}
extension PIVL_TS {
    public init(phase: IVL_TS? = nil, period: PQ? = nil, institutionSpecified: Bool? = nil) throws {
        var node = XMLNode("PIVL_TS", children: [phase?.xml(named: "phase"), period?.xml(named: "period")].compactMap { $0 })
        node[attribute: "institutionSpecified"] = institutionSpecified.map { $0 ? "true" : "false" }
        try self.init(node: node)
    }
    public var phase: IVL_TS? { node.first("phase").flatMap { try? IVL_TS(node: $0) } }
    public var period: PQ? { node.first("period").flatMap { try? PQ(node: $0) } }
}

extension ADXP {
    public init(part: String, text: String, qualifiers: [String] = []) throws {
        var node = XMLNode(part, text: text)
        if !qualifiers.isEmpty { node[attribute: "qualifier"] = qualifiers.joined(separator: " ") }
        try self.init(node: node)
    }
    public var part: String { node.name.localName }
    public var text: String? { nullFlavor == nil ? node.textContent : nil }
    public var qualifiers: [String] { (node[attribute: "qualifier"] ?? "").split(separator: " ").map(String.init) }
}
extension AD {
    public init(parts: [ADXP], use: [String] = []) throws {
        var node = XMLNode("AD", children: parts.map(\.node))
        if !use.isEmpty { node[attribute: "use"] = use.joined(separator: " ") }
        try self.init(node: node)
    }
    public var parts: [ADXP] { node.children.compactMap { try? ADXP(node: $0) } }
    public var use: [String] { (node[attribute: "use"] ?? "").split(separator: " ").map(String.init) }
}

public struct ENPart: Equatable, Sendable {
    public var node: XMLNode
    public init(part: String, text: String, qualifiers: [String] = []) {
        node = XMLNode(part, text: text)
        if !qualifiers.isEmpty { node[attribute: "qualifier"] = qualifiers.joined(separator: " ") }
    }
    public init(node: XMLNode) { self.node = node }
    public var part: String { node.name.localName }
    public var text: String { node.textContent }
    public var qualifiers: [String] { (node[attribute: "qualifier"] ?? "").split(separator: " ").map(String.init) }
}
public protocol NameDataType: HL7DataType {}
extension EN: NameDataType {}
extension PN: NameDataType {}
extension ON: NameDataType {}
extension NameDataType {
    public init(parts: [ENPart], use: [String] = []) throws {
        var node = XMLNode(Self.typeName, children: parts.map(\.node))
        if !use.isEmpty { node[attribute: "use"] = use.joined(separator: " ") }
        try self.init(node: node)
    }
    public var parts: [ENPart] { node.children.map(ENPart.init(node:)) }
    public var use: [String] { (node[attribute: "use"] ?? "").split(separator: " ").map(String.init) }
}
