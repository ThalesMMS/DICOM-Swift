import Foundation
#if canImport(Network)
import Network
#endif

public struct DicomDIMSEServerConfiguration: Sendable {
    public var bindAddress: String = ""
    public var maximumOutstandingOperations: Int = 16
    public var storage: DicomStorageSCPConfiguration
    /// Explicit per-service syntax allowlist. Omitted entries use the storage configuration syntaxes.
    public var serviceTransferSyntaxes: [String: [DicomTransferSyntax]]
    public var asynchronousOperationsWindow: DicomAsynchronousOperationsWindow
    public var extendedNegotiations: [DicomSOPClassExtendedNegotiation]
    /// Objects one C-GET or C-MOVE may serve (issue #2817), apart from the C-STORE admission limits of `storage`;
    /// the sub-operation counts of the responses are 16-bit.
    public var maximumRetrieveObjects: Int = Int(UInt16.max)

    public init(aeTitle: String, port: UInt16 = 11112, maximumPDULength: UInt32 = 16_384,
                tls: DicomTLSConfiguration = .disabled,
                asynchronousOperationsWindow: DicomAsynchronousOperationsWindow = .init(),
                serviceTransferSyntaxes: [String: [DicomTransferSyntax]] = [:],
                extendedNegotiations: [DicomSOPClassExtendedNegotiation] = []) {
        storage = DicomStorageSCPConfiguration(aeTitle: aeTitle, port: port,
            maximumPDULength: maximumPDULength, tls: tls)
        self.asynchronousOperationsWindow = asynchronousOperationsWindow
        self.serviceTransferSyntaxes = serviceTransferSyntaxes
        self.extendedNegotiations = extendedNegotiations
    }
}

/// Composable DIMSE acceptor. Blocking transport reads run on a listener worker;
/// asynchronous providers run in tasks and share one serialized message writer.
public final class DicomDIMSEServer: @unchecked Sendable {
    public let configuration: DicomDIMSEServerConfiguration
    let query: (any DicomQueryProviding)?
    let retrieve: (any DicomRetrieveProviding)?
    let moveDestinations: (any DicomMoveDestinationResolving)?
    let worklist: (any DicomQueryProviding)?
    let unifiedProcedureSteps: DicomUnifiedProcedureStepService?
    let instanceAvailability: (any DicomInstanceAvailabilityNotificationReceiving)?
    let mpps: (any DicomModalityPerformedProcedureStepProviding)?
    let commitment: (any DicomStorageCommitmentProviding)?
    let commitmentEvidence: (any DicomCommitmentEvidenceProviding)?
    let commitmentPolicy: DicomDurabilityPolicy
    let printConfiguration: DicomPrintSCPConfiguration?
    let printProvider: (any DicomPrintSCPProviding)?
    let printQueueAdmission: DicomPrintQueueAdmission
    public let commitmentResultHandler: (@Sendable (DicomStorageCommitmentReport) throws -> Void)?
    public let onCommitmentReportDelivered: (@Sendable (String, DicomNetworkAuditEvent.Outcome) async throws -> Void)?
    let commitmentDeliveryLock = NSLock()
    var commitmentReports: [String: DicomStorageCommitmentReport] = [:]
    var commitmentDelivering: Set<String> = []
    var commitmentDelivered: Set<String> = []
    public let resourceResolver: (@Sendable (String) async -> DicomResourceRef?)?
    public let authorizer: (any DicomAuthorizing)?
    public let audit: DicomAuditRecorder?
    /// Nil preserves legacy binding without exposure validation. Hosts exposed beyond loopback MUST
    /// pass a policy; the product and dicomtool always supply one.
    public let exposure: DicomExposurePolicy?
    public let peerPrincipalResolver: (@Sendable (String, String, String) async -> DicomPrincipal?)?
    let identity: (any DicomUserIdentityAuthenticating)?
    let auditLogger: (any DicomNetworkAuditLogging)?
    let resourceGovernor: DicomStorageSCPResourceGovernor
    let storageService: DicomStorageSCPService?
    private var legacyStorageMode = false
    private var tlsContext: DicomAppliedTLSContext?
    private let lifecycleLock = NSLock()
    #if canImport(Network)
    private var listener: NWListener?
    #endif
    private var notificationTasks: [UUID: Task<Void, Never>] = [:]
    private var transports: [UUID: DicomTCPAssociationTransport] = [:]
    private let workers = DispatchGroup()
    private let listenerCancelled = DispatchSemaphore(value: 0)
    private var didStart = false

