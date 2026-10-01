import Foundation

public struct CDALinkFinding: Equatable, Sendable {
    public enum Kind: String, Sendable { case dangling, duplicateID, cycle }
    public let kind: Kind
    /// Structural path only; identifiers and clinical text are never included.
    public let path: String
}

enum CDALinks {
    static func references(_ node: XMLNode) -> [String] {
        var result: [String] = []
        for (name, value) in node.attributes where name.namespaceURI.isEmpty {
            if ["IDREF", "IDREFS", "referencedObject"].contains(name.localName) {
                result += value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            } else if name.localName == "href" || (name.localName == "value" && node.name.localName == "reference") {
                if value.hasPrefix("#") { result.append(String(value.dropFirst())) }
            }
        }
        return result
    }

    static func findings(in root: XMLNode) -> [CDALinkFinding] {
        var ids: [String: String] = [:]
        var refs: [(String?, String, String)] = []
        var findings: [CDALinkFinding] = []
        var pending: [(XMLNode, String, String?)] = [(root, "/" + root.name.localName, nil)]
        while let (node, path, parentID) = pending.popLast() {
            let id = node[attribute: "ID"]
            if let id {
                if ids[id] != nil { findings.append(.init(kind: .duplicateID, path: path)) }
                else { ids[id] = path }
            }
            for ref in references(node) { refs.append((id ?? parentID, ref, path)) }
            for (index, child) in node.children.enumerated().reversed() {
                pending.append((child, path + "/" + child.name.localName + "[\(index + 1)]", id ?? parentID))
            }
        }
        var edges: [String: Set<String>] = [:]
        var indegree = Dictionary(uniqueKeysWithValues: ids.keys.map { ($0, 0) })
        for (source, target, path) in refs {
            guard ids[target] != nil else { findings.append(.init(kind: .dangling, path: path)); continue }
            if let source, edges[source, default: []].insert(target).inserted { indegree[target, default: 0] += 1 }
        }
        // Kahn's algorithm is linear, bounded, and never follows a recursive IDREF chain.
        var ready = indegree.filter { $0.value == 0 }.map(\.key)
        var removed = 0
        while let id = ready.popLast() {
            removed += 1
            for target in edges[id] ?? [] {
                indegree[target, default: 0] -= 1
                if indegree[target] == 0 { ready.append(target) }
            }
        }
        if removed < ids.count { findings.append(.init(kind: .cycle, path: "/" + root.name.localName)) }
        return findings
    }
}
