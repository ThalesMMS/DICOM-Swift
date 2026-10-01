import Foundation

public struct DicomCompletenessRule: Sendable {
    public enum Matching: Sendable { case all, any }
    public let quietPeriod: TimeInterval?
    public let expectedObjectCount: Int?
    public let requireExplicitEnd: Bool
    public let matching: Matching
    /// All configured conditions must hold by default. An empty rule never fires.
    public init(quietPeriod: TimeInterval? = nil, expectedObjectCount: Int? = nil,
                requireExplicitEnd: Bool = false, matching: Matching = .all) {
        self.quietPeriod = quietPeriod
        self.expectedObjectCount = expectedObjectCount
        self.requireExplicitEnd = requireExplicitEnd
        self.matching = matching
    }
    fileprivate func matches(count: Int, lastReceived: Date, ended: Date?, now: Date) -> Bool {
        var checks: [Bool] = []
        if let quietPeriod {
            guard quietPeriod.isFinite, quietPeriod >= 0 else { return false }
            checks.append(now.timeIntervalSince(lastReceived) >= quietPeriod)
        }
        if let expectedObjectCount {
            guard expectedObjectCount > 0 else { return false }
            checks.append(count >= expectedObjectCount)
        }
        if requireExplicitEnd { checks.append(ended.map { $0 >= lastReceived && $0 <= now } ?? false) }
        guard !checks.isEmpty, now >= lastReceived else { return false }
        return matching == .all ? checks.allSatisfy { $0 } : checks.contains(true)
    }
}

public struct DicomCompletion: Equatable, Sendable {
    public let studyUID: String
    public let seriesUID: String?
    public let objectCount: Int
    public let generation: Int
    public let occurredAt: Date
    public var sourceRef: String { "\(seriesUID ?? studyUID)#\(generation)" }
    public func lifecycleEvent() throws -> DicomLifecycleEvent {
        try .init(kind: .complete, subject: .init(studyInstanceUID: studyUID, seriesInstanceUID: seriesUID,
                  objectCount: objectCount), sourceKind: "completeness", sourceRef: sourceRef, occurredAt: occurredAt)
    }
}

/// Hosts call observeReceived once per newly received object, not per socket or retry.
/// Counts are cumulative; each generation requires a new observation and a fresh end signal.
public actor DicomCompletenessTracker {
    private struct Key: Hashable { let study: String; let series: String? }
    private struct State {
        var count = 0
        var generation = 1
        var lastReceived: Date
        var ended: Date?
        var completed = false
    }
    private let rule: DicomCompletenessRule
    private var states: [Key: State] = [:]
    public init(rule: DicomCompletenessRule) { self.rule = rule }
    public func observeReceived(studyUID: String, seriesUID: String? = nil, at: Date = Date()) {
        guard !studyUID.isEmpty, at.timeIntervalSince1970.isFinite else { return }
        var keys = [Key(study: studyUID, series: nil)]
        if let seriesUID, !seriesUID.isEmpty { keys.append(Key(study: studyUID, series: seriesUID)) }
        for key in keys {
            var state = states[key] ?? State(lastReceived: at)
            if state.completed {
                state.generation += 1
                state.completed = false
            }
            state.count += 1
            state.lastReceived = max(state.lastReceived, at)
            state.ended = nil
            states[key] = state
        }
    }
    public func markEnd(studyUID: String, at: Date = Date()) {
        guard at.timeIntervalSince1970.isFinite else { return }
        for key in Array(states.keys) where key.study == studyUID { states[key]?.ended = at }
    }
    public func dueCompletions(now: Date = Date()) -> [DicomCompletion] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        var result: [DicomCompletion] = []
        for key in Array(states.keys) {
            guard var state = states[key], !state.completed,
                  rule.matches(count: state.count, lastReceived: state.lastReceived, ended: state.ended, now: now) else { continue }
            state.completed = true
            states[key] = state
            result.append(.init(studyUID: key.study, seriesUID: key.series, objectCount: state.count,
                                generation: state.generation, occurredAt: now))
        }
        return result.sorted { ($0.studyUID, $0.seriesUID ?? "") < ($1.studyUID, $1.seriesUID ?? "") }
    }
}
