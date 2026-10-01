import Foundation

/// A recursive, order-independent comparison of two data sets: every element is matched by tag inside every
/// sequence item (items matched by position), and VR, multiplicity and value are compared exactly.
public struct DicomDataSetDiff: Equatable, Sendable {
    public struct Options: Equatable, Sendable {
        /// Tags ignored at every level (the file meta group is always ignored when `ignoresFileMeta`).
        public var ignoredTags: Set<Int>
        /// Ignore every UI element (identity differences between derived instances).
        public var ignoresUIDs: Bool
        /// Ignore private elements.
        public var ignoresPrivate: Bool
        /// Ignore the file meta group (0002,xxxx).
        public var ignoresFileMeta: Bool
        /// Treat `.empty` and a zero-length value as equal, and ignore trailing padding in text.
        public var normalizesText: Bool

        public init(ignoredTags: Set<Int> = [], ignoresUIDs: Bool = false, ignoresPrivate: Bool = false,
                    ignoresFileMeta: Bool = true, normalizesText: Bool = true) {
            self.ignoredTags = ignoredTags
            self.ignoresUIDs = ignoresUIDs
            self.ignoresPrivate = ignoresPrivate
            self.ignoresFileMeta = ignoresFileMeta
            self.normalizesText = normalizesText
        }
    }

    public enum Kind: String, Equatable, Sendable {
        case added, removed, vrChanged, valueChanged, itemCountChanged
    }

    public struct Change: Equatable, Sendable, CustomStringConvertible {
        public let path: DicomTagPath
        public let kind: Kind
        public let before: DicomDataElement?
        public let after: DicomDataElement?

        public init(path: DicomTagPath, kind: Kind, before: DicomDataElement?, after: DicomDataElement?) {
            self.path = path
            self.kind = kind
            self.before = before
            self.after = after
        }

        public var description: String {
            switch kind {
            case .added: return "+ \(path) \(after?.vr.code ?? "") \(Self.summary(after))"
            case .removed: return "- \(path) \(before?.vr.code ?? "") \(Self.summary(before))"
            case .vrChanged: return "~ \(path) VR \(before?.vr.code ?? "") -> \(after?.vr.code ?? "")"
            case .valueChanged: return "~ \(path) \(before?.vr.code ?? "") \(Self.summary(before)) -> \(Self.summary(after))"
            case .itemCountChanged: return "~ \(path) items \(before?.sequenceItems.count ?? 0) -> \(after?.sequenceItems.count ?? 0)"
            }
        }

        public static func summary(_ element: DicomDataElement?) -> String {
            guard let element else { return "" }
            switch element.value {
            case .empty: return "(empty)"
            case .strings(let values): return values.joined(separator: "\\")
            case .signedIntegers(let values): return values.map(String.init).joined(separator: "\\")
            case .unsignedIntegers(let values): return values.map(String.init).joined(separator: "\\")
            case .floats(let values): return values.map { String($0) }.joined(separator: "\\")
            case .bytes(let data): return "\(data.count) bytes"
            case .sequence(let items): return "\(items.count) item(s)"
            }
        }
    }

    public let changes: [Change]
    public var isEmpty: Bool { changes.isEmpty }

    public init(changes: [Change]) {
        self.changes = changes
    }

    public static func compare(_ before: DicomDataSet, _ after: DicomDataSet, options: Options = .init()) -> DicomDataSetDiff {
        var changes: [Change] = []
        compare(before, after, at: DicomTagPath(components: []), options: options, into: &changes)
        return DicomDataSetDiff(changes: changes)
    }

    private static func ignored(_ element: DicomDataElement, options: Options) -> Bool {
        if options.ignoredTags.contains(element.tag) { return true }
        if options.ignoresFileMeta, element.group == 0x0002 { return true }
        if options.ignoresUIDs, element.vr == .UI { return true }
        if options.ignoresPrivate, element.isPrivate { return true }
        return false
    }

