import Foundation

public enum CDADiffChangeKind: String, Codable, CaseIterable, Sendable {
    case added
    case removed
    case changed
}

public struct CDADiffChange: Codable, Equatable, Sendable {
    public let kind: CDADiffChangeKind
    public let path: String
    public let before: String?
    public let after: String?

    public init(kind: CDADiffChangeKind, path: String, before: String? = nil, after: String? = nil) {
        self.kind = kind
        self.path = path
        self.before = before
        self.after = after
    }

    public var oldValue: String? { before }
    public var newValue: String? { after }
}

public struct CDANarrativeDiff: Codable, Equatable, Sendable {
    public let path: String
    public let before: String?
    public let after: String?

    public init(path: String, before: String?, after: String?) {
        self.path = path
        self.before = before
        self.after = after
    }
}

public struct CDADiff: Codable, Equatable, Sendable {
    public var changes: [CDADiffChange]
    public var narrativeChanges: [CDANarrativeDiff]

    public init(changes: [CDADiffChange] = [], narrativeChanges: [CDANarrativeDiff] = []) {
        self.changes = changes
        self.narrativeChanges = narrativeChanges
    }

    public var isEmpty: Bool { changes.isEmpty && narrativeChanges.isEmpty }
    public var added: [CDADiffChange] { changes.filter { $0.kind == .added } }
    public var removed: [CDADiffChange] { changes.filter { $0.kind == .removed } }
    public var changed: [CDADiffChange] { changes.filter { $0.kind == .changed } }
    public var addedElements: [CDADiffChange] { added }
    public var removedElements: [CDADiffChange] { removed }
    public var changedElements: [CDADiffChange] { changed }
    public var narrativeTextDiffs: [CDANarrativeDiff] { narrativeChanges }
}

public enum CDADocumentComparator {
    public static func compare(_ a: ClinicalDocument, _ b: ClinicalDocument) -> CDADiff {
        var result = CDADiff()
        compareNodes(a.node, b.node, path: "/" + a.node.name.localName, result: &result)
        return result
    }

    public static func compare(a: ClinicalDocument, b: ClinicalDocument) -> CDADiff { compare(a, b) }

    private static func compareNodes(_ lhs: XMLNode, _ rhs: XMLNode, path: String, result: inout CDADiff) {
        if lhs.name != rhs.name {
            result.changes.append(.init(kind: .changed, path: path, before: lhs.name.qualifiedName, after: rhs.name.qualifiedName))
            return
        }
        let attributeKeys = Set(lhs.attributes.keys).union(rhs.attributes.keys).sorted {
            let left = [$0.namespaceURI, $0.localName, $0.prefix]
            let right = [$1.namespaceURI, $1.localName, $1.prefix]
            return left.lexicographicallyPrecedes(right)
        }
        for key in attributeKeys {
            let old = lhs.attributes[key]
            let new = rhs.attributes[key]
            guard old != new else { continue }
            let attributePath = path + "/@" + key.localName
            result.changes.append(.init(kind: .changed, path: attributePath, before: old, after: new))
        }

        let lhsDirectText = lhs.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        let rhsDirectText = rhs.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
        if lhsDirectText != rhsDirectText {
            if isNarrativeNode(lhs) {
                result.narrativeChanges.append(.init(path: path, before: lhsDirectText, after: rhsDirectText))
            }
            result.changes.append(.init(kind: .changed, path: path, before: lhsDirectText.isEmpty ? nil : lhsDirectText,
                                        after: rhsDirectText.isEmpty ? nil : rhsDirectText))
        }

        let lhsChildren = lhs.children
        let rhsChildren = rhs.children
        var matchedRight = Set<Int>()
        for (leftIndex, child) in lhsChildren.enumerated() {
            let candidate = matchingChildIndex(for: child, among: rhsChildren, used: matchedRight)
            guard let rightIndex = candidate else {
                result.changes.append(.init(kind: .removed, path: childPath(path, child: child, index: leftIndex)))
                continue
            }
            matchedRight.insert(rightIndex)
            compareNodes(child, rhsChildren[rightIndex], path: childPath(path, child: child, index: leftIndex), result: &result)
        }
        for (rightIndex, child) in rhsChildren.enumerated() where !matchedRight.contains(rightIndex) {
            result.changes.append(.init(kind: .added, path: childPath(path, child: child, index: rightIndex)))
        }
    }

