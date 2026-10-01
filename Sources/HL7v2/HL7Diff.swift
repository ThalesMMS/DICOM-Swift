import Foundation

public struct HL7Difference: Codable, Equatable, Sendable {
    public enum Change: String, Codable, Sendable { case added, removed, changed }
    public let path: String
    public let change: Change
}

public enum HL7Diff {
    /// Occurrence-aware positional comparison. Detail contains paths and change kinds only.
    public static func compare(_ a: HL7Message, _ b: HL7Message) -> [HL7Difference] {
        func leaves(_ node: HL7InspectionNode) -> [String: HL7InspectionNode] {
            if node.children.isEmpty { return [node.path: node] }
            return node.children.reduce(into: [:]) { $0.merge(leaves($1)) { _, rhs in rhs } }
        }
        let lhs = leaves(HL7Inspector.tree(a, includeValues: true))
        let rhs = leaves(HL7Inspector.tree(b, includeValues: true))
        return Set(lhs.keys).union(rhs.keys).sorted().compactMap { path in
            switch (lhs[path], rhs[path]) {
            case (nil, .some): return .init(path: path, change: .added)
            case (.some, nil): return .init(path: path, change: .removed)
            case (.some(let a), .some(let b)) where a.state != b.state || a.value != b.value:
                return .init(path: path, change: .changed)
            default: return nil
            }
        }
    }
}
