import Foundation

public struct CDADocumentSerializer: Sendable {
    public var indentation: Int?
    public init(indentation: Int? = nil) { self.indentation = indentation }
    public func serialize(_ document: ClinicalDocument) throws -> Data {
        guard document.node.name.localName == "ClinicalDocument", document.node.name.namespaceURI == CDANamespace.hl7 else {
            throw CDAError.invalidDocument
        }
        try CDAInspection.validateTypes(document.node)
        guard !document.validateLinks().contains(where: { $0.kind == .cycle }) else { throw CDAError.cyclicReferences }
        return try XMLSerializer(indentation: indentation).serialize(ordered(document.node))
    }

    private func ordered(_ node: XMLNode) -> XMLNode {
        var result = node
        // Mixed narrative and datatype content is never reordered.
        guard node.name.namespaceURI == CDANamespace.hl7,
              let order = CDAInspection.orders[node.name.localName] else {
            if node.name.localName == "component" {
                result.content = node.content.map { if case .element(let child) = $0 { .element(ordered(child)) } else { $0 } }
            }
            return result
        }
        result.content = node.content.map { if case .element(let child) = $0 { .element(ordered(child)) } else { $0 } }
        let indices = result.content.indices.filter { index in
            if case .element(let child) = result.content[index] {
                return [CDANamespace.hl7, CDANamespace.sdtc].contains(child.name.namespaceURI) && order.contains(child.name.localName)
            }
            return false
        }
        let sorted = indices.enumerated().sorted { lhs, rhs in
            guard case .element(let left) = result.content[lhs.element],
                  case .element(let right) = result.content[rhs.element] else { return lhs.offset < rhs.offset }
            let a = order.firstIndex(of: left.name.localName) ?? order.count
            let b = order.firstIndex(of: right.name.localName) ?? order.count
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map { result.content[$0.element] }
        for (index, content) in zip(indices, sorted) { result.content[index] = content }
        return result
    }
}