    public init(configuration: DicomDIMSEServerConfiguration,
                storage: DicomStorageSCPService? = nil,
                ingest: DicomIngestCoordinator? = nil,
                durabilityPolicy: DicomDurabilityPolicy = .init(),
                query: (any DicomQueryProviding)? = nil,
                retrieve: (any DicomRetrieveProviding)? = nil,
                moveDestinations: (any DicomMoveDestinationResolving)? = nil,
                worklist: (any DicomQueryProviding)? = nil,
                mpps: (any DicomModalityPerformedProcedureStepProviding)? = nil,
                commitment: (any DicomStorageCommitmentProviding)? = nil,
                commitmentEvidence: (any DicomCommitmentEvidenceProviding)? = nil,
                commitmentPolicy: DicomDurabilityPolicy = .init(required: .retentionConfirmed),
                commitmentResultHandler: (@Sendable (DicomStorageCommitmentReport) throws -> Void)? = nil,
                onCommitmentReportDelivered: (@Sendable (String, DicomNetworkAuditEvent.Outcome) async throws -> Void)? = nil,
                unifiedProcedureSteps: DicomUnifiedProcedureStepService? = nil,
                instanceAvailability: (any DicomInstanceAvailabilityNotificationReceiving)? = nil,
                print printConfiguration: DicomPrintSCPConfiguration? = nil,
                printProvider: (any DicomPrintSCPProviding)? = nil,
                identity: (any DicomUserIdentityAuthenticating)? = nil,
                resourceGovernor: DicomStorageSCPResourceGovernor? = nil,
                auditLogger: (any DicomNetworkAuditLogging)? = nil,
                peerPrincipalResolver: (@Sendable (String, String, String) async -> DicomPrincipal?)? = nil,
                notificationPrincipalProvider: (@Sendable () async -> DicomPrincipal?)? = nil,
                authorizer: (any DicomAuthorizing)? = nil, audit: DicomAuditRecorder? = nil,
                exposure: DicomExposurePolicy? = nil,
                resourceResolver: (@Sendable (String) async -> DicomResourceRef?)? = nil) {
        self.resourceResolver = resourceResolver
        self.authorizer = authorizer; self.audit = audit; self.exposure = exposure
        self.peerPrincipalResolver = peerPrincipalResolver
        self.configuration = configuration
        let governor = resourceGovernor ?? storage?.resourceGovernor
            ?? DicomStorageSCPResourceGovernor(configuration: configuration.storage)
        if let ingest {
            self.storageService = storage?.withIngest(ingest, policy: durabilityPolicy, resourceGovernor: governor)
                ?? DicomStorageSCPService(configuration: configuration.storage,
                    storage: DicomIngestStorageAdapter(ingest: ingest), ingest: ingest, durabilityPolicy: durabilityPolicy, resourceGovernor: governor)
        } else { self.storageService = storage }
        self.query = query
        self.retrieve = retrieve
        self.moveDestinations = moveDestinations
        self.worklist = worklist
        self.unifiedProcedureSteps = unifiedProcedureSteps
        self.instanceAvailability = instanceAvailability
        self.printConfiguration = printConfiguration
        self.printProvider = printProvider
        self.printQueueAdmission = .init(maximum: printConfiguration?.maximumQueuedJobs ?? 0)
        self.mpps = mpps
        self.commitment = commitment
        self.commitmentEvidence = commitmentEvidence ?? commitment?.evidenceProvider
        self.commitmentPolicy = commitmentPolicy
        self.commitmentResultHandler = commitmentResultHandler
        self.onCommitmentReportDelivered = onCommitmentReportDelivered
        self.identity = identity
        self.resourceGovernor = governor
        self.auditLogger = auditLogger
        if let moveDestinations {
            unifiedProcedureSteps?.installEventSinkIfAbsent(DicomDIMSEUnifiedProcedureStepEventSink(
                resolver: moveDestinations, callingAETitle: configuration.storage.aeTitle,
                timeout: configuration.storage.timeout, authorizer: authorizer, audit: audit,
                principalProvider: { _, _ in await notificationPrincipalProvider?() }))
        }
    }

    convenience init(legacyStorageService: DicomStorageSCPService) {
        var configuration = DicomDIMSEServerConfiguration(aeTitle: legacyStorageService.configuration.aeTitle)
        configuration.storage = legacyStorageService.configuration
        self.init(configuration: configuration, storage: legacyStorageService)
        legacyStorageMode = true
    }

