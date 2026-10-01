import Foundation

public enum NullFlavor: String, CaseIterable, Sendable {
    case NI, NA, UNK, ASKU, NAV, NASK, MSK, OTH, TRC, PINF, NINF, INV, DER, UNC, QS, NAVU, NP
}

/// Immutable validated XML-backed value. A null value cannot also carry a payload.
public protocol HL7DataType: Equatable, Sendable {
    static var typeName: String { get }
    var node: XMLNode { get }
    init(node: XMLNode) throws
}

extension HL7DataType {
    public var nullFlavor: NullFlavor? { node[attribute: "nullFlavor"].flatMap(NullFlavor.init(rawValue:)) }
    public init(nullFlavor: NullFlavor) {
        // Every conforming type accepts a standalone nullFlavor.
        self = try! Self(node: XMLNode(Self.typeName, attributes: ["nullFlavor": nullFlavor.rawValue]))
    }
    public func xml(named name: String, anyTyped: Bool = false) -> XMLNode {
        var result = node
        result.name = XMLName(name, namespaceURI: CDANamespace.hl7)
        if anyTyped {
            result.attributes[XMLName("type", namespaceURI: CDANamespace.xsi, prefix: "xsi")] = Self.typeName
            result.namespaces["xsi"] = CDANamespace.xsi
            result.namespaces[""] = CDANamespace.hl7
        }
        return result
    }
}

enum HL7TypeValidation {
    static func validate(_ node: XMLNode, type: String) throws {
        if type == "CS" {
            let metadata = ["codeSystem", "codeSystemName", "codeSystemVersion", "displayName", "originalText"]
            guard !metadata.contains(where: { node[attribute: $0] != nil }), node.children.isEmpty else {
                throw CDAError.invalidDataType(type)
            }
        }
        if let raw = node[attribute: "nullFlavor"] {
            guard NullFlavor(rawValue: raw) != nil else { throw CDAError.invalidDataType(type) }
            let payload = ["value", "root", "extension", "code", "displayName"]
            let permitsConceptText = ["CD", "CE"].contains(type) && ["OTH", "UNC"].contains(raw)
            let directText = node.content.compactMap { item -> String? in
                if case .text(let text) = item { return text }
                return nil
            }.joined()
            guard !payload.contains(where: { node[attribute: $0] != nil }),
                  directText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  node.children.allSatisfy({ child in
                      permitsConceptText && child.name.namespaceURI == CDANamespace.hl7 &&
                          ["originalText", "translation"].contains(child.name.localName)
                  }) else {
                throw CDAError.nullFlavorConflict(type)
            }
            for child in node.children {
                try validate(child, type: child.name.localName == "originalText" ? "ED" : "CD")
            }
            return
        }
        let value = node[attribute: "value"]
        switch type {
        case "TS":
            guard let value, validTS(value) else { throw CDAError.invalidDataType(type) }
        case "INT":
            guard let value, value.range(of: "^[+-]?[0-9]+$", options: .regularExpression) != nil else {
                throw CDAError.invalidDataType(type)
            }
        case "REAL", "PQ":
            guard let value, value.range(of: "^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?$",
                                         options: .regularExpression) != nil else { throw CDAError.invalidDataType(type) }
        case "BL":
            guard let value, ["true", "false", "1", "0"].contains(value) else { throw CDAError.invalidDataType(type) }
        case "II":
            guard let root = node[attribute: "root"], validUID(root) else { throw CDAError.invalidDataType(type) }
        case "CS":
            guard let code = node[attribute: "code"], !code.isEmpty else { throw CDAError.invalidDataType(type) }
        case "TEL":
            guard value != nil else { throw CDAError.invalidDataType(type) }
        case "ED":
            if let representation = node[attribute: "representation"], !["B64", "TXT"].contains(representation) {
                throw CDAError.invalidDataType(type)
            }
            if node[attribute: "representation"] == "B64" {
                let compact = node.textContent.filter { !$0.isWhitespace }
                guard Data(base64Encoded: compact) != nil else { throw CDAError.invalidDataType(type) }
            }
        case "IVL_TS", "IVL_PQ":
            let point = type == "IVL_TS" ? "TS" : "PQ"
            if value != nil { try validate(node, type: point) }
            for child in node.children where ["low", "high", "center", "width"].contains(child.name.localName) {
                try validate(child, type: child.name.localName == "width" ? "PQ" : point)
            }
            if (node.first("center") != nil && (node.first("low") != nil || node.first("high") != nil)) ||
                (node.first("low") != nil && node.first("high") != nil && node.first("width") != nil) ||
                (value != nil && !node.children.isEmpty) {
                throw CDAError.invalidDataType(type)
            }
        case "PIVL_TS":
            if let phase = node.first("phase") { try validate(phase, type: "IVL_TS") }
            if let period = node.first("period") { try validate(period, type: "PQ") }
        default: break
        }
    }

    static func validUID(_ value: String) -> Bool {
        let oid = "[0-2](?:\\.(?:0|[1-9][0-9]*))+"
        let uuid = "[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"
        let ruid = "[A-Za-z][A-Za-z0-9-]*"
        return value.range(of: "\\A(?:\(oid)|\(uuid)|\(ruid))\\z", options: .regularExpression) != nil
    }

    static func validTS(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}([0-9]{2}){0,5}(\\.[0-9]+)?([+-][0-9]{4})?$", options: .regularExpression) != nil else { return false }
        var core = value
        if let offset = core.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let zone = String(core[core.index(after: offset)...])
            guard let hours = Int(zone.prefix(2)), let minutes = Int(zone.suffix(2)), hours <= 23, minutes < 60 else { return false }
            core = String(core[..<offset])
        }
        let parts = core.split(separator: ".")
        let digits = String(parts[0])
        if parts.count > 1 && digits.count != 14 { return false }
        func number(_ start: Int, _ length: Int) -> Int {
            Int(digits.dropFirst(start).prefix(length)) ?? 0
        }
        let year = number(0, 4)
        guard year > 0 else { return false }
        if digits.count >= 6 && !(1...12).contains(number(4, 2)) { return false }
        if digits.count >= 8 {
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...days[number(4, 2) - 1]).contains(number(6, 2)) else { return false }
        }
        if digits.count >= 10 && number(8, 2) > 23 { return false }
        if digits.count >= 12 && number(10, 2) > 59 { return false }
        if digits.count >= 14 && number(12, 2) > 60 { return false }
        return true
    }
}
