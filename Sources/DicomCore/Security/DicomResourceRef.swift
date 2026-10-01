import Foundation

public struct DicomResourceRef: Codable, Equatable, Hashable, Sendable {
    public indirect enum Box: Codable, Equatable, Hashable, Sendable { case value(DicomResourceRef) }
    public enum Kind: String, Codable, Sendable {
        case patient, study, series, instance, representation, derivative, workitem, subscription
        case configuration, auditTrail, archive
    }
    public let kind: Kind
    public let id: String
    public let parent: Box?
    public init(kind: Kind, id: String, parent: DicomResourceRef? = nil) {
        self.kind = kind; self.id = id; self.parent = parent.map(Box.value)
    }
    /// Immediate parent first, ending at the root. Does not include self.
    public var ancestry: [DicomResourceRef] {
        guard case .value(let parent) = parent else { return [] }
        return [parent] + parent.ancestry
    }
    /// An unresolved derived resource returns itself; authorizers must deny that case.
    public var sourceObject: DicomResourceRef {
        guard kind == .representation || kind == .derivative else { return self }
        return ancestry.first { $0.kind == .instance || $0.kind == .study } ?? self
    }
}
