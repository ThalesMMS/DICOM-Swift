import Foundation
import DicomData

public struct DicomWebSearchParameters: Equatable, Sendable {
    public enum Level: String, Sendable { case study, series, instance }
    public struct Match: Equatable, Sendable {
        public let attribute: String
        public let vr: DicomVR
        public let values: [String]
        public init(_ attribute: String, vr: DicomVR, values: [String]) {
            self.attribute = attribute
            self.vr = vr
            self.values = values
        }
    }
    public var level: Level
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var matches: [Match]
    public var fuzzyMatching: Bool?
    public var includeFields: [String]
    public var limit: Int?
    public var offset: Int?

    public init(level: Level = .study, studyInstanceUID: String? = nil, seriesInstanceUID: String? = nil,
                matches: [Match] = [], fuzzyMatching: Bool? = nil, includeFields: [String] = ["all"],
                limit: Int? = nil, offset: Int? = nil) {
        self.level = level
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.matches = matches
        self.fuzzyMatching = fuzzyMatching
        self.includeFields = includeFields
        self.limit = limit
        self.offset = offset
    }

    public func pathComponents() throws -> [String] {
        guard limit.map({ $0 >= 0 }) ?? true, offset.map({ $0 >= 0 }) ?? true,
              seriesInstanceUID == nil || (studyInstanceUID != nil && level == .instance),
              level != .study || studyInstanceUID == nil else { throw DicomWebError(kind: .badRequest) }
        var path: [String] = []
        if let studyInstanceUID { path += ["studies", studyInstanceUID] }
        if let seriesInstanceUID { path += ["series", seriesInstanceUID] }
        path += [level == .study ? "studies" : level == .series ? "series" : "instances"]
        return path
    }

    /// Each value list is joined with ",", the QIDO-RS separator between the values of one key.
    public func queryItems() throws -> [URLQueryItem] {
        try queryValueLists().map { URLQueryItem(name: $0.name, value: $0.values.joined(separator: ",")) }
    }

    /// The query keys in request order, each with its list of values. A key with several values (a UID list, or
    /// multiple value matching for any other VR) is matched against any of them.
    private func queryValueLists() throws -> [(name: String, values: [String])] {
        _ = try pathComponents()
        guard !includeFields.contains("all") || includeFields == ["all"],
              Set(matches.map(\.attribute)).count == matches.count else { throw DicomWebError(kind: .badRequest) }
        var lists: [(name: String, values: [String])] = []
        for match in matches {
            guard !match.attribute.isEmpty, !["limit", "offset", "includefield", "fuzzymatching"].contains(match.attribute),
                  !match.values.isEmpty, match.values.count == 1 || !match.values.contains(""),
                  match.values.allSatisfy({ !$0.utf8.contains(13) && !$0.utf8.contains(10) }) else {
                throw DicomWebError(kind: .badRequest)
            }
            lists.append((match.attribute, match.values))
        }
        if let fuzzyMatching { lists.append(("fuzzymatching", [String(fuzzyMatching)])) }
        if !includeFields.isEmpty { lists.append(("includefield", includeFields)) }
        if let limit { lists.append(("limit", [String(limit)])) }
        if let offset { lists.append(("offset", [String(offset)])) }
        return lists
    }

    public func url(relativeTo base: URL) throws -> URL {
        var url = base
        for part in try pathComponents() { url.appendPathComponent(part) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DicomWebError(kind: .badRequest)
        }
        // ASCII only (#2888): `.alphanumerics` is the Unicode set and would leave letters such as "é" unencoded,
        // which URLComponents refuses as a percent-encoded query. "*" stays literal for wildcards. The "," between
        // values stays literal: servers such as dcm4chee read "%2C" as data, so "CT%2CMR" would be one value. A
        // "," inside a value has no QIDO-RS representation and is encoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~*")
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        components.percentEncodedQuery = try queryValueLists().map {
            encoded($0.name) + "=" + $0.values.map(encoded).joined(separator: ",")
        }.joined(separator: "&")
        guard let result = components.url else { throw DicomWebError(kind: .badRequest) }
        return result
    }

    /// The server supplies dictionary VR lookup for keyword, numeric and private matching keys.
    public static func parse(queryItems: [URLQueryItem], level: Level = .study,
                             studyInstanceUID: String? = nil, seriesInstanceUID: String? = nil,
                             vrForAttribute: (String) -> DicomVR?) throws -> Self {
        var result = Self(level: level, studyInstanceUID: studyInstanceUID, seriesInstanceUID: seriesInstanceUID,
                          includeFields: [])
        var seen: Set<String> = []
        for item in queryItems {
            guard let value = item.value,
                  item.name == "includefield" || seen.insert(item.name).inserted else { throw DicomWebError(kind: .badRequest) }
            switch item.name {
            case "limit", "offset":
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(value) else {
                    throw DicomWebError(kind: .badRequest)
                }
                if item.name == "limit" { result.limit = n } else { result.offset = n }
            case "fuzzymatching":
                guard value == "true" || value == "false" else { throw DicomWebError(kind: .badRequest) }
                result.fuzzyMatching = value == "true"
            case "includefield": result.includeFields += value.components(separatedBy: ",")
            default:
                guard let vr = vrForAttribute(item.name) else { throw DicomWebError(kind: .badRequest) }
                result.matches.append(.init(item.name, vr: vr, values: vr == .UI ? value.components(separatedBy: ",") : [value]))
            }
        }
        _ = try result.queryItems()
        return result
    }
}
