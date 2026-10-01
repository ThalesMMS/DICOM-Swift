import Foundation
import Network
import HL7v2
import DicomCore
import CryptoKit

public enum MLLPSendResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case acknowledged(HL7Message, HL7AckCode)
    case negativeAck(HL7AckCode, String?)
    case noAckExpected
    /// The message may have been processed; no durable conclusion is possible.
    case ackTimeout
    /// Uncorrelated ACKs were observed, but no matching ACK arrived before the deadline.
    case ackMismatch
    public var description: String {
        switch self {
        case .acknowledged(_, let code): "acknowledged(\(code.rawValue))"
        case .negativeAck(let code, _): "negativeAck(\(code.rawValue))"
        case .noAckExpected: "noAckExpected"
        case .ackTimeout: "ackTimeout"
        case .ackMismatch: "ackMismatch"
        }
    }
    public var debugDescription: String { description }
}

public enum MLLPClientState: Sendable { case disconnected, connecting, connected }
public struct MLLPClientDiagnostics: Sendable {
    public var lateOrDuplicateACKs = 0
    public var mismatchedACKs = 0
    public var pending = 0
    public var waitingForCapacity = 0
}

/// Cancellation-aware FIFO permits. A released permit is transferred directly to the oldest waiter.
actor MLLPPermits {
    private var used = 0
    private let maximum: Int
    private var closed = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(_ maximum: Int) { self.maximum = maximum }
    var waiting: Int { waiters.count }
    func acquire() async throws {
        try Task.checkCancellation()
        guard !closed else { throw MLLPError.cancelled }
        if used < maximum { used += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { c.resume(throwing: MLLPError.cancelled) }
                else { waiters.append((id, c)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
        if Task.isCancelled { release(); throw MLLPError.cancelled }
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume() }
        else { used = max(0, used - 1) }
    }
    func close() {
        closed = true
        for waiter in waiters { waiter.1.resume(throwing: MLLPError.cancelled) }
        waiters.removeAll()
    }
    private func cancel(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: i).1.resume(throwing: MLLPError.cancelled)
        }
    }
}

