import Foundation

public enum CDAStatement: Equatable, Sendable {
    case observation(Observation)
    case substanceAdministration(SubstanceAdministration)
    case supply(Supply)
    case procedure(Procedure)
    case encounter(Encounter)
    case organizer(Organizer)
    case act(Act)
    case generic(XMLNode)

    public init(node: XMLNode) {
        guard node.name.namespaceURI == CDANamespace.hl7 else { self = .generic(node); return }
        switch node.name.localName {
        case "observation": self = .observation(Observation(node: node))
        case "substanceAdministration": self = .substanceAdministration(SubstanceAdministration(node: node))
        case "supply": self = .supply(Supply(node: node))
        case "procedure": self = .procedure(Procedure(node: node))
        case "encounter": self = .encounter(Encounter(node: node))
        case "organizer": self = .organizer(Organizer(node: node))
        case "act": self = .act(Act(node: node))
        default: self = .generic(node)
        }
    }
    public var node: XMLNode {
        switch self {
        case .observation(let value): value.node
        case .substanceAdministration(let value): value.node
        case .supply(let value): value.node
        case .procedure(let value): value.node
        case .encounter(let value): value.node
        case .organizer(let value): value.node
        case .act(let value): value.node
        case .generic(let node): node
        }
    }
}

extension Entry {
    public init(_ statement: CDAStatement, typeCode: String? = nil) {
        node = XMLNode("entry", children: [statement.node])
        node[attribute: "typeCode"] = typeCode
    }
    public var statement: CDAStatement? {
        get { node.children.first { !["realmCode", "typeId", "templateId"].contains($0.name.localName) }.map(CDAStatement.init(node:)) }
        set {
            if let old = statement?.node, let index = node.content.firstIndex(of: .element(old)) {
                node.content.remove(at: index)
                if let newValue { node.content.insert(.element(newValue.node), at: index) }
            } else if let newValue { node.content.append(.element(newValue.node)) }
        }
    }
}
extension EntryRelationship {
    public var inversionInd: Bool? {
        get { node[attribute: "inversionInd"].map { $0 == "true" || $0 == "1" } }
        set { node[attribute: "inversionInd"] = newValue.map { $0 ? "true" : "false" } }
    }
    public var statement: CDAStatement? {
        get { Entry(node: node).statement }
        set { var entry = Entry(node: node); entry.statement = newValue; node = entry.node }
    }
}
extension Organizer {
    public var components: [CDAStatement] {
        get { node.elements("component").compactMap { Entry(node: $0).statement } }
        set { node.replace("component", with: newValue.map { XMLNode("component", children: [$0.node]) }, order: Self.childOrder) }
    }
}
