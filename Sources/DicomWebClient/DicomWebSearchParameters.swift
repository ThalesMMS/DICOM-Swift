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

    public func queryItems() throws -> [URLQueryItem] {
        _ = try pathComponents()
        guard !includeFields.contains("all") || includeFields == ["all"],
              Set(matches.map(\.attribute)).count == matches.count else { throw DicomWebError(kind: .badRequest) }
        var items: [URLQueryItem] = []
        for match in matches {
            guard !match.attribute.isEmpty, !["limit", "offset", "includefield", "fuzzymatching"].contains(match.attribute),
                  !match.values.isEmpty, match.vr == .UI || match.values.count == 1,
                  match.values.allSatisfy({ !$0.utf8.contains(13) && !$0.utf8.contains(10) }) else {
                throw DicomWebError(kind: .badRequest)
            }
            items.append(.init(name: match.attribute, value: match.values.joined(separator: ",")))
        }
        if let fuzzyMatching { items.append(.init(name: "fuzzymatching", value: String(fuzzyMatching))) }
        if !includeFields.isEmpty { items.append(.init(name: "includefield", value: includeFields.joined(separator: ","))) }
        if let limit { items.append(.init(name: "limit", value: String(limit))) }
        if let offset { items.append(.init(name: "offset", value: String(offset))) }
        return items
    }

    public func url(relativeTo base: URL) throws -> URL {
        var url = base
        for part in try pathComponents() { url.appendPathComponent(part) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DicomWebError(kind: .badRequest)
        }
        // ASCII only (#2888): `.alphanumerics` is the Unicode set and would leave letters such as "é" unencoded,
        // which URLComponents refuses as a percent-encoded query. "*" stays literal for wildcards; "," is encoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~*")
        components.percentEncodedQuery = try queryItems().map {
            ($0.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" +
            (($0.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
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
