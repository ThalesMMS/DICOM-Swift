import Foundation

public struct DicomObjectPlacement: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case available, recalling
        /// The provider reported an error/outage; the placement record still exists.
        case unreachable
        /// A reachable provider verified absence through head/list. An outage is not absence.
        case missing
    }
    public var objectKey: String
    public var tier: DicomStorageTier
    public var providerID: String
    public var locator: String
    public var byteCount: Int64
    public var sha256: String
    public var recordedAt: Date
    public private(set) var state: State

    public init(objectKey: String, tier: DicomStorageTier, providerID: String, locator: String,
                byteCount: Int64, sha256: String, recordedAt: Date = Date(), state: State = .available) {
        self.objectKey = objectKey
        self.tier = tier
        self.providerID = providerID
        self.locator = locator
        self.byteCount = byteCount
        self.sha256 = sha256
        self.recordedAt = recordedAt
        self.state = state
    }

    public func transition(to next: State, verifiedAbsent: Bool = false) throws -> Self {
        if next == .missing && next != state && (state == .unreachable || !verifiedAbsent) {
            throw DicomPlacementError.invalidTransition(from: state, to: next)
        }
        var result = self
        result.state = next
        return result
    }

    /// A new reachable observation resolves a previous outage before absence can be recorded.
    public func refreshed(using provider: any DicomStorageProvider) async throws -> Self {
        guard provider.id == providerID else { throw DicomPlacementError.unknownProvider(providerID) }
        do {
            if try await provider.head(locator) != nil { return try transition(to: .available) }
            let reachable = try transition(to: .available)
            return try reachable.transition(to: .missing, verifiedAbsent: true)
        } catch { return try transition(to: .unreachable) }
    }
}
