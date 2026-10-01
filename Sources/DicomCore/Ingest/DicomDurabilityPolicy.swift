import Foundation

public enum DicomDurabilityLevel: Int, Codable, Comparable, Sendable {
    case receivedInMemory, fileSynced, publishedAndRegistered, retentionConfirmed
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct DicomDurabilityPolicy: Sendable {
    public let required: DicomDurabilityLevel
    public init(required: DicomDurabilityLevel = .publishedAndRegistered) { self.required = required }
    public func validate(_ achieved: DicomDurabilityLevel) throws {
        guard achieved >= required else { throw DicomIngestError.insufficientDurability(achieved: achieved, required: required) }
    }
}
