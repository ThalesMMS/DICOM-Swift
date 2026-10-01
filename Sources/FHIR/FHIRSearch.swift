import Foundation

/// Search prefixes for number, date and quantity parameters.
public enum FHIRSearchPrefix: String, Sendable, CaseIterable {
    case eq, ne, gt, lt, ge, le, sa, eb, ap
}

/// Modifiers appended to a parameter name (`name:exact`).
public enum FHIRSearchModifier: Equatable, Sendable {
    case exact, contains, missing, not, text, `in`, notIn, below, above, identifier, ofType
    case type(String)

    var suffix: String {
        switch self {
        case .exact: return ":exact"
        case .contains: return ":contains"
        case .missing: return ":missing"
        case .not: return ":not"
        case .text: return ":text"
        case .in: return ":in"
        case .notIn: return ":not-in"
        case .below: return ":below"
        case .above: return ":above"
        case .identifier: return ":identifier"
        case .ofType: return ":of-type"
        case .type(let name): return ":" + name
        }
    }
}

/// One typed search parameter value; composite OR values are joined with `,`.
public struct FHIRSearchParameter: Equatable, Sendable {
    public var name: String
    public var modifier: FHIRSearchModifier?
    public var values: [String]

    public init(name: String, modifier: FHIRSearchModifier? = nil, values: [String]) {
        self.name = name
        self.modifier = modifier
        self.values = values
    }

    public var key: String { name + (modifier?.suffix ?? "") }
    /// Values are stored already escaped (`\`, `,`, `|`, `$` inside text parts carry a backslash); OR values join with `,`.
    public var encodedValue: String { values.joined(separator: ",") }

    public static func token(_ name: String, system: String? = nil, code: String, modifier: FHIRSearchModifier? = nil) -> FHIRSearchParameter {
        .init(name: name, modifier: modifier, values: [system.map { FHIRSearchQuery.escape($0) + "|" + FHIRSearchQuery.escape(code) } ?? FHIRSearchQuery.escape(code)])
    }
    public static func string(_ name: String, _ value: String, modifier: FHIRSearchModifier? = nil) -> FHIRSearchParameter {
        .init(name: name, modifier: modifier, values: [FHIRSearchQuery.escape(value)])
    }
    public static func reference(_ name: String, _ reference: String) -> FHIRSearchParameter {
        .init(name: name, values: [FHIRSearchQuery.escape(reference)])
    }
    public static func date(_ name: String, _ prefix: FHIRSearchPrefix? = nil, _ value: String) -> FHIRSearchParameter {
        .init(name: name, values: [(prefix?.rawValue ?? "") + FHIRSearchQuery.escape(value)])
    }
    public static func number(_ name: String, _ prefix: FHIRSearchPrefix? = nil, _ value: String) -> FHIRSearchParameter {
        .init(name: name, values: [(prefix?.rawValue ?? "") + FHIRSearchQuery.escape(value)])
    }
    public static func quantity(_ name: String, _ prefix: FHIRSearchPrefix? = nil, _ value: String, system: String? = nil, code: String? = nil) -> FHIRSearchParameter {
        var text = (prefix?.rawValue ?? "") + FHIRSearchQuery.escape(value)
        if system != nil || code != nil { text += "|" + FHIRSearchQuery.escape(system ?? "") + "|" + FHIRSearchQuery.escape(code ?? "") }
        return .init(name: name, values: [text])
    }
    /// Chained parameter: `subject:Patient.name=...` or `subject.name=...`.
    public static func chained(_ name: String, targetType: String? = nil, _ chain: String, _ value: String) -> FHIRSearchParameter {
        .init(name: name + (targetType.map { ":" + $0 } ?? "") + "." + chain, values: [FHIRSearchQuery.escape(value)])
    }
    /// Reverse chaining: `_has:Observation:patient:code=...`.
    public static func has(_ resourceType: String, _ referenceParameter: String, _ parameter: String, _ value: String) -> FHIRSearchParameter {
        .init(name: "_has:" + resourceType + ":" + referenceParameter + ":" + parameter, values: [FHIRSearchQuery.escape(value)])
    }
}