    func prepareListener() throws {
        #if canImport(Network)
        if lifecycleLock.withLock({ self.listener != nil }) { return }
        if let exposure {
            if exposure.mode != .localOnly,
               !(exposure.mode == .intranetLab && exposure.allowUnauthorizedIntranetLab),
               configuration.storage.tls.mode != .enabled {
                throw DicomExposureValidationError(findings: [.init(code: .tlsRequired)])
            }
            let findings = try exposure.validate(bindAddress: configuration.bindAddress,
                tlsEnabled: configuration.storage.tls.mode == .enabled,
                authenticationConfigured: exposure.mode == .localOnly || (authorizer != nil && (identity != nil || peerPrincipalResolver != nil)))
            if let audit {
                try DicomIngestBlockingResult.run { [findings] in
                    try await audit.record(DicomAuditMessages.exposureFindings(findings, principal: nil,
                        context: .init(protocol: .dimse)))
                }
            }
        }
        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: configuration.storage.tls, role: .server)
        let listener: NWListener
        if !configuration.bindAddress.isEmpty {
            prepared.parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.bindAddress),
                port: NWEndpoint.Port(rawValue: configuration.storage.port)!)
            listener = try NWListener(using: prepared.parameters)
        } else {
            listener = try NWListener(using: prepared.parameters,
                on: NWEndpoint.Port(rawValue: configuration.storage.port) ?? .any)
        }
        lifecycleLock.withLock { self.listener = listener; self.tlsContext = prepared.tlsContext }
        #endif
    }

    func scheduleNotification(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        workers.enter()
        lifecycleLock.withLock {
            notificationTasks[id] = Task.detached { [self] in
                await operation()
                _ = lifecycleLock.withLock { notificationTasks.removeValue(forKey: id) }
                workers.leave()
            }
        }
    }

    public var listeningPort: UInt16? {
        #if canImport(Network)
        return lifecycleLock.withLock { listener?.port?.rawValue }
        #else
        return nil
        #endif
    }

    public var metrics: DicomStorageSCPMetrics { resourceGovernor.snapshot() }

    public func start(progress: (@Sendable (DicomStorageSCPProgress) -> Void)? = nil) throws {
        #if canImport(Network)
        try prepareListener()
        guard let listener = lifecycleLock.withLock({ self.listener }) else { return }
        let ready = DispatchSemaphore(value: 0)
        let result = DicomSynchronousResult<Void>()
        let listenerCancelled = listenerCancelled
        let governor = resourceGovernor
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { listenerCancelled.signal() }
            if case .ready = state, result.resolve(.success(())) { ready.signal() }
            if case .failed(let error) = state {
                let fault = DicomStorageSCPListenerFault.portUnavailable(error.localizedDescription)
                governor.setFault(fault)
                progress?(.listenerFault(fault))
                if result.resolve(.failure(error)) { ready.signal() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let peer: String
            if case .hostPort(let host, _) = connection.endpoint { peer = String(describing: host) }
            else { peer = String(describing: connection.endpoint) }
            guard DicomStorageSCPPeerAccess.allows(connection.endpoint,
                acceptOnlyIntranet: self.configuration.storage.acceptOnlyIntranet) else { connection.cancel(); return }
            let transport = DicomTCPAssociationTransport(acceptedConnection: connection,
                timeout: self.configuration.storage.timeout,
                maximumIncomingPDUSize: self.configuration.storage.maximumPDULength)
            transport.startAcceptedConnection()
            if let reason = self.resourceGovernor.admitAssociation(peer: peer) {
                let rejection = DicomAssociationReject(result: .rejectedTransient,
                    source: .serviceProviderACSE, reason: .providerLocalLimitExceeded)
                try? transport.writePDU(DicomPDUCodec.encode(.associationReject(rejection)))
                progress?(.pressure(reason))
                progress?(.metrics(self.resourceGovernor.snapshot()))
                transport.close()
                return
            }
            progress?(.metrics(self.resourceGovernor.snapshot()))
            let id = UUID()
            self.lifecycleLock.withLock { self.transports[id] = transport }
            self.workers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    transport.close()
                    self.resourceGovernor.releaseAssociation(peer: peer)
                    _ = self.lifecycleLock.withLock { self.transports.removeValue(forKey: id) }
                    progress?(.metrics(self.resourceGovernor.snapshot()))
                    self.workers.leave()
                }
                do { try self.handleAssociation(using: transport, progress: progress, peerAddress: peer) }
                catch {
                    self.resourceGovernor.recordFailure()
                    progress?(.metrics(self.resourceGovernor.snapshot()))
                }
            }
        }
        lifecycleLock.withLock { self.listener = listener }
        lifecycleLock.withLock { didStart = true }
        listener.start(queue: DispatchQueue(label: "DicomDIMSEServer.listener"))
        guard ready.wait(timeout: .now() + configuration.storage.timeout) == .success else {
            listener.cancel()
            throw DicomNetworkError.networkTimeout("starting DIMSE server")
        }
        try result.get()
        if let unifiedProcedureSteps {
            scheduleNotification { try? await unifiedProcedureSteps.scpStatusChanged(status: .restarted) }
        }
        #else
        throw DicomNetworkError.networkUnavailable("Network framework unavailable")
        #endif
    }

    public func stop() async {
        resourceGovernor.stopAccepting()
        #if canImport(Network)
        lifecycleLock.withLock { listener?.cancel() }
        #endif
        guard lifecycleLock.withLock({ didStart }) else { return }
        let cancelled = listenerCancelled
        let timeout = configuration.storage.timeout
        let workers = workers
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = cancelled.wait(timeout: .now() + timeout)
                continuation.resume()
            }
        }
        let drained = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: workers.wait(timeout: .now() + timeout) == .success) }
        }
        if !drained {
            let active = lifecycleLock.withLock { Array(transports.values) }
            active.forEach { $0.close() }
            lifecycleLock.withLock { notificationTasks.values.forEach { $0.cancel() } }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    _ = workers.wait(timeout: .now() + timeout)
                    continuation.resume()
                }
            }
        }
    }

    public func handleAssociation(using transport: DicomAssociationTransport,
                                  progress: (@Sendable (DicomStorageSCPProgress) -> Void)? = nil,
                                  peerAddress: String = "") throws {
        do {
            try serveAssociation(using: transport, progress: progress, peerAddress: peerAddress)
        } catch {
            // An unexpected or malformed PDU is answered with A-ABORT before the
            // connection closes (PS3.8 AA-1/AA-8, issue #2792): the first PDU of
            // an association must be an A-ASSOCIATE-RQ.
            let abort = DicomAbort.forProtocolError(error) ?? {
                guard case DicomStorageSCPError.associationRequestExpected = error else { return nil }
                return DicomAbort(source: .serviceProvider, reason: .unexpectedPDU)
            }()
            if let abort { try? transport.writePDU(DicomPDUCodec.encode(.abort(abort))) }
            throw error
        }
    }

    private func serveAssociation(using transport: DicomAssociationTransport,
                                  progress: (@Sendable (DicomStorageSCPProgress) -> Void)?,
                                  peerAddress: String) throws {
        if legacyStorageMode, let storageService {
            _ = try storageService.handleAssociation(using: transport, progress: progress)
            return
        }
        guard case .associationRequest(let request) = try DicomPDUCodec.decode(transport.readPDU()) else {
            throw DicomStorageSCPError.associationRequestExpected
        }
        let config = configuration.storage
        guard config.acceptAnyCalledAETitle || request.calledAETitle == config.aeTitle else {
            try reject(transport, reason: .calledAENotRecognized)
            return
        }
        guard config.allowedCallingAETitles.isEmpty || config.allowedCallingAETitles.contains(request.callingAETitle) else {
            try reject(transport, reason: .callingAENotRecognized)
            return
        }
        var supported: Set<String> = [DicomNetworkUID.verificationSOPClass]
        if let printConfiguration, printProvider != nil {
            supported.formUnion(printConfiguration.capabilities.acceptedSOPClassUIDs)
        }
        if storageService != nil { supported.formUnion(config.supportedStorageSOPClassUIDs) }
        if query != nil { supported.formUnion(DicomQueryRetrieveModelPreference.find) }
        if retrieve != nil {
            supported.formUnion(DicomQueryRetrieveModelPreference.get)
            supported.formUnion(DicomQueryRetrieveModelPreference.move)
            supported.formUnion(config.supportedStorageSOPClassUIDs)
        }
        if unifiedProcedureSteps != nil { supported.formUnion(DicomNetworkUID.unifiedProcedureStepSOPClasses) }
        if instanceAvailability != nil { supported.insert(DicomNetworkUID.instanceAvailabilityNotificationSOPClass) }
        if worklist != nil { supported.insert(DicomNetworkUID.modalityWorklistInformationModelFind) }
        if mpps != nil { supported.insert(DicomNetworkUID.modalityPerformedProcedureStepSOPClass) }
        if commitment != nil || commitmentResultHandler != nil { supported.insert(DicomNetworkUID.storageCommitmentPushModelSOPClass) }
        var outgoing = retrieve == nil ? Set<String>() : config.supportedStorageSOPClassUIDs
        if commitment != nil || commitmentResultHandler != nil { outgoing.insert(DicomNetworkUID.storageCommitmentPushModelSOPClass) }
        if unifiedProcedureSteps != nil { outgoing.insert(DicomNetworkUID.unifiedProcedureStepEventSOPClass) }
        var accept = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: supported,
            preferredTransferSyntaxes: config.transferSyntaxes, maximumPDULength: config.maximumPDULength,
            supportedSCUAbstractSyntaxUIDs: outgoing,
            supportedAsynchronousOperationsWindow: configuration.asynchronousOperationsWindow,
            supportedExtendedNegotiations: configuration.extendedNegotiations)
        for index in accept.presentationContexts.indices {
            if let proposed = request.presentationContexts.first(where: { $0.id == accept.presentationContexts[index].id }),
               printProvider != nil, printConfiguration?.capabilities.acceptedSOPClassUIDs.contains(proposed.abstractSyntaxUID) == true {
                let selected = [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian]
                    .first { proposed.transferSyntaxUIDs.contains($0.rawValue) }
                accept.presentationContexts[index] = .init(id: proposed.id,
                    result: selected == nil ? .transferSyntaxNotSupported : .acceptance, transferSyntaxUID: selected?.rawValue)
                continue
            }
            guard let proposed = request.presentationContexts.first(where: { $0.id == accept.presentationContexts[index].id }),
                  supported.contains(proposed.abstractSyntaxUID),
                  let syntaxes = configuration.serviceTransferSyntaxes[proposed.abstractSyntaxUID] else { continue }
            let selected = syntaxes.first { proposed.transferSyntaxUIDs.contains($0.rawValue) }
            accept.presentationContexts[index] = DicomPresentationContextAccept(id: proposed.id,
                result: selected == nil ? .transferSyntaxNotSupported : .acceptance,
                transferSyntaxUID: selected?.rawValue)
        }
        // A query, retrieve or workflow context carries identifiers only: it never takes an encapsulated syntax,
        // whatever the storage preference is.
        for index in accept.presentationContexts.indices where accept.presentationContexts[index].result == .acceptance {
            guard let proposed = request.presentationContexts.first(where: { $0.id == accept.presentationContexts[index].id }),
                  !DicomStorageSOPClassUIDs.mayCarryEncapsulatedPixelData(proposed.abstractSyntaxUID),
                  let chosen = accept.presentationContexts[index].transferSyntaxUID.flatMap(DicomTransferSyntax.init(rawValue:)),
                  chosen.registryEntry.isEncapsulated else { continue }
            let native = DicomStorageSOPClassUIDs.transferSyntaxes(config.transferSyntaxes + [.explicitVRLittleEndian,
                .implicitVRLittleEndian], forAbstractSyntax: proposed.abstractSyntaxUID)
            let selected = native.first { proposed.transferSyntaxUIDs.contains($0.rawValue) }
            accept.presentationContexts[index] = DicomPresentationContextAccept(id: proposed.id,
                result: selected == nil ? .transferSyntaxNotSupported : .acceptance,
                transferSyntaxUID: selected?.rawValue)
        }
        var principal = DicomPrincipal.anonymous
        if let identity {
            guard let credentials = request.userIdentity else { try reject(transport); return }
            do {
                let response = try identity.authenticate(credentials)
                // The successful authenticator owns verification. Never log credential or response bytes.
                let id = (credentials.type == .username || credentials.type == .usernameAndPasscode)
                    ? String(data: credentials.primaryField, encoding: .utf8) ?? "authenticated-peer"
                    : "authenticated-peer"
                principal = .init(id: id, kind: .peerApplication, source: .userIdentityNegotiation,
                    sessionID: UUID().uuidString, authenticatedAt: Date(), policyVersion: 0)
                if credentials.positiveResponseRequested {
                    accept.userIdentityServerResponse = response ?? DicomUserIdentityServerResponse(data: Data())
                }
            } catch { try reject(transport); return }
        }
        if principal.kind == .anonymous, let peerPrincipalResolver {
            principal = try DicomIngestBlockingResult.run {
                await peerPrincipalResolver(request.calledAETitle, request.callingAETitle, peerAddress) ?? .anonymous
            }
        }
        let associationContext = DicomAssociationContext(principal: principal,
            access: .init(callingAETitle: request.callingAETitle, calledAETitle: request.calledAETitle,
                peerAddress: peerAddress.isEmpty ? nil : peerAddress,
                transportSecured: config.tls.mode == .enabled, protocol: .dimse))
        let encodedAccept: Data
        do {
            encodedAccept = try DicomPDUCodec.encode(.associationAccept(accept))
        } catch { try reject(transport); return }
        try transport.writePDU(encodedAccept)
        progress?(.associationAccepted(callingAETitle: request.callingAETitle))
        let session = DicomDIMSEServerSession(transport: transport,
            association: DicomAssociation(request: request, accept: accept), timeout: config.timeout,
            governor: resourceGovernor, maximumOutstanding: configuration.maximumOutstandingOperations, auditLogger: auditLogger,
            authorizationContext: associationContext)
        if let printConfiguration, let printProvider {
            session.printState = DicomPrintAssociationState(configuration: printConfiguration, provider: printProvider,
                                                           queueAdmission: printQueueAdmission)
        }
        defer { session.cancelAll() }
        defer { if let state = session.printState { Task { await state.release() } } }
        let printIngress = session.printState.map {
            DicomPrintAdmissionTransport(underlying: transport, association: session.association, budget: $0.ingressBudget)
        }
        let incoming: DicomAssociationTransport = printIngress ?? transport
        let reader = DicomDIMSEMessageReader()
        var receivedObjectCount = 0
        var receivedByteCount: Int64 = 0
        while true {
            switch try reader.readNext(from: incoming) {
            case .releaseRequest:
                session.waitForOperations()
                try transport.writePDU(DicomPDUCodec.encode(.releaseResponse))
                progress?(.released)
                return
            case .message(let message):
                guard message.isCommand else { throw DicomNetworkError.malformedCommandSet("Expected command") }
                let command = try DicomDIMSECommandSet.decode(message.data)
                if command.commandField == DicomDIMSECommandField.cCancelRQ {
                    session.cancel(command.messageIDBeingRespondedTo, contextID: message.presentationContextID)
                    continue
                }
                if command.commandField & 0x8000 != 0 { try session.receive(command); continue }
                let context = try session.context(message.presentationContextID)
                if command.commandField == DicomDIMSECommandField.cStoreRQ, let storageService {
                    do {
                        try session.performSynchronousOperation(command) {
                            try storageService.handleDelegatedStore(command: command, contextID: context.id,
                                association: session.association, transport: DicomDIMSEStorageTransport(session: session),
                                reader: reader, receivedObjectCount: &receivedObjectCount, receivedByteCount: &receivedByteCount,
                                progress: progress, authorize: { [self] dataSet in
                                    try DicomIngestBlockingResult.run {
                                        guard let resource = DicomResourceRef.dataSet(dataSet) else {
                                            if self.authorizer != nil { throw DicomDIMSEProviderError(status: 0xA900) }; return
                                        }
                                        _ = try await self.enforcement(session).check(.store, resource)
                                    }
                                })
                        }
                    } catch let failure as DicomDIMSEProviderError {
                        if command.commandDataSetType != DicomDIMSECommandDataSetType.noDataSet {
                            // Drain the refused dataset without retaining it before reading the next command.
                            do { _ = try reader.readMessage(from: transport, maximumDataLength: 0) }
                            catch DicomStorageSCPAdmissionError.messageTooLarge {}
                        }
                        try session.reply(command, contextID: context.id, status: failure.status,
                                          errorComment: failure.errorComment, errorID: failure.errorID)
                    }
                    continue
                }
                var bytes: Data?
                if command.commandDataSetType != DicomDIMSECommandDataSetType.noDataSet {
                    let printSOP = command.affectedSOPClassUID ?? command.requestedSOPClassUID ?? ""
                    let printRequest = session.printState != nil && printConfiguration?.permits(printSOP) == true
                    let printImage = printRequest && [DicomNetworkUID.basicGrayscaleImageBoxSOPClass,
                        DicomNetworkUID.basicColorImageBoxSOPClass].contains(printSOP)
                    // Pixel admission happens in the PDV wrapper. The message
                    // accumulator also bounds the metadata envelope independently.
                    let maximumLength = printRequest
                        ? min(config.maximumBytesPerAssociation, printImage
                            ? Int64(min(Int.max - 65536, printConfiguration?.limits.bytesPerImageBox ?? 0) + 65536)
                            : 65536)
                        : config.maximumBytesPerAssociation
                    let payload: DicomDIMSEMessage
                    do { payload = try reader.readMessage(from: incoming, maximumDataLength: maximumLength) }
                    catch is DicomStorageSCPAdmissionError where printRequest {
                        if printImage { _ = printIngress?.takeImageFailure() }
                        try session.reply(command, contextID: context.id, status: 0x0213)
                        continue
                    }
                    guard !payload.isCommand, payload.presentationContextID == context.id else {
                        throw DicomNetworkError.malformedCommandSet("Mismatched dataset context")
                    }
                    if printImage, let failure = printIngress?.takeImageFailure() {
                        try session.reply(command, contextID: context.id, status: failure)
                        continue
                    }
                    bytes = payload.data
                }
                let payload = bytes
                do {
                    if session.printState != nil,
                       printConfiguration?.permits(command.affectedSOPClassUID ?? command.requestedSOPClassUID ?? "") == true {
                        // Complete admission bookkeeping before reading the next
                        // request: independent SCUs may reuse Message ID 1 immediately.
                        try session.performSynchronousOperation(command) {
                            let completed = DispatchSemaphore(value: 0)
                            Task {
                                await dispatch(command, context: context, bytes: payload, session: session, commandBytes: message.data)
                                completed.signal()
                            }
                            completed.wait()
                        }
                        continue
                    }
                    try session.begin(command: command, contextID: context.id) { [self] in
                        await dispatch(command, context: context, bytes: payload, session: session, commandBytes: message.data)
                    }
                } catch let failure as DicomDIMSEProviderError {
                    try session.reply(command, contextID: context.id, status: failure.status,
                                      errorComment: failure.errorComment, errorID: failure.errorID)
                }
            }
        }
    }

    private func reject(_ transport: DicomAssociationTransport, reason: DicomAssociationRejectReason = .noReason) throws {
        try transport.writePDU(DicomPDUCodec.encode(.associationReject(DicomAssociationReject(
            result: .rejectedPermanent, source: .serviceUser, reason: reason))))
    }

    func sourceResource(_ instanceUID: String) async throws -> DicomResourceRef {
        if let resource = await resourceResolver?(instanceUID), resource.kind == .instance,
           resource.id == instanceUID, resource.ancestry.contains(where: { $0.kind == .study }) { return resource }
        if authorizer != nil { throw DicomDIMSEProviderError(status: 0xA900) }
        return .init(kind: .instance, id: instanceUID)
    }

    func enforcement(_ session: DicomDIMSEServerSession) -> DicomEnforcement {
        .init(principal: session.authorizationContext.principal, authorizer: authorizer, audit: audit,
              context: session.authorizationContext.access)
    }

    func dispatch(_ command: DicomDIMSECommandSet, context: DicomAcceptedPresentationContext,
                  bytes: Data?, session: DicomDIMSEServerSession, commandBytes: Data? = nil) async {
        do {
            let sopClass = command.affectedSOPClassUID ?? command.requestedSOPClassUID
            let upsContext = DicomNetworkUID.unifiedProcedureStepSOPClasses.contains(context.abstractSyntaxUID)
            let upsNormalized = upsContext && command.commandField >= DicomDIMSECommandField.nEventReportRQ
                && command.commandField <= 0x0150
                && sopClass == DicomNetworkUID.unifiedProcedureStepPushSOPClass
            let printMeta = [DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                             DicomNetworkUID.basicColorPrintManagementMetaSOPClass].contains(context.abstractSyntaxUID)
            let printComponent = [DicomNetworkUID.basicFilmSessionSOPClass, DicomNetworkUID.basicFilmBoxSOPClass,
                DicomNetworkUID.printerSOPClass, context.abstractSyntaxUID == DicomNetworkUID.basicColorPrintManagementMetaSOPClass
                    ? DicomNetworkUID.basicColorImageBoxSOPClass : DicomNetworkUID.basicGrayscaleImageBoxSOPClass].contains(sopClass ?? "")
            guard sopClass == context.abstractSyntaxUID || upsNormalized || printMeta && printComponent else {
                throw DicomDIMSEProviderError(status: 0x0122)
            }
            switch command.commandField {
            case DicomDIMSECommandField.cEchoRQ:
                guard context.abstractSyntaxUID == DicomNetworkUID.verificationSOPClass else {
                    throw DicomDIMSEProviderError(status: 0x0122)
                }
            case DicomDIMSECommandField.cFindRQ:
                guard DicomQueryRetrieveModelPreference.find.contains(context.abstractSyntaxUID)
                    || context.abstractSyntaxUID == DicomNetworkUID.modalityWorklistInformationModelFind || upsContext else {
                    throw DicomDIMSEProviderError(status: 0xA900)
                }
            case DicomDIMSECommandField.cGetRQ:
                guard DicomQueryRetrieveModelPreference.get.contains(context.abstractSyntaxUID) else {
                    throw DicomDIMSEProviderError(status: 0xA900)
                }
            case DicomDIMSECommandField.cMoveRQ:
                guard DicomQueryRetrieveModelPreference.move.contains(context.abstractSyntaxUID) else {
                    throw DicomDIMSEProviderError(status: 0xA900)
                }
            default: break
            }
            let identifier = try bytes.map {
                if let printConfiguration, session.printState != nil,
                   printMeta || printConfiguration.permits(sopClass ?? "") {
                    return try printSCPDataSet($0, syntax: context.transferSyntax ?? .implicitVRLittleEndian,
                                               limits: printConfiguration.limits)
                }
                return try DicomDataSetParser.dataSet(from: $0, transferSyntax: context.transferSyntax ?? .implicitVRLittleEndian,
                    limits: configuration.storage.dataSetParseLimits)
            }
            if upsContext, command.commandField >= 0x0100 && command.commandField <= 0x0150 {
                let uid = command.affectedSOPInstanceUID ?? command.requestedSOPInstanceUID ?? "workitem"
                _ = try await enforcement(session).check(command.commandField == 0x0110 ? .readMetadata : .workitemChange,
                    .init(kind: .workitem, id: uid))
            }
            if let printState = session.printState, printMeta || printConfiguration?.permits(sopClass ?? "") == true {
                let operation: DicomAccessOperation
                switch command.commandField {
                case DicomDIMSECommandField.nGetRQ: operation = .readMetadata
                case DicomDIMSECommandField.nDeleteRQ: operation = .delete
                case DicomDIMSECommandField.nActionRQ: operation = .export
                default: operation = .store
                }
                _ = try await enforcement(session).check(operation, .init(kind: .instance,
                    id: command.affectedSOPInstanceUID ?? command.requestedSOPInstanceUID ?? context.abstractSyntaxUID))
                try await printState.handle(command, context: context, data: identifier, connection: session)
                return
            }
            if upsContext || context.abstractSyntaxUID == DicomNetworkUID.instanceAvailabilityNotificationSOPClass {
                try await unifiedProcedureStep(command, context: context, identifier: identifier,
                                               session: session, commandBytes: commandBytes)
                return
            }
            switch command.commandField {
            case DicomDIMSECommandField.cEchoRQ:
                try session.reply(command, contextID: context.id, status: 0)
            case DicomDIMSECommandField.cGetRQ, DicomDIMSECommandField.cMoveRQ:
                try await retrieve(command, context: context, identifier: identifier, session: session,
                    move: command.commandField == DicomDIMSECommandField.cMoveRQ)
            case DicomDIMSECommandField.nCreateRQ, DicomDIMSECommandField.nSetRQ:
                try await workflow(command, context: context, identifier: identifier, session: session)
            case DicomDIMSECommandField.nEventReportRQ:
                try await receiveCommitmentReport(command, context: context, identifier: identifier, session: session)
            case DicomDIMSECommandField.nActionRQ:
                try await storageCommitment(command, context: context, identifier: identifier, session: session)
            case DicomDIMSECommandField.cFindRQ:
                try await find(command, context: context, identifier: identifier, session: session)
            default:
                try session.reply(command, contextID: context.id, status: 0x0122)
            }
        } catch {
            let failure = error as? DicomDIMSEProviderError
            let isPrint = session.printState != nil && printConfiguration?.permits(
                command.affectedSOPClassUID ?? command.requestedSOPClassUID ?? "") == true
            try? session.reply(command, contextID: context.id,
                status: error is CancellationError ? 0xFE00 : failure?.status ?? (error is DicomWebServerFailure || error is DicomAuditError ? 0xA702 : (isPrint ? 0x0110 : 0xC000)),
                errorComment: failure?.errorComment, errorID: failure?.errorID)
        }
    }
}

