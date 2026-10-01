import Foundation

/// A node is either a segment reference or an ordered group. nil maximum means unbounded.
public struct HL7StructureNode: Codable, Equatable, Sendable {
    public var name: String
    public var segment: String?
    public var children: [HL7StructureNode]
    public var min: Int
    public var max: Int?
    public init(segment: String, min: Int = 0, max: Int? = 1) {
        self.name = segment; self.segment = segment; self.children = []; self.min = min; self.max = max
    }
    public init(group: String, children: [Self], min: Int = 0, max: Int? = 1) {
        self.name = group; self.segment = nil; self.children = children; self.min = min; self.max = max
    }
}

public struct HL7MessageStructure: Codable, Equatable, Sendable {
    public var id: String
    public var children: [HL7StructureNode]
    public init(id: String, children: [HL7StructureNode]) { self.id = id; self.children = children }
}

public struct HL7SchemaVersion: Sendable {
    public let version: HL7Version
    public var segments: [String: HL7SegmentDefinition]
    public var structures: [String: HL7MessageStructure]
    public var messageTypeToStructure: [String: String]
    public var valueSets: [String: Set<String>]
    public var dataTypes: [HL7DataTypeName: HL7DataTypeDefinition]
    public var diagnostics: [HL7ValidationFinding] = []
}

public struct HL7SchemaRegistry: Sendable {
    public static let shared = Self()
    public let versions: [HL7Version] = [.v2_3_1, .v2_4, .v2_5, .v2_5_1, .v2_6]
    public init() {}
    /// No fallback exists below the first covered version or for an unparseable version.
    public func schema(for requested: HL7Version) -> HL7SchemaVersion? {
        guard let key = versionKey(requested.rawValue),
              let selected = versions.last(where: { versionKey($0.rawValue)! <= key }) else { return nil }
        var result = HL7Tables.schema(selected)
        if requested != selected {
            result.diagnostics.append(.init(code: .versionMismatch, path: HL7Path(segment: "MSH", field: 12),
                severity: .warning, detail: "versionMismatch nearestLowerSchema=" + selected.rawValue))
        }
        return result
    }
}

func versionKey(_ value: String) -> Int? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...3).contains(parts.count), parts.allSatisfy({ Int($0).map { (0...99).contains($0) } == true })
    else { return nil }
    return Int(parts[0])! * 10_000 + Int(parts[1])! * 100 + (parts.count == 3 ? Int(parts[2])! : 0)
}
