import Foundation

/// A path to an element inside nested sequences: `(0008,1115)[0]/(0008,1140)[*]/(0008,1155)`.
///
/// Each component names a tag and, when the element is a sequence that is descended into, a zero-based item
/// index or `*` for every item. The last component addresses the element itself and carries no index unless
/// the caller wants a whole item. Tags are written as `(gggg,eeee)` or eight hex digits; components are
/// separated by `/`.
public struct DicomTagPath: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Item: Equatable, Hashable, Sendable {
        case index(Int)
        case all
    }

    public struct Component: Equatable, Hashable, Sendable {
        public var tag: Int
        public var item: Item?

        public init(tag: Int, item: Item? = nil) {
            self.tag = tag
            self.item = item
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case malformedComponent(String)
        case indexOnLastComponent(String)
        case missingItemIndex(String)
    }

    public var components: [Component]

    public init(components: [Component]) {
        self.components = components
    }

    public init(_ tag: Int) {
        components = [Component(tag: tag)]
    }

    public init(_ tag: DicomTag) {
        self.init(tag.rawValue)
    }

    /// Parses `(0008,1115)[0]/00081155`; every component except the last needs an item selector.
    public init(parsing text: String) throws {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, !parts.allSatisfy(\.isEmpty) else { throw ParseError.empty }
        var components: [Component] = []
        for (index, part) in parts.enumerated() {
            guard let component = Self.component(from: part) else { throw ParseError.malformedComponent(part) }
            if index < parts.count - 1, component.item == nil { throw ParseError.missingItemIndex(part) }
            components.append(component)
        }
        self.components = components
    }

    private static func component(from text: String) -> Component? {
        var tagText = text
        var item: Item?
        if let open = text.firstIndex(of: "[") {
            guard text.hasSuffix("]") else { return nil }
            let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
            if inner == "*" {
                item = .all
            } else if let number = Int(inner), number >= 0 {
                item = .index(number)
            } else {
                return nil
            }
            tagText = String(text[..<open])
        }
        guard let tag = Self.tag(from: tagText) else { return nil }
        return Component(tag: tag, item: item)
    }

    static func tag(from text: String) -> Int? {
        var hex = text.uppercased()
        if hex.hasPrefix("("), hex.hasSuffix(")") {
            hex = String(hex.dropFirst().dropLast()).replacingOccurrences(of: ",", with: "")
        }
        guard hex.count == 8, hex.allSatisfy(\.isHexDigit), let value = Int(hex, radix: 16) else { return nil }
        return value
    }

    public var last: Component? { components.last }

    public var isTopLevel: Bool { components.count == 1 }

    public var description: String {
        components.map { component in
            let tag = String(format: "(%04X,%04X)", component.tag >> 16 & 0xFFFF, component.tag & 0xFFFF)
            switch component.item {
            case .none: return tag
            case .all: return tag + "[*]"
            case .index(let index): return tag + "[\(index)]"
            }
        }.joined(separator: "/")
    }

    /// The path with a concrete item index in place of `*` at every level (used when reporting matches).
    public func appending(_ component: Component) -> DicomTagPath {
        DicomTagPath(components: components + [component])
    }
}

/// Errors from path-addressed data set operations.
public enum DicomTagPathError: Error, Equatable, Sendable {
    /// An intermediate sequence component does not select an item.
    case missingItemIndex(DicomTagPath)
    /// The element at the intermediate component is not a sequence.
    case notASequence(DicomTagPath)
    /// The item index is beyond the sequence's items.
    case itemOutOfRange(DicomTagPath, count: Int)
    /// Wildcards are only allowed when selecting, not when setting a single value.
    case wildcardNotAllowed(DicomTagPath)
    /// The element the last component names is absent.
    case notFound(DicomTagPath)
}

public extension DicomDataSet {
    /// The single element at a concrete path; `nil` when absent, throws when an intermediate is not a sequence.
    func element(at path: DicomTagPath) throws -> DicomDataElement? {
        let matches = try elements(matching: path)
        guard !path.components.contains(where: { $0.item == .all }) else { throw DicomTagPathError.wildcardNotAllowed(path) }
        return matches.first?.element
    }

    /// Every element the path selects, with the concrete path of each match (wildcards resolved).
    func elements(matching path: DicomTagPath) throws -> [(path: DicomTagPath, element: DicomDataElement)] {
        guard let first = path.components.first else { return [] }
        return try select(path: path, from: 0, resolved: DicomTagPath(components: []), in: self, first: first)
    }