final class DicomDIMSEServerSession: @unchecked Sendable {
    let authorizationContext: DicomAssociationContext
    var printState: DicomPrintAssociationState?
    let identifier = UUID()
    let transport: DicomAssociationTransport
    let association: DicomAssociation
    let timeout: TimeInterval
    let governor: DicomStorageSCPResourceGovernor
    let maximumOutstanding: Int
    let auditLogger: (any DicomNetworkAuditLogging)?
    private let lock = NSCondition()
    private let writer = NSLock()
    private let group = DispatchGroup()
    private var operations: [UInt16: (UInt8, Task<Void, Never>)] = [:]
    private var nextID: UInt16 = 1
    private var expectedResponses: [UInt16: UInt16] = [:]
    private var responses: [UInt16: DicomDIMSECommandSet] = [:]

    init(transport: DicomAssociationTransport, association: DicomAssociation, timeout: TimeInterval,
         governor: DicomStorageSCPResourceGovernor, maximumOutstanding: Int,
         auditLogger: (any DicomNetworkAuditLogging)?, authorizationContext: DicomAssociationContext = .init()) {
        self.authorizationContext = authorizationContext
        self.transport = transport
        self.association = association
        self.timeout = timeout
        self.governor = governor
        self.maximumOutstanding = max(1, maximumOutstanding)
        self.auditLogger = auditLogger
    }

