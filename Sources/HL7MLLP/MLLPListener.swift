import Foundation
import Network
import HL7v2
import DicomCore

public struct MLLPExposureError: Error, Sendable {
    public let findings: [DicomExposureFinding]
}

public struct MLLPListenerConfiguration: Sendable {
    public var listenerID: String
    public var bindAddress: String
    public var port: UInt16
    public var tls: DicomTLSConfiguration?
    public var maxConnections: Int
    public var limits: MLLPLimits
    public var ackPolicy: MLLPAckPolicy
    public var exposure: DicomExposurePolicy
    public var rejectInvalid: Bool = true
    public var drainTimeout: TimeInterval
    public init(bindAddress: String = "127.0.0.1", port: UInt16 = 0, tls: DicomTLSConfiguration? = nil,
                maxConnections: Int = 16, limits: MLLPLimits = .init(), ackPolicy: MLLPAckPolicy = .init(),
                exposure: DicomExposurePolicy, listenerID: String = UUID().uuidString,
                drainTimeout: TimeInterval = 1) {
        self.bindAddress = bindAddress; self.port = port; self.tls = tls
        self.maxConnections = maxConnections; self.limits = limits; self.ackPolicy = ackPolicy
        self.exposure = exposure; self.listenerID = listenerID; self.drainTimeout = drainTimeout
    }
    public func validateExposure(authorizerConfigured: Bool) throws -> [DicomExposureFinding] {
        let secure = tls?.mode == .enabled
        var findings: [DicomExposureFinding]
        do { findings = try exposure.validate(bindAddress: bindAddress, tlsEnabled: secure,
                                              authenticationConfigured: authorizerConfigured) }
        catch let error as DicomExposureValidationError { findings = error.findings }
        let components = bindAddress.split(separator: ".", omittingEmptySubsequences: false)
        let loopback = bindAddress == "::1" || (components.count == 4 && components.first == "127"
            && components.allSatisfy { UInt8($0) != nil })
        let lab = exposure.mode == .intranetLab && exposure.allowUnauthorizedIntranetLab
        if (!loopback && !lab) || exposure.mode == .external {
            if !secure && !findings.contains(where: { $0.code == .tlsRequired }) {
                findings.append(.init(code: .tlsRequired))
            }
            if !authorizerConfigured && !findings.contains(where: { $0.code == .authenticationRequired }) {
                findings.append(.init(code: .authenticationRequired))
            }
        }
        if findings.contains(where: \.isError) { throw MLLPExposureError(findings: findings) }
        return findings
    }
}

