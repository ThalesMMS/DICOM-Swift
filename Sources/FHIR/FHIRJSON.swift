import Foundation

/// Limits applied to every parse (JSON or XML) and to Bundle handling.
public struct FHIRLimits: Equatable, Sendable {
    public var maxBytes: Int = 64 * 1024 * 1024
    public var maxDepth: Int = 128
    public var maxNodes: Int = 2_000_000
    public var maxStringBytes: Int = 16 * 1024 * 1024
    public var maxBundleEntries: Int = 10_000
    public init() {}
}

public enum FHIRJSONError: Error, Equatable, Sendable {
    case byteLimit
    case depthLimit
    case nodeLimit
    case stringLimit
    case bundleEntryLimit
    case invalidUTF8
    /// Byte offset of the syntax error; never the offending content.
    case syntax(offset: Int)
    case duplicateKey(String)
    case notAnObject
    case notAResource
}

/// A JSON number kept in its lexical form so decimals round-trip with their precision.
public struct FHIRNumber: Hashable, Sendable, CustomStringConvertible {
    public let lexical: String

    public init(lexical: String) { self.lexical = lexical }
    public init(_ value: Int) { lexical = String(value) }
    public init(_ value: Decimal) { lexical = "\(value)" }

    public var decimalValue: Decimal? { Decimal(string: lexical, locale: nil) }
    public var intValue: Int? { Int(lexical) }
    public var isInteger: Bool { !lexical.contains(".") && !lexical.lowercased().contains("e") }
    public var description: String { lexical }

    public static func isValidLexical(_ text: String) -> Bool {
        text.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil
    }
}

/// Insertion-ordered JSON object; FHIR forbids duplicate keys and order is preserved for byte-stable output.
public struct FHIRJSONObject: Equatable, Sendable {
    public private(set) var keys: [String] = []
    private var storage: [String: FHIRJSON] = [:]

    public init() {}
    public init(_ pairs: [(String, FHIRJSON)]) {
        for (key, value) in pairs { self[key] = value }
    }
    public init(_ pairs: KeyValuePairs<String, FHIRJSON>) {
        for (key, value) in pairs { self[key] = value }
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    public subscript(key: String) -> FHIRJSON? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var pairs: [(key: String, value: FHIRJSON)] { keys.map { ($0, storage[$0]!) } }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> FHIRJSON? {
        let removed = storage.removeValue(forKey: key)
        if removed != nil { keys.removeAll { $0 == key } }
        return removed
    }

    /// Reorders keys so that `first` come first in that order; other keys keep their relative order.
    public mutating func moveToFront(_ first: [String]) {
        var seen: Set<String> = []
        let head = first.filter { storage[$0] != nil && seen.insert($0).inserted }
        keys = head + keys.filter { !head.contains($0) }
    }
}

/// Lossless JSON value tree: numbers keep their lexical form, objects keep key order.
public indirect enum FHIRJSON: Equatable, Sendable {
    case object(FHIRJSONObject)
    case array([FHIRJSON])
    case string(String)
    case number(FHIRNumber)
    case bool(Bool)
    case null

    public var object: FHIRJSONObject? { if case .object(let value) = self { return value } else { return nil } }
    public var array: [FHIRJSON]? { if case .array(let value) = self { return value } else { return nil } }
    public var string: String? { if case .string(let value) = self { return value } else { return nil } }
    public var number: FHIRNumber? { if case .number(let value) = self { return value } else { return nil } }
    public var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public subscript(key: String) -> FHIRJSON? { object?[key] }
    public subscript(index: Int) -> FHIRJSON? {
        guard let array, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Counts every value node in the tree (used for limits and diagnostics).
    public var nodeCount: Int {
        switch self {
        case .object(let object): return 1 + object.pairs.reduce(0) { $0 + $1.value.nodeCount }
        case .array(let items): return 1 + items.reduce(0) { $0 + $1.nodeCount }
        default: return 1
        }
    }
}

extension FHIRJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(FHIRNumber(value)) }
    public init(arrayLiteral elements: FHIRJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, FHIRJSON)...) { self = .object(FHIRJSONObject(elements)) }
}
