import Foundation

public enum DicomDerivativeRepairPlanner {
    public struct Record: Sendable {
        public let path: URL
        public let sourceSOPUID: String
        public let sourceSHA256: String?
        public let isUsable: Bool
        public init(path: URL, sourceSOPUID: String, sourceSHA256: String?, isUsable: Bool) {
            self.path = path; self.sourceSOPUID = sourceSOPUID; self.sourceSHA256 = sourceSHA256; self.isUsable = isUsable
        }
    }
    public enum Action: String, Sendable { case regenerate, invalidate }
    public struct Plan: Sendable { public let path: URL; public let action: Action }
    /// Only verified original hashes belong in currentSources. Originals are never mutated by this plan.
    public static func plan(derivatives: [Record], currentSources: [String: String]) -> [Plan] {
        derivatives.compactMap { record in
            guard let current = currentSources[record.sourceSOPUID], !current.isEmpty else {
                return .init(path: record.path, action: .invalidate)
            }
            if !record.isUsable || record.sourceSHA256 != current { return .init(path: record.path, action: .regenerate) }
            return nil
        }
    }
}
