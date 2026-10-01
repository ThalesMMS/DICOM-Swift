import Foundation

public struct DicomObjectProtection: Codable, Equatable, Sendable {
    public enum PrivacyFlag: String, Codable, Sendable { case restricted, researchOnly, vip }
    public var protected: Bool
    public var retainUntil: Date?
    public var privacyFlags: Set<PrivacyFlag>
    public var legalHold: Bool
    public init(protected: Bool = false, retainUntil: Date? = nil,
                privacyFlags: Set<PrivacyFlag> = [], legalHold: Bool = false) {
        self.protected = protected; self.retainUntil = retainUntil
        self.privacyFlags = privacyFlags; self.legalHold = legalHold
    }
}

public indirect enum DicomDeletionBlocker: Codable, Equatable, Sendable {
    case protected, legalHold, retention(until: Date)
    case inheritedFrom(String, DicomDeletionBlocker)
    case invalidPlan(String)
}

public struct DicomProtectionGraph: Sendable {
    private let parents: [String: String]
    public init(parents: [String: String]) { self.parents = parents }
    func chain(_ key: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        var current: String? = key
        while let value = current, seen.insert(value).inserted {
            result.append(value); current = parents[value]
        }
        return result
    }
    public func effective(for key: String, own: [String: DicomObjectProtection], now: Date) -> DicomObjectProtection {
        var result = DicomObjectProtection()
        for ancestor in chain(key) {
            guard let value = own[ancestor] else { continue }
            result.protected = result.protected || value.protected
            result.legalHold = result.legalHold || value.legalHold
            result.privacyFlags.formUnion(value.privacyFlags)
            if let deadline = value.retainUntil { result.retainUntil = max(result.retainUntil ?? deadline, deadline) }
        }
        return result
    }
    public func deletionBlockers(for key: String, own: [String: DicomObjectProtection],
                                 now: Date) -> [DicomDeletionBlocker] {
        var result: [DicomDeletionBlocker] = []
        for ancestor in chain(key) {
            guard let value = own[ancestor] else { continue }
            var blockers: [DicomDeletionBlocker] = []
            if value.protected { blockers.append(.protected) }
            if value.legalHold { blockers.append(.legalHold) }
            if let deadline = value.retainUntil, deadline > now { blockers.append(.retention(until: deadline)) }
            result += blockers.map { ancestor == key ? $0 : .inheritedFrom(ancestor, $0) }
        }
        return result
    }
}