    private func select(path: DicomTagPath, from index: Int, resolved: DicomTagPath, in dataSet: DicomDataSet,
                        first: DicomTagPath.Component) throws -> [(path: DicomTagPath, element: DicomDataElement)] {
        let component = path.components[index]
        guard let element = dataSet[component.tag] else { return [] }
        let isLast = index == path.components.count - 1
        if isLast, component.item == nil {
            return [(resolved.appending(component), element)]
        }
        guard case .sequence(let items) = element.value else {
            if case .empty = element.value, component.item != nil { return [] }
            throw DicomTagPathError.notASequence(resolved.appending(component))
        }
        let indices: [Int]
        switch component.item {
        case .all: indices = Array(items.indices)
        case .none: throw DicomTagPathError.missingItemIndex(resolved.appending(component))
        case .index(let wanted):
            guard items.indices.contains(wanted) else {
                if isLast { return [] }
                throw DicomTagPathError.itemOutOfRange(resolved.appending(component), count: items.count)
            }
            indices = [wanted]
        }
        var results: [(path: DicomTagPath, element: DicomDataElement)] = []
        for itemIndex in indices {
            let concrete = resolved.appending(.init(tag: component.tag, item: .index(itemIndex)))
            if isLast {
                // A trailing item selector yields the item's elements as a whole: the sequence element narrowed to that item.
                results.append((concrete, DicomDataElement(tag: element.tag, vr: element.vr, value: .sequence([items[itemIndex]]), name: element.name)))
            } else {
                results += try select(path: path, from: index + 1, resolved: concrete, in: items[itemIndex].dataSet, first: first)
            }
        }
        return results
    }

    /// Sets an element at a concrete path (the element's own tag is taken from the path's last component).
    /// Intermediate sequences and items must exist; `creatingItems` appends missing items only at the exact next index.
    func setting(_ element: DicomDataElement, at path: DicomTagPath, creatingItems: Bool = false) throws -> DicomDataSet {
        guard !path.components.contains(where: { $0.item == .all }) else { throw DicomTagPathError.wildcardNotAllowed(path) }
        guard let last = path.last, last.item == nil else { throw DicomTagPathError.wildcardNotAllowed(path) }
        return try mutate(path: path, from: 0, resolved: DicomTagPath(components: []), creatingItems: creatingItems) { dataSet in
            dataSet.set(DicomDataElement(tag: last.tag, vr: element.vr, value: element.value, name: element.name))
        }
    }

    /// Removes the element at a concrete path; removing an absent element is not an error.
    func removing(at path: DicomTagPath) throws -> DicomDataSet {
        guard !path.components.contains(where: { $0.item == .all }) else { throw DicomTagPathError.wildcardNotAllowed(path) }
        guard let last = path.last else { return self }
        if let item = last.item {
            // Removing one item of a sequence.
            let parent = DicomTagPath(components: Array(path.components.dropLast()))
            return try mutate(path: parent.appending(.init(tag: last.tag)), from: 0, resolved: DicomTagPath(components: []), creatingItems: false) { dataSet in
                guard let element = dataSet[last.tag], case .sequence(var items) = element.value, case .index(let index) = item, items.indices.contains(index) else { return }
                items.remove(at: index)
                dataSet.set(DicomDataElement(tag: element.tag, vr: element.vr, value: items.isEmpty ? .empty : .sequence(items), name: element.name))
            }
        }
        return try mutate(path: path, from: 0, resolved: DicomTagPath(components: []), creatingItems: false) { dataSet in
            dataSet.remove(last.tag)
        }
    }

    private func mutate(path: DicomTagPath, from index: Int, resolved: DicomTagPath, creatingItems: Bool,
                        _ body: (inout DicomDataSet) throws -> Void) throws -> DicomDataSet {
        var copy = self
        if index == path.components.count - 1 {
            try body(&copy)
            return copy
        }
        let component = path.components[index]
        let here = resolved.appending(component)
        guard case .index(let wanted) = component.item else { throw DicomTagPathError.wildcardNotAllowed(here) }
        guard let element = copy[component.tag] else {
            guard creatingItems, wanted == 0 else { throw DicomTagPathError.notFound(here) }
            let child = try DicomDataSet().mutate(path: path, from: index + 1, resolved: here, creatingItems: creatingItems, body)
            copy.set(DicomDataElement(tag: component.tag, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: child)])))
            return copy
        }
        var items: [DicomSequenceItem]
        switch element.value {
        case .sequence(let existing): items = existing
        case .empty where element.vr == .SQ: items = []
        default: throw DicomTagPathError.notASequence(here)
        }
        if wanted == items.count, creatingItems {
            items.append(DicomSequenceItem(dataSet: DicomDataSet()))
        }
        guard items.indices.contains(wanted) else { throw DicomTagPathError.itemOutOfRange(here, count: items.count) }
        let child = try items[wanted].dataSet.mutate(path: path, from: index + 1, resolved: here, creatingItems: creatingItems, body)
        items[wanted] = DicomSequenceItem(dataSet: child)
        copy.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .sequence(items), name: element.name))
        return copy
    }
}
