import Foundation
import Network
import Security
import CryptoKit

public struct MLLPConnectionMetrics: Sendable {
    public var bytesIn = 0
    public var bytesOut = 0
    public var frames = 0
    public var pending = 0
    public var drops = 0
    public var bufferedBytes = 0
    public var peakBufferedBytes = 0
    public var activeTasks = 0
    public var closed = false
}

public actor MLLPConnection {
    private let network: NWConnection
    private let limits: MLLPLimits
    private let accumulator: MLLPAccumulator
    private let queue = DispatchQueue(label: "HL7MLLP.connection")
    private var ready = false
    private var closed = false
    private var started = false
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var sends: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var readWaiter: CheckedContinuation<(Data, Bool), Error>?
    private var consumptionRevision = 0
    private var capacityWaiter: CheckedContinuation<Void, Never>?
    private var reader: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var counters = MLLPConnectionMetrics()

    public init(connection: NWConnection, limits: MLLPLimits = .init()) {
        network = connection; self.limits = limits; accumulator = MLLPAccumulator(limits: limits)
    }
    public var peer: MLLPPeer {
        if case .hostPort(let host, let port) = network.endpoint {
            return .init(address: String(describing: host), port: port.rawValue)
        }
        return .init(address: "unknown", port: 0)
    }
    public var tlsPeerIdentity: String? {
        guard ready, let metadata = network.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return nil }
        var fingerprint: String?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if fingerprint == nil {
                let certificate = sec_certificate_copy_ref(certificate).takeRetainedValue()
                fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
                    .map { String(format: "%02x", $0) }.joined()
            }
        }
        return fingerprint
    }
    public var isClosed: Bool { closed }
    public var metrics: MLLPConnectionMetrics {
        get async {
            let stats = await accumulator.stats
            var result = counters
            result.frames = stats.frames; result.pending = stats.pending
            result.drops = stats.dropped; result.bufferedBytes = stats.bufferedBytes
            result.peakBufferedBytes = await accumulator.peakBufferedBytes
            result.activeTasks = (reader == nil ? 0 : 1) + (deadline == nil ? 0 : 1)
            result.closed = closed
            return result
        }
    }

    public func start() async throws {
        guard limits.isValid else { throw MLLPError.invalidConfiguration }
        guard !closed else { throw MLLPError.connectionClosed }
        if ready { return }
        if !started {
            started = true
            lastActivity = .now
            network.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
            network.start(queue: queue)
            deadline = Task { [weak self, limits] in
                let beginning = ContinuousClock.now
                while !Task.isCancelled {
                    do { try await mllpSleep(min(0.1, max(0.01, limits.idleTimeout / 2))) } catch { return }
                    guard let self else { return }
                    if await self.expired(beginning: beginning) { await self.cancel(); return }
                }
            }
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { waiter.resume(throwing: MLLPError.cancelled) }
                else if closed { waiter.resume(throwing: MLLPError.connectionClosed) }
                else if ready { waiter.resume() }
                else { readyWaiters[id] = waiter }
            }
        } onCancel: { Task { await self.cancel() } }
    }

    private func expired(beginning: ContinuousClock.Instant) -> Bool {
        beginning.duration(to: .now) >= .seconds(limits.connectionLifetime)
            || lastActivity.duration(to: .now) >= .seconds(limits.idleTimeout)
    }
    private func stateChanged(_ state: NWConnection.State) async {
        guard !closed else { return }
        switch state {
        case .ready:
            ready = true
            let waiters = readyWaiters.values; readyWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if reader == nil { reader = Task { await self.readLoop() } }
        case .failed, .cancelled: await cancel()
        default: break
        }
    }

    /// Input is already MLLP-framed. Completion means the transport processed the content, not a peer ACK.
    public func send(frame: Data) async throws {
        try Task.checkCancellation()
        guard ready && !closed else { throw MLLPError.connectionClosed }
        guard frame.count <= limits.maxMessageBytes + 3 else { throw MLLPError.invalidMessage }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                sends[id] = waiter
                network.send(content: frame, completion: .contentProcessed { [weak self] error in
                    Task { await self?.sent(id, bytes: frame.count, failed: error != nil) }
                })
            }
        } onCancel: { Task { await self.cancel() } }
    }
    private func sent(_ id: UUID, bytes: Int, failed: Bool) {
        guard let waiter = sends.removeValue(forKey: id) else { return }
        if failed { waiter.resume(throwing: MLLPError.connectionFailed) }
        else { counters.bytesOut += bytes; lastActivity = .now; waiter.resume() }
    }
    public func next() async -> MLLPFrame? { await accumulator.next() }
    public func consumed() async {
        consumptionRevision += 1
        if await accumulator.consumed() == .resumeReads {
            capacityWaiter?.resume(); capacityWaiter = nil
        }
    }
    private func read() async throws -> (Data, Bool) {
        guard !closed else { throw MLLPError.connectionClosed }
        return try await withCheckedThrowingContinuation { waiter in
            readWaiter = waiter
            network.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, end, error in
                Task { await self?.received(data ?? Data(), end: end, failed: error != nil) }
            }
        }
    }
    private func received(_ data: Data, end: Bool, failed: Bool) {
        guard let waiter = readWaiter else { return }
        readWaiter = nil
        if failed { waiter.resume(throwing: MLLPError.connectionFailed) }
        else {
            if !data.isEmpty { counters.bytesIn += data.count; lastActivity = .now }
            waiter.resume(returning: (data, end))
        }
    }
    private func readLoop() async {
        do {
            while !closed && !Task.isCancelled {
                let (chunk, end) = try await read()
                try await admit(chunk)
                if end {
                    await shutdown(discardPending: false)
                    reader = nil
                    return
                }
            }
        } catch { }
        await cancel()
    }
    private func admit(_ data: Data) async throws {
        guard !closed else { throw MLLPError.connectionClosed }
        do {
            let outcome = try await accumulator.feed(data)
            if outcome == .pauseReads {
                while !closed {
                    let revision = consumptionRevision
                    let stats = await accumulator.stats
                    if revision != consumptionRevision { continue }
                    if stats.pending < limits.maxPendingFrames && stats.bufferedBytes < limits.maxBufferedBytes { break }
                    if stats.pending == 0 { throw MLLPError.invalidMessage }
                    await withCheckedContinuation { capacityWaiter = $0 }
                }
            }
        } catch let error as MLLPFramingError
            where (error.reason == .pendingFramesLimit || error.reason == .bufferLimit) && data.count > 1 {
            let middle = data.count / 2
            try await admit(Data(data.prefix(middle)))
            try await admit(Data(data.dropFirst(middle)))
        }
    }

    public func cancel() async { await shutdown(discardPending: true) }

    private func shutdown(discardPending: Bool) async {
        guard !closed else {
            if discardPending { await accumulator.close(discardPending: true) }
            return
        }
        closed = true; ready = false
        network.stateUpdateHandler = nil; network.cancel()
        reader?.cancel(); reader = nil; deadline?.cancel(); deadline = nil
        for waiter in readyWaiters.values { waiter.resume(throwing: MLLPError.connectionClosed) }
        readyWaiters.removeAll()
        for waiter in sends.values { waiter.resume(throwing: MLLPError.connectionClosed) }
        sends.removeAll()
        readWaiter?.resume(throwing: MLLPError.connectionClosed); readWaiter = nil
        capacityWaiter?.resume(); capacityWaiter = nil
        await accumulator.close(discardPending: discardPending)
    }
}
