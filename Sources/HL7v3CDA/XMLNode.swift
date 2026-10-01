import Foundation

public enum CDANamespace {
    public static let hl7 = "urn:hl7-org:v3"
    public static let sdtc = "urn:hl7-org:sdtc"
    public static let xsi = "http://www.w3.org/2001/XMLSchema-instance"
    public static let xml = "http://www.w3.org/XML/1998/namespace"
}

public struct XMLName: Hashable, Sendable {
    public var localName: String
    public var namespaceURI: String
    public var prefix: String

    public init(_ localName: String, namespaceURI: String = "", prefix: String = "") {
        self.localName = localName
        self.namespaceURI = namespaceURI
        self.prefix = prefix
    }

    public var qualifiedName: String { prefix.isEmpty ? localName : "\(prefix):\(localName)" }
}

public indirect enum XMLContent: Equatable, Sendable {
    case element(XMLNode)
    case text(String)
    case comment(String)
    case processingInstruction(String, String)
}

/// Ordered mixed content; namespace declarations are kept even when used only in QName attribute values.
public struct XMLNode: Equatable, Sendable {
    public var name: XMLName
    public var attributes: [XMLName: String]
    public var namespaces: [String: String]
    public var content: [XMLContent]
    // Context needed to interpret or detach QName-valued extension attributes.
    var inheritedNamespaces: [String: String] = [:]

    public static func == (lhs: XMLNode, rhs: XMLNode) -> Bool {
        lhs.name == rhs.name && lhs.attributes == rhs.attributes && lhs.namespaces == rhs.namespaces && lhs.content == rhs.content
    }

    var schemaTypeName: XMLName? {
        guard let raw = attributes.first(where: { $0.key.namespaceURI == CDANamespace.xsi && $0.key.localName == "type" })?.value else { return nil }
        let pieces = raw.split(separator: ":").map(String.init)
        guard pieces.count == 1 || pieces.count == 2, let local = pieces.last else { return nil }
        let prefix = pieces.count == 2 ? pieces[0] : ""
        let uri = namespaces[prefix] ?? inheritedNamespaces[prefix] ?? (prefix.isEmpty ? name.namespaceURI : "")
        return XMLName(local, namespaceURI: uri, prefix: prefix)
    }

    public init(_ name: String, namespaceURI: String = CDANamespace.hl7, prefix: String = "",
                attributes: [String: String] = [:], children: [XMLNode] = [], text: String? = nil) {
        self.name = XMLName(name, namespaceURI: namespaceURI, prefix: prefix)
        self.attributes = Dictionary(uniqueKeysWithValues: attributes.map { (XMLName($0.key), $0.value) })
        self.namespaces = [:]
        self.content = children.map(XMLContent.element)
        if let text { self.content.append(.text(text)) }
    }

    public var children: [XMLNode] {
        get { content.compactMap { if case .element(let node) = $0 { node } else { nil } } }
        set { content = newValue.map(XMLContent.element) }
    }

    public var textContent: String {
        content.map {
            switch $0 {
            case .text(let text): text
            case .element(let node): node.textContent
            default: ""
            }
        }.joined()
    }

    public subscript(attribute name: String) -> String? {
        get { attributes[XMLName(name)] }
        set { attributes[XMLName(name)] = newValue }
    }

    public func elements(_ name: String, namespaceURI: String = CDANamespace.hl7) -> [XMLNode] {
        children.filter { $0.name.localName == name && $0.name.namespaceURI == namespaceURI }
    }

    public func first(_ name: String) -> XMLNode? { elements(name).first }

    public func descendants() -> [XMLNode] {
        var result: [XMLNode] = []
        var pending = [self]
        while let node = pending.popLast() {
            result.append(node)
            pending.append(contentsOf: node.children.reversed())
        }
        return result
    }

    mutating func replace(_ name: String, with nodes: [XMLNode], order: [String]) {
        let firstIndex = content.firstIndex {
            if case .element(let node) = $0 { return node.name.namespaceURI == CDANamespace.hl7 && node.name.localName == name }
            return false
        }
        content.removeAll {
            if case .element(let node) = $0 { return node.name.namespaceURI == CDANamespace.hl7 && node.name.localName == name }
            return false
        }
        let rank = order.firstIndex(of: name) ?? order.count
        let insertion = firstIndex.map { min($0, content.count) } ?? content.firstIndex {
            if case .element(let node) = $0 {
                return (order.firstIndex(of: node.name.localName) ?? order.count) > rank
            }
            return false
        } ?? content.count
        content.insert(contentsOf: nodes.map(XMLContent.element), at: insertion)
    }
}