    func context(_ id: UInt8) throws -> DicomAcceptedPresentationContext {
        guard let context = association.acceptedPresentationContexts.first(where: { $0.id == id }) else {
            throw DicomStorageSCPError.missingPresentationContext(id)
        }
        return context
    }

    func begin(command: DicomDIMSECommandSet, contextID: UInt8,
               body: @escaping @Sendable () async -> Void) throws {
        guard let id = command.messageID else { throw DicomNetworkError.malformedCommandSet("Missing Message ID") }
        lock.lock()
        defer { lock.unlock() }
        let limit = association.accept.asynchronousOperationsWindow?.maximumInvoked ?? 1
        guard operations[id] == nil, limit == 0 || operations.count < Int(limit) else {
            throw DicomNetworkError.malformedCommandSet("Outstanding operation limit or duplicate Message ID")
        }
        guard governor.beginOperation(limit: maximumOutstanding) else {
            throw DicomDIMSEProviderError(status: 0xA700)
        }
        audit(command, outcome: .started)
        group.enter()
        let task = Task.detached { [self] in
            await body()
            finish(id)
        }
        operations[id] = (contextID, task)
    }

    func performSynchronousOperation(_ command: DicomDIMSECommandSet, body: () throws -> Void) throws {
        try lock.withLock {
            let limit = association.accept.asynchronousOperationsWindow?.maximumInvoked ?? 1
            guard let id = command.messageID, operations[id] == nil,
                  limit == 0 || operations.count < Int(limit) else {
                throw DicomNetworkError.malformedCommandSet("Outstanding operation limit or duplicate Message ID")
            }
            guard governor.beginOperation(limit: maximumOutstanding) else {
                throw DicomDIMSEProviderError(status: 0xA700)
            }
        }
        defer { governor.endOperation() }
        audit(command, outcome: .started)
        try body()
    }