    private static func matchingChildIndex(for child: XMLNode, among siblings: [XMLNode], used: Set<Int>) -> Int? {
        if let identity = entryIdentity(child), child.name.localName == "entry" {
            return siblings.indices.first { !used.contains($0) && siblings[$0].name.localName == "entry" && entryIdentity(siblings[$0]) == identity }
        }
        return siblings.indices.first { !used.contains($0) && siblings[$0].name.localName == child.name.localName }
    }

    private static func childPath(_ parent: String, child: XMLNode, index: Int) -> String {
        parent + "/" + child.name.localName + "[\(index + 1)]"
    }

    private static func entryIdentity(_ entry: XMLNode) -> String? {
        guard entry.name.localName == "entry", let statement = entry.children.first(where: {
            ["act", "observation", "substanceAdministration", "organizer", "procedure", "encounter", "supply"].contains($0.name.localName)
        }), let id = statement.first("id"), let root = id[attribute: "root"] else { return nil }
        return root + "#" + (id[attribute: "extension"] ?? "")
    }

    private static func isNarrativeNode(_ node: XMLNode) -> Bool {
        node.name.localName == "text" || node.name.localName == "paragraph" || node.name.localName == "content" || node.name.localName == "listItem"
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public enum CDAMergePolicy: String, Codable, CaseIterable, Sendable {
    case preferIncoming
    case preferBase
    case unionEntriesByID
}

public struct CDAMergeConflict: Codable, Equatable, Sendable {
    public let path: String
    public let base: String?
    public let incoming: String?

    public init(path: String, base: String? = nil, incoming: String? = nil) {
        self.path = path
        self.base = base
        self.incoming = incoming
    }
}

public struct CDADroppedNode: Codable, Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct CDAMergeResult: Sendable {
    public let document: ClinicalDocument
    public let conflicts: [CDAMergeConflict]
    public let droppedNodes: [CDADroppedNode]

    public init(document: ClinicalDocument, conflicts: [CDAMergeConflict], droppedNodes: [CDADroppedNode]) {
        self.document = document
        self.conflicts = conflicts
        self.droppedNodes = droppedNodes
    }

    public var merged: ClinicalDocument { document }
    public var mergedDocument: ClinicalDocument { document }
    public var dropped: [CDADroppedNode] { droppedNodes }
    public var droppedPaths: [String] { droppedNodes.map(\.path) }
    public var hasConflicts: Bool { !conflicts.isEmpty }
}

public enum CDADocumentMerger {
    /// Merge is intentionally non-throwing: the result records every conflict
    /// and dropped node.  `try` remains harmless for callers that use a common
    /// throwing pipeline with versioning operations.
    public static func merge(base: ClinicalDocument, incoming: ClinicalDocument,
                             policy: CDAMergePolicy = .preferIncoming) -> CDAMergeResult {
        var conflicts: [CDAMergeConflict] = []
        var dropped: [CDADroppedNode] = []
        let remappedIncoming = remapCollidingNarrativeIDs(base: base.node, incoming: incoming.node)
        var mergedNode = mergeNode(base.node, incoming: remappedIncoming, path: "/" + base.node.name.localName,
                                   policy: policy, conflicts: &conflicts, dropped: &dropped)
        mergedNode = normalizeReferences(in: mergedNode)
        return CDAMergeResult(document: ClinicalDocument(node: mergedNode), conflicts: conflicts, droppedNodes: dropped)
    }

    public static func merge(_ base: ClinicalDocument, _ incoming: ClinicalDocument,
                             policy: CDAMergePolicy = .preferIncoming) -> CDAMergeResult {
        merge(base: base, incoming: incoming, policy: policy)
    }

    private static func mergeNode(_ base: XMLNode, incoming: XMLNode, path: String, policy: CDAMergePolicy,
                                  conflicts: inout [CDAMergeConflict], dropped: inout [CDADroppedNode]) -> XMLNode {
        guard base.name == incoming.name else {
            conflicts.append(.init(path: path, base: base.name.qualifiedName, incoming: incoming.name.qualifiedName))
            return policy == .preferBase ? base : incoming
        }
        var output = policy == .preferBase ? base : incoming
        var attributes = base.attributes
        for (key, value) in incoming.attributes {
            if let old = base.attributes[key], old != value {
                conflicts.append(.init(path: path + "/@" + key.localName, base: old, incoming: value))
                attributes[key] = policy == .preferBase ? old : value
            } else { attributes[key] = value }
        }
        output.attributes = attributes
        output.namespaces = mergeNamespaces(base.namespaces, incoming.namespaces)

        let baseText = base.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined()
        let incomingText = incoming.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined()
        if baseText != incomingText && !baseText.isEmpty && !incomingText.isEmpty {
            conflicts.append(.init(path: path, base: baseText, incoming: incomingText))
        }

        let baseChildren = base.children
        let incomingChildren = incoming.children
        var resultChildren: [XMLNode] = []
        var usedIncoming = Set<Int>()
        for (baseIndex, baseChild) in baseChildren.enumerated() {
            let match = matchForMerge(baseChild, index: baseIndex, incoming: incomingChildren, used: usedIncoming,
                                      unionEntries: policy == .unionEntriesByID)
            if let incomingIndex = match {
                usedIncoming.insert(incomingIndex)
                let child = mergeNode(baseChild, incoming: incomingChildren[incomingIndex],
                                      path: childPath(path, child: baseChild, index: baseIndex), policy: policy,
                                      conflicts: &conflicts, dropped: &dropped)
                resultChildren.append(child)
            } else if policy == .preferBase || policy == .unionEntriesByID {
                resultChildren.append(baseChild)
                if policy == .preferBase { dropped.append(.init(path: childPath(path, child: baseChild, index: baseIndex), reason: "incoming omitted node")) }
            } else {
                dropped.append(.init(path: childPath(path, child: baseChild, index: baseIndex), reason: "preferIncoming replaced node"))
            }
        }
        for (incomingIndex, child) in incomingChildren.enumerated() where !usedIncoming.contains(incomingIndex) {
            if policy == .preferBase && baseChildren.contains(where: { $0.name.localName == child.name.localName }) {
                dropped.append(.init(path: childPath(path, child: child, index: incomingIndex), reason: "preferBase dropped incoming node"))
            } else { resultChildren.append(child) }
        }
        // Preserve non-element comments/PIs and emit the merged element list
        // in deterministic base-then-incoming order.  Rebuilding the element
        // slots avoids losing a base entry when the incoming document has fewer
        // children but unionEntriesByID adds a later entry.
        let nonElements = output.content.filter { item in
            if case .element = item { return false }
            return true
        }
        let orderedChildren: [XMLNode]
        if let order = CDAInspection.orders[output.name.localName] {
            orderedChildren = resultChildren.enumerated().sorted { left, right in
                let leftRank = order.firstIndex(of: left.element.name.localName) ?? order.count
                let rightRank = order.firstIndex(of: right.element.name.localName) ?? order.count
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }.map { $0.element }
        } else { orderedChildren = resultChildren }
        output.content = nonElements + orderedChildren.map(XMLContent.element)
        return output
    }

    private static func matchForMerge(_ child: XMLNode, index: Int, incoming: [XMLNode], used: Set<Int>, unionEntries: Bool) -> Int? {
        if unionEntries, child.name.localName == "entry", let identity = entryIdentity(child) {
            return incoming.indices.first { !used.contains($0) && incoming[$0].name.localName == "entry" && entryIdentity(incoming[$0]) == identity }
        }
        if let identifier = child[attribute: "ID"] {
            return incoming.indices.first { !used.contains($0) && incoming[$0].name.localName == child.name.localName && incoming[$0][attribute: "ID"] == identifier }
        }
        let candidates = incoming.indices.filter { !used.contains($0) && incoming[$0].name.localName == child.name.localName }
        let prior = 0 // child indexes are matched in stable occurrence order
        return candidates[safe: prior]
    }

    private static func entryIdentity(_ entry: XMLNode) -> String? {
        guard entry.name.localName == "entry", let statement = entry.children.first(where: {
            ["act", "observation", "substanceAdministration", "organizer", "procedure", "encounter", "supply"].contains($0.name.localName)
        }), let id = statement.first("id"), let root = id[attribute: "root"] else { return nil }
        return root + "#" + (id[attribute: "extension"] ?? "")
    }

    private static func childPath(_ parent: String, child: XMLNode, index: Int) -> String {
        parent + "/" + child.name.localName + "[\(index + 1)]"
    }

    private static func mergeNamespaces(_ base: [String: String], _ incoming: [String: String]) -> [String: String] {
        var result = base
        for (prefix, uri) in incoming where result[prefix] == nil { result[prefix] = uri }
        return result
    }

    private static func remapCollidingNarrativeIDs(base: XMLNode, incoming: XMLNode) -> XMLNode {
        let baseIDs = Set(base.descendants().compactMap { $0[attribute: "ID"] })
        var map: [String: String] = [:]
        var used = baseIDs
        for id in incoming.descendants().compactMap({ $0[attribute: "ID"] }) where baseIDs.contains(id) {
            var suffix = 2
            var candidate = "\(id)-merged"
            while used.contains(candidate) { suffix += 1; candidate = "\(id)-merged-\(suffix)" }
            map[id] = candidate
            used.insert(candidate)
        }
        guard !map.isEmpty else { return incoming }
        func rewrite(_ node: XMLNode) -> XMLNode {
            var result = node
            if let id = node[attribute: "ID"], let replacement = map[id] { result[attribute: "ID"] = replacement }
            for (name, value) in node.attributes where name.namespaceURI.isEmpty {
                if value.hasPrefix("#"), let replacement = map[String(value.dropFirst())] {
                    result.attributes[name] = "#" + replacement
                } else if name.localName == "IDREF" || name.localName == "IDREFS" {
                    let values = value.split(whereSeparator: { $0.isWhitespace }).map { map[String($0)] ?? String($0) }
                    result.attributes[name] = values.joined(separator: " ")
                }
            }
            result.content = node.content.map { item in
                if case .element(let child) = item { return .element(rewrite(child)) }
                return item
            }
            return result
        }
        return rewrite(incoming)
    }

    private static func normalizeReferences(in root: XMLNode) -> XMLNode {
        let ids = Set(root.descendants().compactMap { $0[attribute: "ID"] })
        var replacements: [String: String] = [:]
        for node in root.descendants() {
            for reference in CDALinks.references(node) where !ids.contains(reference) {
                if let candidate = ids.filter({ $0.hasPrefix(reference + "-merged") }).sorted().first {
                    replacements[reference] = candidate
                }
            }
        }
        guard !replacements.isEmpty else { return root }
        func rewrite(_ node: XMLNode) -> XMLNode {
            var result = node
            for (name, value) in node.attributes where name.namespaceURI.isEmpty {
                if value.hasPrefix("#"), let replacement = replacements[String(value.dropFirst())] {
                    result.attributes[name] = "#" + replacement
                } else if name.localName == "IDREF" || name.localName == "IDREFS" {
                    result.attributes[name] = value.split(whereSeparator: { $0.isWhitespace })
                        .map { replacements[String($0)] ?? String($0) }.joined(separator: " ")
                }
            }
            result.content = node.content.map { item in
                if case .element(let child) = item { return .element(rewrite(child)) }
                return item
            }
            return result
        }
        return rewrite(root)
    }
}
