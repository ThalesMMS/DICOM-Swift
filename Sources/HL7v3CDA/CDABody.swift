import Foundation

public enum CDABody: Equatable, Sendable {
    case structured(StructuredBody)
    case nonXML(NonXMLBody)
    case unknown(XMLNode)

    public var node: XMLNode {
        switch self {
        case .structured(let value): value.node
        case .nonXML(let value): value.node
        case .unknown(let node): node
        }
    }
}

extension ClinicalDocument {
    public var body: CDABody? {
        get {
            guard let component = node.first("component"), let body = component.children.first(where: {
                !["realmCode", "typeId", "templateId"].contains($0.name.localName)
            }) else { return nil }
            guard body.name.namespaceURI == CDANamespace.hl7 else { return .unknown(body) }
            switch body.name.localName {
            case "structuredBody": return .structured(StructuredBody(node: body))
            case "nonXMLBody": return .nonXML(NonXMLBody(node: body))
            default: return .unknown(body)
            }
        }
        set {
            var component = node.first("component") ?? XMLNode("component")
            component.content.removeAll {
                if case .element(let child) = $0 { return ["structuredBody", "nonXMLBody"].contains(child.name.localName) }
                return false
            }
            if let newValue { component.content.append(.element(newValue.node)) }
            node.replace("component", with: newValue == nil ? [] : [component], order: Self.childOrder)
        }
    }
    public func validateLinks() -> [CDALinkFinding] { CDALinks.findings(in: node) }
}

extension StructuredBody {
    public var sections: [Section] {
        get { node.elements("component").compactMap { $0.first("section").map(Section.init(node:)) } }
        set { node.replace("component", with: newValue.map { XMLNode("component", children: [$0.node]) }, order: Self.childOrder) }
    }
}

extension Section {
    public var narrative: XMLNode? {
        get { node.first("text") }
        set { node.replace("text", with: newValue.map { [$0] } ?? [], order: Self.childOrder) }
    }
    public var sections: [Section] {
        get { node.elements("component").compactMap { $0.first("section").map(Section.init(node:)) } }
        set { node.replace("component", with: newValue.map { XMLNode("component", children: [$0.node]) }, order: Self.childOrder) }
    }
    public func referencedNarrativeNodes(for entry: Entry) -> [XMLNode] {
        let references = Set(entry.node.descendants().flatMap(CDALinks.references))
        return (narrative?.descendants() ?? []).filter { node in
            node[attribute: "ID"].map { references.contains($0) } ?? false
        }
    }
    public func validateLinks() -> [CDALinkFinding] { CDALinks.findings(in: node) }
}