    private func finish(_ id: UInt16) {
        lock.lock()
        operations.removeValue(forKey: id)
        lock.unlock()
        governor.endOperation()
        group.leave()
    }

    func cancel(_ id: UInt16?, contextID: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        if let id, let operation = operations[id], operation.0 == contextID { operation.1.cancel() }
    }

    func cancelAll() {
        lock.lock()
        operations.values.forEach { $0.1.cancel() }
        lock.broadcast()
        lock.unlock()
    }

    func waitForOperations() { group.wait() }

    func receive(_ command: DicomDIMSECommandSet) throws {
        guard let id = command.messageIDBeingRespondedTo else {
            throw DicomNetworkError.malformedCommandSet("Missing response Message ID")
        }
        lock.lock()
        guard expectedResponses[id] == command.commandField else {
            lock.unlock()
            throw DicomNetworkError.malformedCommandSet("Unsolicited or mismatched response")
        }
        responses[id] = command
        lock.broadcast()
        lock.unlock()
    }

    func suboperation(_ request: DicomDIMSECommandSet, contextID: UInt8, bytes: Data) async throws -> DicomDIMSECommandSet {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                do { continuation.resume(returning: try blockingSuboperation(request, contextID: contextID, bytes: bytes)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func blockingSuboperation(_ request: DicomDIMSECommandSet, contextID: UInt8,
                                      bytes: Data) throws -> DicomDIMSECommandSet {
        lock.lock()
        let admissionDeadline = Date().addingTimeInterval(timeout)
        let limit = association.accept.asynchronousOperationsWindow?.maximumPerformed ?? 1
        while limit != 0 && expectedResponses.count >= Int(limit) {
            guard lock.wait(until: admissionDeadline) else {
                lock.unlock()
                throw DicomNetworkError.networkTimeout("outgoing operation window")
            }
        }
        while expectedResponses[nextID] != nil { nextID = nextID == .max ? 1 : nextID + 1 }
        let id = nextID
        nextID = nextID == .max ? 1 : nextID + 1
        expectedResponses[id] = request.commandField | 0x8000
        lock.unlock()
        defer {
            lock.lock()
            expectedResponses.removeValue(forKey: id)
            responses.removeValue(forKey: id)
            lock.broadcast()
            lock.unlock()
        }
        var command = request
        command.messageID = id
        try send(command, contextID: contextID, bytes: bytes)
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while responses[id] == nil {
            guard lock.wait(until: deadline) else { throw DicomNetworkError.networkTimeout("DIMSE suboperation") }
        }
        return responses[id]!
    }

    func audit(_ command: DicomDIMSECommandSet, outcome: DicomNetworkAuditEvent.Outcome) {
        let operation: DicomDIMSEOperation
        switch command.commandField & 0x7FFF {
        case DicomDIMSECommandField.cEchoRQ: operation = .verification
        case DicomDIMSECommandField.cFindRQ:
            operation = command.affectedSOPClassUID == DicomNetworkUID.modalityWorklistInformationModelFind
                ? .modalityWorklist : .query
        case DicomDIMSECommandField.cGetRQ: operation = .getRetrieve
        case DicomDIMSECommandField.cMoveRQ: operation = .moveRetrieve
        case DicomDIMSECommandField.cStoreRQ: operation = .store
        case DicomDIMSECommandField.nCreateRQ: operation = .mppsCreate
        case DicomDIMSECommandField.nSetRQ: operation = .mppsUpdate
        case DicomDIMSECommandField.nActionRQ: operation = .storageCommitmentRequest
        case DicomDIMSECommandField.nEventReportRQ: operation = .storageCommitmentReport
        default: return
        }
        auditLogger?.record(DicomNetworkAuditEvent(operation: operation, outcome: outcome, host: "", port: 0,
            calledAETitle: association.request.calledAETitle, attempt: 1, status: command.status))
    }

    func send(_ command: DicomDIMSECommandSet, contextID: UInt8, bytes: Data? = nil,
              attributeIdentifierList: [Int] = []) throws {
        try writer.withLock {
            var encoded = try command.encoded()
            if !attributeIdentifierList.isEmpty {
                var attributes = Data()
                for tag in attributeIdentifierList {
                    for value in [UInt16(truncatingIfNeeded: tag >> 16), UInt16(truncatingIfNeeded: tag)] {
                        attributes.append(UInt8(truncatingIfNeeded: value)); attributes.append(UInt8(value >> 8))
                    }
                }
                encoded.append(contentsOf: [0, 0, 5, 16])
                let length = UInt32(attributes.count)
                for shift in stride(from: 0, to: 32, by: 8) { encoded.append(UInt8(truncatingIfNeeded: length >> shift)) }
                encoded.append(attributes)
                let groupLength = UInt32(encoded.count - 12)
                for index in 0..<4 { encoded[8 + index] = UInt8(truncatingIfNeeded: groupLength >> (index * 8)) }
            }
            try fragments(encoded, contextID: contextID, command: true)
            if let bytes { try fragments(bytes, contextID: contextID, command: false) }
        }
        if command.commandField & 0x8000 != 0, let status = command.status, status != 0xFF00 && status != 0xFF01 {
            audit(command, outcome: status == 0 ? .succeeded : .failed)
        }
    }

    private func fragments(_ bytes: Data, contextID: UInt8, command: Bool) throws {
        let maximum = association.request.maximumPDULength
        guard maximum == 0 || maximum > 6 else { throw DicomNetworkError.malformedCommandSet("PDU limit too small") }
        let length = maximum == 0 ? max(1, bytes.count) : Int(maximum) - 6
        for offset in stride(from: 0, to: max(1, bytes.count), by: length) {
            let end = min(bytes.count, offset + length)
            try transport.writePDU(DicomPDUCodec.encode(.pData([DicomPDV(presentationContextID: contextID,
                isCommand: command, isLastFragment: end == bytes.count, data: bytes.subdata(in: offset..<end))])))
        }
    }

    func reply(_ request: DicomDIMSECommandSet, contextID: UInt8, status: UInt16,
               identifier: DicomDataSet? = nil, errorComment: String? = nil, errorID: UInt16? = nil,
               attributeIdentifierList: [Int] = []) throws {
        let context = try context(contextID)
        let bytes = try identifier.map { try DicomDataSetWriter.dataSetData(from: $0,
            transferSyntax: context.transferSyntax ?? .implicitVRLittleEndian) }
        let response = DicomDIMSECommandSet(affectedSOPClassUID: request.affectedSOPClassUID ?? request.requestedSOPClassUID,
            commandField: request.commandField | 0x8000, messageIDBeingRespondedTo: request.messageID,
            commandDataSetType: bytes == nil ? DicomDIMSECommandDataSetType.noDataSet : DicomDIMSECommandDataSetType.hasDataSet,
            status: status, errorComment: errorComment, errorID: errorID,
            affectedSOPInstanceUID: request.affectedSOPInstanceUID ?? request.requestedSOPInstanceUID,
            eventTypeID: request.eventTypeID, actionTypeID: request.actionTypeID)
        try send(response, contextID: contextID, bytes: bytes, attributeIdentifierList: attributeIdentifierList)
    }
}

/// Keeps legacy C-STORE replies on the association's serialized, fragmenting writer.
private final class DicomDIMSEStorageTransport: DicomAssociationTransport {
    let session: DicomDIMSEServerSession
    init(session: DicomDIMSEServerSession) { self.session = session }
    var isOpen: Bool { session.transport.isOpen }
    func readPDU() throws -> Data { try session.transport.readPDU() }
    func writePDU(_ data: Data) throws {
        guard case .pData(let pdvs) = try DicomPDUCodec.decode(data), pdvs.count == 1,
              let pdv = pdvs.first, pdv.isCommand, pdv.isLastFragment else {
            throw DicomNetworkError.malformedCommandSet("Expected delegated C-STORE response")
        }
        try session.send(DicomDIMSECommandSet.decode(pdv.data), contextID: pdv.presentationContextID)
    }
}