    private static func compare(_ before: DicomDataSet, _ after: DicomDataSet, at path: DicomTagPath, options: Options, into changes: inout [Change]) {
        let beforeByTag = Dictionary(uniqueKeysWithValues: before.elements.filter { !ignored($0, options: options) }.map { ($0.tag, $0) })
        let afterByTag = Dictionary(uniqueKeysWithValues: after.elements.filter { !ignored($0, options: options) }.map { ($0.tag, $0) })
        for tag in Set(beforeByTag.keys).union(afterByTag.keys).sorted() {
            let here = path.appending(.init(tag: tag))
            switch (beforeByTag[tag], afterByTag[tag]) {
            case (nil, let new?): changes.append(.init(path: here, kind: .added, before: nil, after: new))
            case (let old?, nil): changes.append(.init(path: here, kind: .removed, before: old, after: nil))
            case (let old?, let new?):
                if old.vr != new.vr {
                    changes.append(.init(path: here, kind: .vrChanged, before: old, after: new))
                    continue
                }
                if case .sequence(let oldItems) = old.value, case .sequence(let newItems) = new.value {
                    if oldItems.count != newItems.count {
                        changes.append(.init(path: here, kind: .itemCountChanged, before: old, after: new))
                    }
                    for (index, pair) in zip(oldItems, newItems).enumerated() {
                        compare(pair.0.dataSet, pair.1.dataSet, at: path.appending(.init(tag: tag, item: .index(index))), options: options, into: &changes)
                    }
                    continue
                }
                if !equal(old.value, new.value, vr: old.vr, options: options) {
                    changes.append(.init(path: here, kind: .valueChanged, before: old, after: new))
                }
            case (nil, nil): continue
            }
        }
    }

    private static func equal(_ lhs: DicomDataValue, _ rhs: DicomDataValue, vr: DicomVR, options: Options) -> Bool {
        guard options.normalizesText else { return lhs == rhs }
        return normalized(lhs, vr: vr) == normalized(rhs, vr: vr)
    }

    private static let integerVRs: Set<DicomVR> = [.US, .UL, .UV, .SS, .SL, .SV, .IS, .AT]
    private static let floatVRs: Set<DicomVR> = [.FL, .FD, .DS]

    private static func normalized(_ value: DicomDataValue, vr: DicomVR) -> DicomDataValue {
        // Numeric elements read through different paths (binary parse, string-typed decoder view, JSON) compare by value.
        if integerVRs.contains(vr) {
            switch value {
            case .strings(let values):
                if [.US, .UL, .UV].contains(vr) {
                    let numbers = values.compactMap { UInt($0.trimmingCharacters(in: .whitespaces)) }
                    if numbers.count == values.count { return normalized(.unsignedIntegers(numbers), vr: vr) }
                } else {
                    let numbers = values.map { Int($0.trimmingCharacters(in: .whitespaces), radix: vr == .AT ? 16 : 10) }
                    if numbers.allSatisfy({ $0 != nil }), !numbers.isEmpty { return .signedIntegers(numbers.compactMap { $0 }) }
                }
            case .unsignedIntegers(let values):
                let numbers = values.compactMap { Int(exactly: $0) }
                if numbers.count == values.count { return numbers.isEmpty ? .empty : .signedIntegers(numbers) }
            case .signedIntegers(let values) where values.isEmpty: return .empty
            default: break
            }
        }
        if floatVRs.contains(vr) {
            switch value {
            case .strings(let values):
                let numbers = values.map { Double($0.trimmingCharacters(in: .whitespaces)) }
                if numbers.allSatisfy({ $0 != nil }), !numbers.isEmpty { return .floats(numbers.compactMap { $0 }) }
            case .signedIntegers(let values): return values.isEmpty ? .empty : .floats(values.map { Double($0) })
            case .unsignedIntegers(let values): return values.isEmpty ? .empty : .floats(values.map { Double($0) })
            default: break
            }
        }
        switch value {
        case .strings(let values):
            let trimmed = values.map { vr == .UI ? $0.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) : String($0.reversed().drop(while: { $0 == " " }).reversed()) }
            return trimmed.allSatisfy(\.isEmpty) ? .empty : .strings(trimmed)
        case .sequence(let items) where items.isEmpty: return .empty
        case .bytes(let data) where data.isEmpty: return .empty
        case .signedIntegers(let values) where values.isEmpty: return .empty
        case .unsignedIntegers(let values) where values.isEmpty: return .empty
        case .floats(let values) where values.isEmpty: return .empty
        default: return value
        }
    }
}
