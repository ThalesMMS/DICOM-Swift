public protocol DicomRoutingDestinationResolving: Sendable {
    func destination(id: String) -> DicomRoutingDestination?
}

public struct DicomRoutingDestination: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case dimseStore, stowRS, webhook }
    public let id: String
    public let kind: Kind
    public let displayName: String
    public let enabled: Bool
    public let acceptsLossy: Bool
    public let acceptedTransferSyntaxUIDs: [String]?

    public init(id: String, kind: Kind, displayName: String, enabled: Bool = true,
                acceptsLossy: Bool, acceptedTransferSyntaxUIDs: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.enabled = enabled
        self.acceptsLossy = acceptsLossy
        self.acceptedTransferSyntaxUIDs = acceptedTransferSyntaxUIDs
    }
}

public struct DicomRoutingDestinationCatalog: DicomRoutingDestinationResolving {
    private let destinations: [String: DicomRoutingDestination]

    /// For repeated configured IDs, the last configuration wins.
    public init(destinations: [DicomRoutingDestination]) {
        self.destinations = Dictionary(destinations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func destination(id: String) -> DicomRoutingDestination? { destinations[id] }
}
