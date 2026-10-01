import Foundation

/// Routing reuses the archive selector's loss policy without selecting representations itself.
public typealias DicomRepresentationPolicy = DicomRepresentationLossPolicy

public struct DicomRoutingRule: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let criteria: [DicomRoutingCriterion]
    public let destinationID: String
    public let representation: DicomRepresentationPolicy
    public let priority: DicomRoutingPriority
    public let requiresPHIAuthorization: Bool
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: String, name: String, enabled: Bool = true, criteria: [DicomRoutingCriterion],
                destinationID: String, representation: DicomRepresentationPolicy = .originalOnly,
                priority: DicomRoutingPriority = .routine, requiresPHIAuthorization: Bool = true,
                createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.criteria = criteria
        self.destinationID = destinationID
        self.representation = representation
        self.priority = priority
        self.requiresPHIAuthorization = requiresPHIAuthorization
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension DicomRepresentationLossPolicy: Codable {
    private enum CodingKeys: String, CodingKey { case kind, authorization }
    private enum Kind: String, Codable { case originalOnly, losslessEquivalents, lossyDerivedAllowed }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .originalOnly: self = .originalOnly
        case .losslessEquivalents: self = .losslessEquivalents
        case .lossyDerivedAllowed:
            self = .lossyDerivedAllowed(authorization: try container.decode(String.self, forKey: .authorization))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .originalOnly: try container.encode(Kind.originalOnly, forKey: .kind)
        case .losslessEquivalents: try container.encode(Kind.losslessEquivalents, forKey: .kind)
        case .lossyDerivedAllowed(let authorization):
            try container.encode(Kind.lossyDerivedAllowed, forKey: .kind)
            try container.encode(authorization, forKey: .authorization)
        }
    }
}
