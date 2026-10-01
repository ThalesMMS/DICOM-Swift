import Foundation

/// Channel metadata contains byte extents only, never copies of pixel payloads.
public actor DicomJPIPServerSessions {
    struct Lease: Sendable {
        let id: String
        let generation: UUID
        let target: String
        let tid: String
        let sent: [DicomJPIPDatabinID: Int]
        let remaining: Int
    }
    private struct Channel {
        let target: String
        let tid: String
        var generation = UUID()
        var touched: Date
        var bytes = 0
        var sent: [DicomJPIPDatabinID: Int] = [:]
    }
    private var channels: [String: Channel] = [:]
    private let maximumChannels: Int
    private let maximumBytes: Int
    private let idleTimeout: TimeInterval
    private let now: @Sendable () -> Date
    public init(maximumChannels: Int = 64, maximumBytes: Int = 256 * 1_024 * 1_024,
                idleTimeout: TimeInterval = 120, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maximumChannels = max(0, maximumChannels); self.maximumBytes = max(0, maximumBytes)
        self.idleTimeout = max(0, idleTimeout); self.now = now
    }
    private func expire() { channels = channels.filter { now().timeIntervalSince($0.value.touched) < idleTimeout } }
    func target(for id: String) throws -> String {
        expire(); guard let channel = channels[id] else { throw DicomJPIPServerError.invalidChannel }
        return channel.target
    }
    func begin(id: String?, create: Bool, target: String, tid: String) throws -> Lease? {
        expire()
        var id = id
        if create {
            guard channels.count < maximumChannels else { throw DicomJPIPServerError.limitExceeded }
            var candidate: String
            repeat { candidate = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16).description }
            while channels[candidate] != nil
            channels[candidate] = Channel(target: target, tid: tid, touched: now()); id = candidate
        }
        guard let id else { return nil }
        guard var channel = channels[id], channel.target == target, channel.tid == tid else {
            throw DicomJPIPServerError.invalidChannel
        }
        channel.generation = UUID(); channel.touched = now(); channels[id] = channel
        return .init(id: id, generation: channel.generation, target: target, tid: tid,
                     sent: channel.sent, remaining: max(0, maximumBytes - channel.bytes))
    }
    func active(_ lease: Lease) -> Bool {
        expire(); return channels[lease.id]?.generation == lease.generation
    }
    func applyModel(_ lease: Lease, known: [DicomJPIPDatabinID: Int]) {
        guard var channel = channels[lease.id], channel.generation == lease.generation else { return }
        for (id, offset) in known { channel.sent[id] = offset }
        channels[lease.id] = channel
    }
    func record(_ lease: Lease, bytes: Int, bin: DicomJPIPDatabinID?, end: Int) -> Bool {
        guard var channel = channels[lease.id], channel.generation == lease.generation,
              bytes <= maximumBytes - channel.bytes else { return false }
        channel.bytes += bytes; channel.touched = now()
        if let bin { channel.sent[bin] = max(channel.sent[bin] ?? 0, end) }
        channels[lease.id] = channel; return true
    }
    @discardableResult public func close(_ ids: [String]) -> [String] {
        expire()
        let selected = ids == ["*"] ? channels.keys.sorted() : ids
        for id in selected { channels.removeValue(forKey: id) }
        return selected
    }
    public var channelCount: Int { expire(); return channels.count }
}