/// Typed, deterministic search query for one resource type.
public struct FHIRSearchQuery: Equatable, Sendable {
    public var resourceType: String
    public var parameters: [FHIRSearchParameter] = []
    public var includes: [String] = []
    public var revIncludes: [String] = []
    public var sort: [String] = []
    public var count: Int?
    public var summary: String?
    public var elements: [String] = []
    public var total: String?
    public var lastUpdated: [String] = []

    public init(resourceType: String) { self.resourceType = resourceType }

    public func `where`(_ parameter: FHIRSearchParameter) -> FHIRSearchQuery {
        var copy = self
        copy.parameters.append(parameter)
        return copy
    }
    public func include(_ sourceType: String, _ parameter: String, target: String? = nil, iterate: Bool = false) -> FHIRSearchQuery {
        var copy = self
        copy.includes.append(sourceType + ":" + parameter + (target.map { ":" + $0 } ?? "") + (iterate ? ":iterate" : ""))
        return copy
    }
    public func revInclude(_ sourceType: String, _ parameter: String, target: String? = nil) -> FHIRSearchQuery {
        var copy = self
        copy.revIncludes.append(sourceType + ":" + parameter + (target.map { ":" + $0 } ?? ""))
        return copy
    }
    public func sorted(by fields: String...) -> FHIRSearchQuery { var copy = self; copy.sort = fields; return copy }
    public func count(_ value: Int) -> FHIRSearchQuery { var copy = self; copy.count = value; return copy }
    public func summary(_ value: String) -> FHIRSearchQuery { var copy = self; copy.summary = value; return copy }
    public func elements(_ names: [String]) -> FHIRSearchQuery { var copy = self; copy.elements = names; return copy }
    public func total(_ mode: String) -> FHIRSearchQuery { var copy = self; copy.total = mode; return copy }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "$", with: "\\$")
    }

    /// Query items in insertion order (`_include`, `_sort`... after parameters).
    public var queryItems: [URLQueryItem] {
        var items = parameters.map { URLQueryItem(name: $0.key, value: $0.encodedValue) }
        items += includes.map { URLQueryItem(name: "_include", value: $0) }
        items += revIncludes.map { URLQueryItem(name: "_revinclude", value: $0) }
        if !sort.isEmpty { items.append(URLQueryItem(name: "_sort", value: sort.joined(separator: ","))) }
        if let count { items.append(URLQueryItem(name: "_count", value: String(count))) }
        if let summary { items.append(URLQueryItem(name: "_summary", value: summary)) }
        if !elements.isEmpty { items.append(URLQueryItem(name: "_elements", value: elements.joined(separator: ","))) }
        if let total { items.append(URLQueryItem(name: "_total", value: total)) }
        items += lastUpdated.map { URLQueryItem(name: "_lastUpdated", value: $0) }
        return items
    }

    /// `Type?a=b&c=d` with RFC 3986 percent-encoding of the query component.
    public var queryString: String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = queryItems.map { item -> String in
            let name = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
            let value = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return name + "=" + value
        }
        return encoded.joined(separator: "&")
    }

    public func url(baseURL: URL) -> URL {
        let path = baseURL.appendingPathComponent(resourceType)
        let query = queryString
        return query.isEmpty ? path : URL(string: path.absoluteString + "?" + query) ?? path
    }

    /// Application/x-www-form-urlencoded body for `POST [type]/_search`.
    public var formBody: Data { Data(queryString.utf8) }
}

/// A page of search results with the entries split by search mode.
public struct FHIRSearchPage: Sendable {
    public let bundle: FHIRBundle
    public let url: URL

    public init(bundle: FHIRBundle, url: URL) {
        self.bundle = bundle
        self.url = url
    }

    public var matches: [FHIRResource] { bundle.entries.filter { ($0.search?.mode ?? "match") == "match" }.compactMap(\.resource) }
    public var included: [FHIRResource] { bundle.entries.filter { $0.search?.mode == "include" }.compactMap(\.resource) }
    public var outcomes: [FHIROperationOutcome] { bundle.entries.filter { $0.search?.mode == "outcome" }.compactMap { $0.resource?.as(FHIROperationOutcome.self) } }
    public var total: Int? { bundle.total }
    public var nextURL: URL? { bundle.nextLink.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL } }
}