public actor MLLPClient {
    private struct Pending {
        let token: UUID
        let continuation: CheckedContinuation<MLLPSendResult, Error>
        let timer: Task<Void, Never>
        let sender: Task<Void, Never>
        let commit: Bool
        var mismatch = false
        var sent = false
    }
    private let host: String
    private let port: UInt16
    private let tls: DicomTLSConfiguration?
    private let serverName: String?
    private let limits: MLLPLimits
    private let ackPolicy: MLLPAckPolicy
    private let retry: MLLPRetryPolicy
    private let reconnect: Bool
    private var permits: MLLPPermits
    private var connection: MLLPConnection?
    private var connecting: Task<MLLPConnection, Error>?
    private var candidate: MLLPConnection?
    private var receiver: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var reservations: Set<String> = []
    private var completed: [String] = []
    private var counters = MLLPClientDiagnostics()
    private var generation = UUID()
    private var hasConnected = false
    private var currentState: MLLPClientState = .disconnected
    private var observers: [UUID: AsyncStream<MLLPClientState>.Continuation] = [:]

    public init(host: String, port: UInt16, tls: DicomTLSConfiguration? = nil, serverName: String? = nil,
                limits: MLLPLimits = .init(), ackPolicy: MLLPAckPolicy = .init(),
                retry: MLLPRetryPolicy = .init(), reconnect: Bool = true) {
        self.host = host; self.port = port; self.tls = tls; self.serverName = serverName
        self.limits = limits; self.ackPolicy = ackPolicy; self.retry = retry; self.reconnect = reconnect
        permits = MLLPPermits(limits.maxInFlight)
    }
    public var state: AsyncStream<MLLPClientState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MLLPClientState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        observers[id] = continuation; continuation.yield(currentState)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func transition(_ state: MLLPClientState) {
        currentState = state
        for observer in observers.values { observer.yield(state) }
    }
    public var diagnostics: MLLPClientDiagnostics {
        get async {
            var result = counters; result.pending = pending.count
            result.waitingForCapacity = await permits.waiting
            return result
        }
    }

    public func send(_ message: HL7Message, timeout: TimeInterval = 30,
                     resendPolicy: MLLPResendPolicy = .never, maxAttempts: Int? = nil) async throws -> MLLPSendResult {
        guard limits.isValid, retry.isValid, port != 0, timeout.isFinite, timeout > 0,
              let id = message.controlID, !id.isEmpty else { throw MLLPError.invalidConfiguration }
        let activePermits = permits
        let epoch = generation
        try await activePermits.acquire()
        do {
            guard epoch == generation else { throw MLLPError.cancelled }
            guard !reservations.contains(id), pending[id] == nil, !completed.contains(Self.hash(id)) else { throw MLLPError.duplicateControlID }
            reservations.insert(id)
            defer { reservations.remove(id) }
            let wire: Data
            do { wire = try MLLPFramer.frame(HL7Serializer().serialize(message)) }
            catch { throw MLLPError.invalidMessage }
            guard wire.count <= limits.maxMessageBytes + 3 else { throw MLLPError.invalidMessage }
            let policy = ackPolicy.resolved(for: message)
            var result: MLLPSendResult = .ackTimeout
            let attempts = resendPolicy == .idempotent ? max(1, maxAttempts ?? retry.attempts) : 1
            for attempt in 0..<attempts {
                try Task.checkCancellation()
                let transport = try await connected()
                guard epoch == generation else { throw MLLPError.cancelled }
                if policy.mode == .never {
                    try await transport.send(frame: wire)
                    result = .noAckExpected
                } else {
                    result = try await awaitACK(id: id, wire: wire, transport: transport,
                                               timeout: timeout, commit: policy.commitAck && policy.mode != .original)
                }
                if case .ackTimeout = result, attempt + 1 < attempts {
                    try await mllpSleep(retry.delay(at: attempt))
                } else { break }
            }
            remember(id)
            await activePermits.release()
            return result
        } catch {
            await activePermits.release()
            throw error
        }
    }

    private func connected() async throws -> MLLPConnection {
        if let connection, !(await connection.isClosed) { return connection }
        if let connecting {
            return try await withTaskCancellationHandler { try await connecting.value }
                onCancel: { Task { await self.disconnect() } }
        }
        if hasConnected && !reconnect { throw MLLPError.connectionClosed }
        let epoch = generation
        transition(.connecting)
        let task = Task { try await self.establish(epoch: epoch) }
        connecting = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value }
                onCancel: { Task { await self.disconnect() } }
            guard epoch == generation else { await result.cancel(); throw MLLPError.cancelled }
            connecting = nil; connection = result; hasConnected = true
            transition(.connected)
            receiver = Task { [weak self] in
                while let frame = await result.next() {
                    await self?.receive(frame, epoch: epoch)
                    await result.consumed()
                }
                await result.cancel()
                await self?.lost(result, epoch: epoch)
            }
            return result
        } catch {
            if epoch == generation { connecting = nil; transition(.disconnected) }
            throw MLLPError.connectionFailed
        }
    }
    private func establish(epoch: UUID) async throws -> MLLPConnection {
        for attempt in 0..<retry.attempts {
            try Task.checkCancellation()
            guard epoch == generation else { throw MLLPError.cancelled }
            let parameters: NWParameters
            do { parameters = try tls.map { try DicomTLSNetworkParameters.client($0, serverName: serverName) } ?? .tcp }
            catch { throw MLLPError.invalidConfiguration }
            let transport = MLLPConnection(connection: NWConnection(host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!, using: parameters), limits: limits)
            candidate = transport
            do { try await transport.start(); candidate = nil; return transport }
            catch {
                await transport.cancel(); candidate = nil
                if attempt + 1 == retry.attempts { throw MLLPError.connectionFailed }
                try await mllpSleep(retry.delay(at: attempt))
            }
        }
        throw MLLPError.connectionFailed
    }
    private func awaitACK(id: String, wire: Data, transport: MLLPConnection,
                          timeout: TimeInterval, commit: Bool) async throws -> MLLPSendResult {
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: MLLPError.cancelled); return }
                let timer = Task {
                    do { try await mllpSleep(timeout) } catch { return }
                    self.expire(id, token: token)
                }
                let sender = Task {
                    do {
                        try await transport.send(frame: wire)
                        if self.pending[id]?.token == token { self.pending[id]?.sent = true }
                    }
                    catch { self.expire(id, token: token) }
                }
                pending[id] = Pending(token: token, continuation: continuation, timer: timer, sender: sender, commit: commit)
            }
        } onCancel: { Task { await self.cancelPending(id, token: token) } }
    }
    private func receive(_ frame: MLLPFrame, epoch: UUID) {
        guard epoch == generation, let ack = try? frame.decodeHL7(), ack.messageType.code == "ACK",
              let id = ack["MSA"]?[2][1][1][1].text,
              let raw = ack["MSA"]?[1][1][1][1].text, let code = HL7AckCode(rawValue: raw) else { return }
        guard let request = pending[id] else {
            if completed.contains(Self.hash(id)) { counters.lateOrDuplicateACKs += 1 }
            else {
                counters.mismatchedACKs += 1
                for key in pending.keys { pending[key]?.mismatch = true }
            }
            return
        }
        guard request.commit == code.isCommit else { counters.mismatchedACKs += 1; return }
        finish(id, result: code.isSuccess ? .acknowledged(ack, code) : .negativeAck(code, ack["MSA"]?[3][1][1][1].text))
    }
    private func expire(_ id: String, token: UUID) {
        guard let request = pending[id], request.token == token else { return }
        finish(id, result: request.mismatch ? .ackMismatch : .ackTimeout)
    }
    private func finish(_ id: String, result: MLLPSendResult) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel()
        if !request.sent { request.sender.cancel() }
        remember(id)
        request.continuation.resume(returning: result)
    }
    private func cancelPending(_ id: String, token: UUID) {
        guard let request = pending[id], request.token == token else { return }
        pending.removeValue(forKey: id); request.timer.cancel(); request.sender.cancel(); remember(id)
        request.continuation.resume(throwing: MLLPError.cancelled)
    }
    private func lost(_ transport: MLLPConnection, epoch: UUID) {
        guard epoch == generation, connection === transport else { return }
        connection = nil; receiver = nil; transition(.disconnected)
        for id in Array(pending.keys) { finish(id, result: .ackTimeout) }
    }
    private static func hash(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func remember(_ id: String) {
        let hash = Self.hash(id)
        if !completed.contains(hash) { completed.append(hash) }
        if completed.count > max(64, limits.maxInFlight * 4) { completed.removeFirst() }
    }
    public func disconnect() async {
        generation = UUID(); connecting?.cancel(); connecting = nil
        let old = connection; connection = nil
        let attempt = candidate; candidate = nil
        receiver?.cancel(); receiver = nil
        for (id, request) in pending {
            request.timer.cancel(); request.sender.cancel(); remember(id)
            request.continuation.resume(throwing: MLLPError.cancelled)
        }
        pending.removeAll()
        await permits.close(); permits = MLLPPermits(limits.maxInFlight)
        await old?.cancel(); await attempt?.cancel()
        transition(.disconnected)
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }
}