public actor MLLPListener {
    private let configuration: MLLPListenerConfiguration
    private let processor: any MLLPMessageProcessing
    private let principals: (any MLLPPrincipalResolving)?
    private let authorization: MLLPAuthorizationBridge?
    private let audit: MLLPAuditing?
    private let ledger: (any MLLPInboundLedger)?
    private let observer: (@Sendable (HL7Message, MLLPProcessingOutcome, String?) async -> Void)?
    private var listener: NWListener?
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var transports: [UUID: MLLPConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var permits: MLLPPermits
    private var running = false
    private var stopping = false
    private var starting = false
    private var socketStopWaiter: CheckedContinuation<Void, Never>?
    private var socketStopTimer: Task<Void, Never>?
    private var generation = UUID()
    public private(set) var inFlight = 0
    public private(set) var refusedConnections = 0
    public private(set) var peakBufferedBytes = 0
    /// Network.framework's resolved required local endpoint after readiness (including assigned port).
    public private(set) var resolvedEndpoint: NWEndpoint?
    public var connections: Int { transports.count }
    public var activeTasks: Int { tasks.count }

    public init(configuration: MLLPListenerConfiguration, processor: any MLLPMessageProcessing,
                principals: (any MLLPPrincipalResolving)? = nil, authorizer: (any DicomAuthorizing)? = nil,
                audit: MLLPAuditing? = nil, ledger: (any MLLPInboundLedger)? = nil,
                observer: (@Sendable (HL7Message, MLLPProcessingOutcome, String?) async -> Void)? = nil) {
        self.configuration = configuration; self.processor = processor; self.principals = principals
        self.authorization = authorizer.map { .init(authorizer: $0, listenerID: configuration.listenerID) }
        self.ledger = ledger; self.observer = observer
        self.audit = audit; permits = MLLPPermits(configuration.limits.maxInFlight)
    }

    public func start() async throws -> UInt16 {
        guard listener == nil, !running, !stopping, !starting, configuration.limits.isValid, configuration.maxConnections > 0,
              configuration.drainTimeout.isFinite, configuration.drainTimeout >= 0 else {
            throw MLLPError.invalidConfiguration
        }
        starting = true
        defer { starting = false }
        let epoch = UUID(); generation = epoch
        // All policy checks and their audit complete before creating/binding a socket.
        do {
            let findings = try configuration.validateExposure(authorizerConfigured: authorization != nil)
            try await audit?.record(.exposure, findings: findings)
        } catch let error as MLLPExposureError {
            try await audit?.record(.exposure, findings: error.findings)
            throw error
        }
        try Task.checkCancellation()
        guard epoch == generation else { throw MLLPError.cancelled }
        let parameters: NWParameters
        do { parameters = try configuration.tls.map { try DicomTLSNetworkParameters.server($0) } ?? .tcp }
        catch { throw MLLPError.invalidConfiguration }
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.bindAddress),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any)
        let network: NWListener
        do { network = try NWListener(using: parameters, on: .any) }
        catch { throw MLLPError.connectionFailed }
        listener = network; running = true
        permits = MLLPPermits(configuration.limits.maxInFlight)
        network.newConnectionHandler = { [weak self] connection in
            Task { if let self { await self.accept(connection, epoch: epoch) } else { connection.cancel() } }
        }
        network.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state, epoch: epoch) } }
        do {
            let port = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<UInt16, Error>) in
                    startWaiter = waiter
                    network.start(queue: DispatchQueue(label: "HL7MLLP.listener"))
                }
            } onCancel: { Task { await self.stop() } }
            try await audit?.record(.start)
            guard running, epoch == generation else { throw MLLPError.cancelled }
            return port
        } catch { await stop(); throw error }
    }
    private func changed(_ state: NWListener.State, epoch: UUID) async {
        guard epoch == generation else { return }
        switch state {
        case .ready:
            if let port = listener?.port {
                if case .hostPort(let host, _) = listener?.parameters.requiredLocalEndpoint {
                    resolvedEndpoint = .hostPort(host: host, port: port)
                }
                startWaiter?.resume(returning: port.rawValue); startWaiter = nil
            }
        case .failed, .cancelled:
            startWaiter?.resume(throwing: MLLPError.connectionFailed); startWaiter = nil
            await stop()
        default: break
        }
    }
    private func accept(_ network: NWConnection, epoch: UUID) async {
        guard epoch == generation, running, transports.count < configuration.maxConnections else {
            network.cancel(); refusedConnections += 1
            try? await audit?.record(.refuse)
            return
        }
        let id = UUID()
        let transport = MLLPConnection(connection: network, limits: configuration.limits)
        transports[id] = transport
        let gate = permits
        tasks[id] = Task { await self.pipeline(id, transport: transport, permits: gate, epoch: epoch) }
    }
    private func pipeline(_ id: UUID, transport: MLLPConnection, permits: MLLPPermits, epoch: UUID) async {
        do {
            try await transport.start()
            try await audit?.record(.accept)
            let peer = await transport.peer
            let fingerprint = await transport.tlsPeerIdentity
            let principal = await principals?.principal(peer: peer, tlsPeerIdentity: fingerprint)
            while !Task.isCancelled, running, epoch == generation, let frame = await transport.next() {
                try await permits.acquire()
                if Task.isCancelled || !running || epoch != generation {
                    await permits.release(); break
                }
                inFlight += 1
                do {
                    try await process(frame, transport: transport, context: .init(peer: peer,
                        transportSecured: configuration.tls?.mode == .enabled, principal: principal,
                        sequence: frame.sequence))
                } catch {
                    if epoch == generation { inFlight -= 1 }
                    await permits.release()
                    throw error
                }
                if epoch == generation { inFlight -= 1 }
                await permits.release()
                await transport.consumed()
            }
        } catch { }
        let metrics = await transport.metrics
        peakBufferedBytes = max(peakBufferedBytes, metrics.peakBufferedBytes)
        await transport.cancel()
        transports.removeValue(forKey: id); tasks.removeValue(forKey: id)
    }
    private func process(_ frame: MLLPFrame, transport: MLLPConnection, context: MLLPInboundContext) async throws {
        let message: HL7Message
        do { message = try frame.decodeHL7() } catch { throw MLLPError.invalidMessage }
        guard let version = message.version else { throw MLLPError.invalidMessage }
        let report: HL7ValidationReport
        if let schema = HL7SchemaRegistry.shared.schema(for: version) {
            report = HL7Validator(schema: schema).validate(message)
        } else {
            report = .init(findings: [.init(code: .structureUnknown, path: .init(segment: "MSH", field: 12))])
        }
        let outcome: MLLPProcessingOutcome
        let key = MLLPMessageKey(message: message, raw: frame.payload)
        var reserved = false
        var denied = false
        if configuration.rejectInvalid && !report.isValid { outcome = .rejectedStructure(report.findings) }
        else if let authorization, await authorization.decide(context: context).outcome == .deny {
            denied = true
            outcome = .rejectedStructure([])
            try await audit?.record(.deny, context: context.accessContext, message: message)
        } else {
            try Task.checkCancellation()
            if let ledger {
                switch try await ledger.begin(key: key) {
                case .process: reserved = true
                case .duplicateAlreadyAcked(let ack, let storedOutcome):
                    if !ack.isEmpty { try await transport.send(frame: ack) }
                    try await ledger.markAckSent(key: MLLPMessageKey(message: message, raw: frame.payload))
                    let replay = ack.isEmpty ? nil : try? HL7Parser().parse(Data(ack.dropFirst().dropLast(2)))
                    let code = replay?["MSA"]?[1][1][1][1].text
                    await observer?(message, storedOutcome, code)
                    return
                case .duplicateInProgress:
                    var builder = HL7MessageBuilder(version: version)
                    builder.ack(for: message, code: .AR, text: "in progress")
                    try await transport.send(frame: MLLPFramer.frame(HL7Serializer().serialize(builder.message)))
                    await observer?(message, .uncertain(reason: "in progress"), "AR")
                    return
                }
            }
            outcome = await processor.process(message, raw: frame.payload, context: context)
        }
        let ack: HL7Message?
        let bytes: Data
        do {
            try Task.checkCancellation()
            try await audit?.record(.processed, context: context.accessContext, message: message, outcome: outcome)
            var policy = configuration.ackPolicy.resolved(for: message)
            // An authorization refusal always returns AR/CR, even if the peer requested suppression.
            if denied { policy.mode = policy.mode == .original ? .original : .always }
            ack = try MLLPAckBuilder.ack(for: message, outcome: outcome, policy: policy)
            bytes = try ack.map { try MLLPFramer.frame(HL7Serializer().serialize($0)) } ?? Data()
            // Validation/authorization refusals do not reserve a processing entry.
            if reserved { try await ledger?.recordOutcome(key: key, outcome: outcome, ackBytes: bytes) }
        } catch {
            if reserved {
                try? await ledger?.recordOutcome(key: key, outcome: .uncertain(reason: "processingIncomplete"),
                    ackBytes: Data())
            }
            throw error
        }
        if !bytes.isEmpty { try await transport.send(frame: bytes) }
        if reserved { try await ledger?.markAckSent(key: key) }
        await observer?(message, outcome, ack?["MSA"]?[1][1][1][1].text)

    }
    /// Providers must cooperate with cancellation. Drain is bounded even if host processing does not finish.
    public func stop() async {
        guard !stopping, listener != nil || running || starting else { return }
        stopping = true
        running = false
        if let network = listener {
            network.newConnectionHandler = nil
            await withCheckedContinuation { waiter in
                socketStopWaiter = waiter
                socketStopTimer = Task {
                    do { try await mllpSleep(max(0.1, configuration.drainTimeout)) } catch { return }
                    self.socketStopped()
                }
                network.stateUpdateHandler = { [weak self] state in
                    if case .cancelled = state { Task { await self?.socketStopped() } }
                }
                network.cancel()
            }
            network.stateUpdateHandler = nil
        }
        listener = nil
        startWaiter?.resume(throwing: MLLPError.cancelled); startWaiter = nil
        let epoch = generation
        let end = ContinuousClock.now.advanced(by: .seconds(configuration.drainTimeout))
        while inFlight > 0 && ContinuousClock.now < end && !Task.isCancelled {
            try? await mllpSleep(0.01)
        }
        guard epoch == generation else { return }
        generation = UUID()
        await permits.close()
        let active = transports.values
        for task in tasks.values { task.cancel() }
        for transport in active { await transport.cancel() }
        tasks.removeAll(); transports.removeAll(); inFlight = 0; resolvedEndpoint = nil
        try? await audit?.record(.stop)
        stopping = false
    }

    private func socketStopped() {
        socketStopTimer?.cancel(); socketStopTimer = nil
        socketStopWaiter?.resume(); socketStopWaiter = nil
    }
}
