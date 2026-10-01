import Foundation

public enum HL7UnknownPolicy: String, Codable, Sendable { case error, warn, allow }

public struct HL7FieldOverride: Codable, Equatable, Sendable {
    public var segment: String
    public var field: Int
    public var optionality: HL7Optionality?
    public var length: Int?
    public var valueSetID: String?
    public init(segment: String, field: Int, optionality: HL7Optionality? = nil, length: Int? = nil,
                valueSetID: String? = nil) {
        self.segment = segment; self.field = field; self.optionality = optionality
        self.length = length; self.valueSetID = valueSetID
    }
}

public struct HL7ZSegmentPlacement: Codable, Equatable, Sendable {
    public var definition: HL7SegmentDefinition
    public var structure: String
    /// Insert after this segment in its containing group, preserving that group's scope.
    public var afterSegment: String
    public var min: Int
    public var max: Int?
    public init(definition: HL7SegmentDefinition, structure: String, afterSegment: String,
                min: Int = 0, max: Int? = 1) {
        self.definition = definition; self.structure = structure; self.afterSegment = afterSegment
        self.min = min; self.max = max
    }
}

public struct HL7Profile: Codable, Equatable, Sendable {
    public var id: String
    public var baseVersion: HL7Version
    public var overrides: [HL7FieldOverride]
    public var zSegments: [HL7ZSegmentPlacement]
    public var valueSets: [String: Set<String>]
    public var unknownSegmentPolicy: HL7UnknownPolicy
    public var unknownFieldPolicy: HL7UnknownPolicy
    public init(id: String, baseVersion: HL7Version, overrides: [HL7FieldOverride] = [],
                zSegments: [HL7ZSegmentPlacement] = [], valueSets: [String: Set<String>] = [:],
                unknownSegmentPolicy: HL7UnknownPolicy = .error, unknownFieldPolicy: HL7UnknownPolicy = .error) {
        self.id = id; self.baseVersion = baseVersion; self.overrides = overrides; self.zSegments = zSegments
        self.valueSets = valueSets; self.unknownSegmentPolicy = unknownSegmentPolicy
        self.unknownFieldPolicy = unknownFieldPolicy
    }
    enum CodingKeys: String, CodingKey {
        case id, baseVersion, overrides, zSegments, valueSets, unknownSegmentPolicy, unknownFieldPolicy
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
            baseVersion: HL7Version(rawValue: try c.decode(String.self, forKey: .baseVersion)),
            overrides: try c.decodeIfPresent([HL7FieldOverride].self, forKey: .overrides) ?? [],
            zSegments: try c.decodeIfPresent([HL7ZSegmentPlacement].self, forKey: .zSegments) ?? [],
            valueSets: try c.decodeIfPresent([String: Set<String>].self, forKey: .valueSets) ?? [:],
            unknownSegmentPolicy: try c.decodeIfPresent(HL7UnknownPolicy.self, forKey: .unknownSegmentPolicy) ?? .error,
            unknownFieldPolicy: try c.decodeIfPresent(HL7UnknownPolicy.self, forKey: .unknownFieldPolicy) ?? .error)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(baseVersion.rawValue, forKey: .baseVersion)
        try c.encode(overrides, forKey: .overrides); try c.encode(zSegments, forKey: .zSegments)
        try c.encode(valueSets, forKey: .valueSets); try c.encode(unknownSegmentPolicy, forKey: .unknownSegmentPolicy)
        try c.encode(unknownFieldPolicy, forKey: .unknownFieldPolicy)
    }
}

public actor HL7ProfileRegistry {
    public static let shared = HL7ProfileRegistry()
    private var profiles: [String: HL7Profile] = [:]
    public init() {}
    public func register(_ profile: HL7Profile) { profiles[profile.id] = profile }
    public func profile(id: String) -> HL7Profile? { profiles[id] }
    @discardableResult public func load(_ json: Data) throws -> HL7Profile {
        let profile = try JSONDecoder().decode(HL7Profile.self, from: json)
        register(profile)
        return profile
    }
}
