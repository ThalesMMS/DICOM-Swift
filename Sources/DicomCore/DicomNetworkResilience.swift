import Foundation

public enum DicomTLSMode: String, Codable, Equatable, Hashable, Sendable {
    case disabled
    case enabled
}

public enum DicomTLSSecurityProfile: String, Equatable, Hashable, Sendable {
    case none
    case bcp195RFC8996
}

extension DicomTLSSecurityProfile: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.none.rawValue:
            self = .none
        case Self.bcp195RFC8996.rawValue,
             "nonDowngradingBCP195",
             "bcp195",
             "extendedBCP195",
             "basicRetired",
             "aesRetired",
             "authenticatedUnencryptedRetired":
            self = .bcp195RFC8996
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown DICOM TLS security profile: \(rawValue)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct DicomTLSMaterial: Codable, Equatable, Sendable {
    /// Process-only PKCS#12 identity and password; neither is serialized.
    public var pkcs12Data: Data?
    public var pkcs12Password: String?
    public var certificatePath: String?
    public var privateKeyPath: String?
    /// Process-only key material. Codable conformance intentionally excludes this value.
    public var privateKeyData: Data?
    public var trustStorePath: String?
    public var trustedCertificatePaths: [String]

    private enum CodingKeys: String, CodingKey {
        case certificatePath
        case privateKeyPath
        case trustStorePath
        case trustedCertificatePaths
    }

    public init(certificatePath: String? = nil,
                privateKeyPath: String? = nil,
                privateKeyData: Data? = nil,
                trustStorePath: String? = nil,
                trustedCertificatePaths: [String] = [],
                pkcs12Data: Data? = nil,
                pkcs12Password: String? = nil) {
        self.pkcs12Data = pkcs12Data
        self.pkcs12Password = pkcs12Password
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
        self.privateKeyData = privateKeyData
        self.trustStorePath = trustStorePath
        self.trustedCertificatePaths = trustedCertificatePaths
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        certificatePath = try container.decodeIfPresent(String.self, forKey: .certificatePath)
        privateKeyPath = try container.decodeIfPresent(String.self, forKey: .privateKeyPath)
        privateKeyData = nil
        pkcs12Data = nil
        pkcs12Password = nil
        trustStorePath = try container.decodeIfPresent(String.self, forKey: .trustStorePath)
        trustedCertificatePaths = try container.decodeIfPresent(
            [String].self,
            forKey: .trustedCertificatePaths
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(certificatePath, forKey: .certificatePath)
        try container.encodeIfPresent(privateKeyPath, forKey: .privateKeyPath)
        try container.encodeIfPresent(trustStorePath, forKey: .trustStorePath)
        try container.encode(trustedCertificatePaths, forKey: .trustedCertificatePaths)
    }
}

public struct DicomTLSConfiguration: Codable, Equatable, Sendable {
    public var mode: DicomTLSMode
    public var serverName: String?
    public var material: DicomTLSMaterial?
    public var securityProfile: DicomTLSSecurityProfile
    /// What a server asks of its callers' certificates. Nil keeps the older
    /// rule: a server with trust anchors requires a certificate, one without
    /// does not ask. Ignored by clients, which always verify the server.
    public var clientCertificatePolicy: DicomTLSClientCertificatePolicy?

    public init(mode: DicomTLSMode = .disabled,
                serverName: String? = nil,
                material: DicomTLSMaterial? = nil,
                securityProfile: DicomTLSSecurityProfile = .none,
                clientCertificatePolicy: DicomTLSClientCertificatePolicy? = nil) {
        self.mode = mode
        self.serverName = serverName
        self.material = material
        self.securityProfile = securityProfile
        self.clientCertificatePolicy = clientCertificatePolicy
    }

    public static let disabled = DicomTLSConfiguration()
}

public final class DicomDIMSEOperationHandle: @unchecked Sendable {
    public let id: UUID

    private let lock = NSLock()
    private var cancelled = false
    private var cancelAction: (() -> Void)?

    public init(id: UUID = UUID()) {
        self.id = id
    }

    public var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    public func cancel() {
        let action: (() -> Void)?
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        action = cancelAction
        lock.unlock()
        action?()
    }

    public func setCancelAction(_ action: @escaping () -> Void) {
        var shouldCancelImmediately = false
        lock.lock()
        cancelAction = action
        shouldCancelImmediately = cancelled
        lock.unlock()
        if shouldCancelImmediately {
            action()
        }
    }

    public func clearCancelAction() {
        lock.lock()
        cancelAction = nil
        lock.unlock()
    }

    public func checkCancellation(operation: DicomDIMSEOperation) throws {
        guard !isCancelled else {
            throw DicomNetworkError.operationCancelled(operation.rawValue)
        }
    }
}

public struct DicomDIMSEAssociationPoolPolicy: Codable, Equatable, Sendable {
    public var maximumIdleServicesPerKey: Int
    public var idleTimeout: TimeInterval

    public init(maximumIdleServicesPerKey: Int = 2,
                idleTimeout: TimeInterval = 30) {
        self.maximumIdleServicesPerKey = max(1, maximumIdleServicesPerKey)
        self.idleTimeout = max(0, idleTimeout)
    }
}

public struct DicomDIMSEAssociationPoolKey: Codable, Equatable, Hashable, Sendable {
    public struct TLSMaterialKey: Codable, Equatable, Hashable, Sendable {
        public var certificatePath: String?
        public var privateKeyPath: String?
        public var privateKeyDataLength: Int?
        public var privateKeyDataFingerprint: String?
        public var pkcs12Fingerprint: String?
        public var pkcs12PasswordFingerprint: String?
        public var trustStorePath: String?
        public var trustedCertificatePaths: [String]

        public init(material: DicomTLSMaterial?) {
            pkcs12Fingerprint = material?.pkcs12Data.map(DicomDIMSEAssociationPoolKey.fingerprint)
            pkcs12PasswordFingerprint = material?.pkcs12Password.map {
                DicomDIMSEAssociationPoolKey.fingerprint(Data($0.utf8))
            }
            certificatePath = material?.certificatePath
            privateKeyPath = material?.privateKeyPath
            privateKeyDataLength = material?.privateKeyData?.count
            privateKeyDataFingerprint = material?.privateKeyData.map(DicomDIMSEAssociationPoolKey.fingerprint)
            trustStorePath = material?.trustStorePath
            trustedCertificatePaths = material?.trustedCertificatePaths ?? []
        }
    }

    public struct UserIdentityKey: Codable, Equatable, Hashable, Sendable {
        public var type: DicomUserIdentityType
        public var primaryFieldLength: Int
        public var primaryFieldFingerprint: String
        public var secondaryFieldLength: Int
        public var secondaryFieldFingerprint: String
        public var positiveResponseRequested: Bool

        public init(identity: DicomUserIdentity) {
            type = identity.type
            primaryFieldLength = identity.primaryField.count
            primaryFieldFingerprint = Self.fingerprint(identity.primaryField)
            secondaryFieldLength = identity.secondaryField.count
            secondaryFieldFingerprint = Self.fingerprint(identity.secondaryField)
            positiveResponseRequested = identity.positiveResponseRequested
        }

        private static func fingerprint(_ data: Data) -> String {
            DicomDIMSEAssociationPoolKey.fingerprint(data)
        }
    }

    public var host: String
    public var port: UInt16
    public var calledAETitle: String
    public var callingAETitle: String
    public var operationTimeouts: [TimeInterval]?
    public var timeout: TimeInterval
    public var maximumPDULength: UInt32
    public var transferSyntaxUIDs: [String]
    public var tlsMode: DicomTLSMode
    public var tlsServerName: String?
    public var tlsMaterial: TLSMaterialKey
    public var tlsSecurityProfile: DicomTLSSecurityProfile
    public var userIdentity: UserIdentityKey?
    public var retryPolicy: DicomNetworkRetryPolicy
    public var circuitBreakerPolicy: DicomCircuitBreakerPolicy?
    public var bandwidthLimitBytesPerSecond: Int?

    public init(configuration: DicomDIMSEConnectionConfiguration) {
        host = configuration.host
        port = configuration.port
        calledAETitle = configuration.calledAETitle
        callingAETitle = configuration.callingAETitle
        operationTimeouts = [configuration.connectTimeout, configuration.associationTimeout,
                             configuration.dimseResponseTimeout, configuration.releaseTimeout, configuration.cancelTimeout]
        timeout = configuration.timeout
        maximumPDULength = configuration.maximumPDULength
        transferSyntaxUIDs = configuration.transferSyntaxes.map(\.rawValue)
        tlsMode = configuration.tls.mode
        tlsServerName = configuration.tls.serverName
        tlsMaterial = TLSMaterialKey(material: configuration.tls.material)
        tlsSecurityProfile = configuration.tls.securityProfile
        userIdentity = configuration.userIdentity.map(UserIdentityKey.init(identity:))
        retryPolicy = configuration.retryPolicy
        circuitBreakerPolicy = configuration.circuitBreakerPolicy
        bandwidthLimitBytesPerSecond = configuration.bandwidthLimitBytesPerSecond
    }

    public var sanitizedHash: String {
        let userIdentityComponent: String
        if let userIdentity {
            userIdentityComponent = [
                String(userIdentity.type.rawValue),
                String(userIdentity.primaryFieldLength),
                userIdentity.primaryFieldFingerprint,
                String(userIdentity.secondaryFieldLength),
                userIdentity.secondaryFieldFingerprint,
                String(userIdentity.positiveResponseRequested)
            ].joined(separator: ":")
        } else {
            userIdentityComponent = ""
        }
        let circuitBreakerComponent: String
        if let circuitBreakerPolicy {
            circuitBreakerComponent = "\(circuitBreakerPolicy.failureThreshold):\(circuitBreakerPolicy.resetInterval)"
        } else {
            circuitBreakerComponent = ""
        }
        let bandwidthComponent = bandwidthLimitBytesPerSecond.map { String($0) } ?? ""
        let components = [
            host,
            String(port),
            calledAETitle,
            callingAETitle,
            String(timeout),
            operationTimeouts?.map { String($0) }.joined(separator: ",") ?? "",
            String(maximumPDULength),
            transferSyntaxUIDs.joined(separator: ","),
            tlsMode.rawValue,
            tlsServerName ?? "",
            tlsMaterial.certificatePath ?? "",
            tlsMaterial.privateKeyPath ?? "",
            tlsMaterial.privateKeyDataLength.map(String.init) ?? "",
            tlsMaterial.privateKeyDataFingerprint ?? "",
            tlsMaterial.pkcs12Fingerprint ?? "",
            tlsMaterial.pkcs12PasswordFingerprint ?? "",
            tlsMaterial.trustStorePath ?? "",
            tlsMaterial.trustedCertificatePaths.joined(separator: ","),
            tlsSecurityProfile.rawValue,
            userIdentityComponent,
            String(retryPolicy.maxAttempts),
            String(retryPolicy.retryDelay),
            circuitBreakerComponent,
            bandwidthComponent
        ]
        return Self.fingerprint(Data(components.joined(separator: "|").utf8))
    }

    private static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public struct DicomDIMSEAssociationPoolEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case created
        case reused
        case recycled
        case evicted
        case closedIdle
        case closedExplicit
        case failedAssociationEvicted
    }

    public var timestamp: Date
    public var kind: Kind
    public var keyHash: String
    public var host: String
    public var port: UInt16
    public var calledAETitle: String
    public var idleCount: Int
    public var reason: String?

    public init(timestamp: Date = Date(),
                kind: Kind,
                key: DicomDIMSEAssociationPoolKey,
                idleCount: Int,
                reason: String? = nil) {
        self.timestamp = timestamp
        self.kind = kind
        keyHash = key.sanitizedHash
        host = key.host
        port = key.port
        calledAETitle = key.calledAETitle
        self.idleCount = idleCount
        self.reason = reason
    }
}

public protocol DicomDIMSEAssociationPoolLogging: AnyObject, Sendable {
    func record(_ event: DicomDIMSEAssociationPoolEvent)
}

public final class DicomInMemoryAssociationPoolLog: DicomDIMSEAssociationPoolLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DicomDIMSEAssociationPoolEvent] = []

    public init() {}

    public func record(_ event: DicomDIMSEAssociationPoolEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    public var events: [DicomDIMSEAssociationPoolEvent] {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return snapshot
    }
}

final class DicomDIMSEPooledAssociationSession: @unchecked Sendable {
    let key: DicomDIMSEAssociationPoolKey
    let transport: DicomAssociationTransport
    let association: DicomAssociation
    let request: DicomAssociationRequest
    private let releaseTimeout: TimeInterval

    init(
        key: DicomDIMSEAssociationPoolKey,
        transport: DicomAssociationTransport,
        association: DicomAssociation,
        request: DicomAssociationRequest,
        releaseTimeout: TimeInterval
    ) {
        self.key = key
        self.transport = transport
        self.association = association
        self.request = request
        self.releaseTimeout = releaseTimeout
    }

    var isOpen: Bool { transport.isOpen }

    func close(gracefully: Bool = false) {
        if gracefully, transport.isOpen {
            try? release()
        } else {
            (transport as? DicomCancellableAssociationTransport)?.close()
        }
    }

    func release() throws {
        let deadline = DispatchTime.now() + max(0, releaseTimeout)
        // Closing a cancellable transport interrupts a blocked read or write, including a partial PDU.
        // The timer belongs to this retired session; it cannot close a later checkout's connection.
        let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timeout.setEventHandler { [self] in close() }
        timeout.schedule(deadline: deadline)
        timeout.resume()
        defer {
            timeout.cancel()
            close()
        }
        do {
            try transport.writePDU(DicomPDUCodec.encode(.releaseRequest))
            for _ in 0..<64 {
                guard DispatchTime.now() < deadline else {
                    throw DicomNetworkError.networkTimeout("releasing association")
                }
                let response = try DicomPDUCodec.decode(transport.readPDU())
                guard DispatchTime.now() < deadline else {
                    throw DicomNetworkError.networkTimeout("releasing association")
                }
                switch response {
                case .releaseResponse:
                    return
                case .pData:
                    continue
                case .releaseRequest:
                    try transport.writePDU(DicomPDUCodec.encode(.releaseResponse))
                case .abort(let abort):
                    throw DicomNetworkError.associationAborted(abort)
                default:
                    throw DicomNetworkError.unsupportedPDU(response.type)
                }
            }
            throw DicomNetworkError.networkUnavailable("A-RELEASE response limit exceeded.")
        } catch {
            if DispatchTime.now() >= deadline {
                throw DicomNetworkError.networkTimeout("releasing association")
            }
            throw error
        }
    }
}

final class DicomDIMSEAssociationLease: DicomCancellableAssociationTransport, @unchecked Sendable {
    private let pool: DicomDIMSEAssociationPool
    private let configuration: DicomDIMSEConnectionConfiguration
    private let transportFactory: () throws -> DicomAssociationTransport
    private let lock = NSLock()
    private var session: DicomDIMSEPooledAssociationSession?
    private var isCancelled = false
    private var isFinished = false

    init(
        pool: DicomDIMSEAssociationPool,
        configuration: DicomDIMSEConnectionConfiguration,
        transportFactory: @escaping () throws -> DicomAssociationTransport
    ) {
        self.pool = pool
        self.configuration = configuration
        self.transportFactory = transportFactory
    }

    var isOpen: Bool {
        lock.lock()
        let value = !isCancelled && !isFinished && (session?.isOpen ?? true)
        lock.unlock()
        return value
    }

    func association(for request: DicomAssociationRequest) throws -> DicomAssociation {
        lock.lock()
        if let session {
            let matches = session.request == request
            lock.unlock()
            guard matches else {
                throw DicomNetworkError.networkUnavailable(
                    "Pooled association lease received incompatible presentation contexts."
                )
            }
            return session.association
        }
        let unavailable = isCancelled || isFinished
        lock.unlock()
        guard !unavailable else {
            throw DicomNetworkError.networkUnavailable("Pooled association lease is no longer available.")
        }

        let checkedOut = try pool.checkoutSession(
            for: configuration,
            request: request,
            transportFactory: transportFactory
        )

        lock.lock()
        if isCancelled || isFinished {
            lock.unlock()
            pool.discardSession(
                checkedOut,
                error: DicomNetworkError.networkUnavailable("Pooled association lease closed during checkout.")
            )
            throw DicomNetworkError.networkUnavailable("Pooled association lease closed during checkout.")
        }
        session = checkedOut
        lock.unlock()
        return checkedOut.association
    }

    func writePDU(_ data: Data) throws {
        try activeSession().transport.writePDU(data)
    }

    func readPDU() throws -> Data {
        try activeSession().transport.readPDU()
    }

    func close() {
        let checkedOut = takeSession(cancelled: true)
        if let checkedOut {
            pool.discardSession(checkedOut, error: nil)
        }
    }

    func finish(reusable: Bool, error: Error?) throws {
        let checkedOut = takeSession(cancelled: false)
        guard let checkedOut else { return }
        if reusable, checkedOut.isOpen {
            pool.recycleSession(checkedOut, configuration: configuration)
        } else if error == nil {
            // A completed operation that cannot share its association (C-MOVE, C-GET) ends with A-RELEASE.
            try pool.releaseSession(checkedOut)
        } else {
            pool.discardSession(checkedOut, error: error)
        }
    }

    private func activeSession() throws -> DicomDIMSEPooledAssociationSession {
        lock.lock()
        let value = session
        let unavailable = isCancelled || isFinished
        lock.unlock()
        guard let value, !unavailable else {
            throw DicomNetworkError.networkUnavailable("Pooled association lease has no active session.")
        }
        return value
    }

    private func takeSession(cancelled: Bool) -> DicomDIMSEPooledAssociationSession? {
        lock.lock()
        if cancelled {
            isCancelled = true
        }
        isFinished = true
        let value = session
        session = nil
        lock.unlock()
        return value
    }
}

public final class DicomDIMSEAssociationPool: @unchecked Sendable {
    private struct Entry {
        var session: DicomDIMSEPooledAssociationSession
        var lastUsed: Date
    }

    public let policy: DicomDIMSEAssociationPoolPolicy
    private let logger: DicomDIMSEAssociationPoolLogging?
    private let transportFactory: ((DicomDIMSEConnectionConfiguration) throws -> DicomAssociationTransport)?

    private let lock = NSLock()
    private var entriesByKey: [DicomDIMSEAssociationPoolKey: [Entry]] = [:]
    /// Releases idle associations once they pass `policy.idleTimeout`, so a peer never drops them first.
    private let idleSweepQueue = DispatchQueue(label: "DicomDIMSEAssociationPool.idleSweep", qos: .utility)
    private var isIdleSweepScheduled = false

    public init(policy: DicomDIMSEAssociationPoolPolicy = DicomDIMSEAssociationPoolPolicy(),
                logger: DicomDIMSEAssociationPoolLogging? = nil) {
        self.policy = policy
        self.logger = logger
        self.transportFactory = nil
    }

    init(
        policy: DicomDIMSEAssociationPoolPolicy = DicomDIMSEAssociationPoolPolicy(),
        logger: DicomDIMSEAssociationPoolLogging? = nil,
        transportFactory: @escaping (DicomDIMSEConnectionConfiguration) throws -> DicomAssociationTransport
    ) {
        self.policy = policy
        self.logger = logger
        self.transportFactory = transportFactory
    }

    public func service(
        for configuration: DicomDIMSEConnectionConfiguration,
        auditLogger: DicomNetworkAuditLogging? = nil,
        circuitBreaker: DicomNetworkCircuitBreaker? = nil,
        operationHandle: DicomDIMSEOperationHandle? = nil,
        now _: Date = Date()
    ) -> DicomDIMSEServiceSCU {
        return DicomDIMSEServiceSCU(
            configuration: configuration,
            auditLogger: auditLogger,
            circuitBreaker: circuitBreaker,
            operationHandle: operationHandle,
            associationPool: self
        )
    }

    @available(*, deprecated, message: "Associations are recycled automatically after each pooled SCU operation.")
    public func recycle(_: DicomDIMSEServiceSCU, now _: Date = Date()) {}

    @available(*, deprecated, message: "Failed pooled associations are discarded automatically by the SCU.")
    public func discard(_: DicomDIMSEServiceSCU, error _: Error? = nil, now _: Date = Date()) {}

    public func idleCount(for configuration: DicomDIMSEConnectionConfiguration, now: Date = Date()) -> Int {
        _ = closeExpiredIdle(now: now)
        let key = Self.key(for: configuration)
        lock.lock()
        let count = entriesByKey[key]?.count ?? 0
        lock.unlock()
        return count
    }

    @discardableResult
    public func closeExpiredIdle(now: Date = Date()) -> Int {
        let sessions = takeExpiredIdle(now: now)
        sessions.forEach { $0.close(gracefully: true) }
        return sessions.count
    }

    private func takeExpiredIdle(now: Date) -> [DicomDIMSEPooledAssociationSession] {
        guard policy.idleTimeout > 0 else { return [] }
        lock.lock()
        var removedEntries: [Entry] = []
        for key in Array(entriesByKey.keys) {
            let entries = entriesByKey[key] ?? []
            let retained = entries.filter { entry in
                let shouldRetain = now.timeIntervalSince(entry.lastUsed) <= policy.idleTimeout
                if !shouldRetain {
                    removedEntries.append(entry)
                }
                return shouldRetain
            }
            if retained.isEmpty {
                entriesByKey.removeValue(forKey: key)
            } else {
                entriesByKey[key] = retained
            }
            for _ in 0..<(entries.count - retained.count) {
                recordLocked(kind: .closedIdle, key: key, idleCount: retained.count, now: now)
            }
        }
        lock.unlock()
        return removedEntries.map(\.session)
    }

    @discardableResult
    public func closeAll(now: Date = Date()) -> Int {
        lock.lock()
        var removedEntries: [Entry] = []
        for (key, entries) in entriesByKey {
            removedEntries.append(contentsOf: entries)
            for _ in entries {
                recordLocked(kind: .closedExplicit, key: key, idleCount: 0, now: now)
            }
        }
        entriesByKey.removeAll()
        lock.unlock()
        removedEntries.forEach { $0.session.close(gracefully: true) }
        return removedEntries.count
    }

    public static func key(for configuration: DicomDIMSEConnectionConfiguration) -> DicomDIMSEAssociationPoolKey {
        DicomDIMSEAssociationPoolKey(configuration: configuration)
    }

    func makeLease(
        for configuration: DicomDIMSEConnectionConfiguration,
        fallbackTransportFactory: @escaping () throws -> DicomAssociationTransport
    ) -> DicomDIMSEAssociationLease {
        let factory = transportFactory.map { configuredFactory in
            { try configuredFactory(configuration) }
        } ?? fallbackTransportFactory
        return DicomDIMSEAssociationLease(
            pool: self,
            configuration: configuration,
            transportFactory: factory
        )
    }

    func checkoutSession(
        for configuration: DicomDIMSEConnectionConfiguration,
        request: DicomAssociationRequest,
        transportFactory: () throws -> DicomAssociationTransport,
        now: Date = Date()
    ) throws -> DicomDIMSEPooledAssociationSession {
        let expiredSessions = takeExpiredIdle(now: now)
        if !expiredSessions.isEmpty {
            idleSweepQueue.async {
                expiredSessions.forEach { $0.close(gracefully: true) }
            }
        }
        let key = Self.key(for: configuration)
        lock.lock()
        var entries = entriesByKey[key] ?? []
        var deadEntries: [Entry] = []
        let initialIdleCount = entries.count
        entries.removeAll { entry in
            if entry.session.isOpen {
                return false
            }
            deadEntries.append(entry)
            recordLocked(
                kind: .failedAssociationEvicted,
                key: key,
                idleCount: max(0, initialIdleCount - deadEntries.count),
                now: now,
                reason: "livenessCheck"
            )
            return true
        }

        if let index = entries.firstIndex(where: { $0.session.request == request }) {
            let entry = entries.remove(at: index)
            if entries.isEmpty {
                entriesByKey.removeValue(forKey: key)
            } else {
                entriesByKey[key] = entries
            }
            recordLocked(kind: .reused, key: key, idleCount: entries.count, now: now)
            lock.unlock()
            deadEntries.forEach { $0.session.close() }
            return entry.session
        }

        if entries.isEmpty {
            entriesByKey.removeValue(forKey: key)
        } else {
            entriesByKey[key] = entries
        }
        recordLocked(kind: .created, key: key, idleCount: entries.count, now: now)
        lock.unlock()
        deadEntries.forEach { $0.session.close() }

        var openedTransport: DicomAssociationTransport?
        do {
            let transport = try transportFactory()
            openedTransport = transport
            let association = try DicomAssociationSCU(request: request).open(using: transport)
            return DicomDIMSEPooledAssociationSession(
                key: key,
                transport: transport,
                association: association,
                request: request,
                releaseTimeout: configuration.releaseTimeout
            )
        } catch {
            (openedTransport as? DicomCancellableAssociationTransport)?.close()
            lock.lock()
            recordLocked(
                kind: .failedAssociationEvicted,
                key: key,
                idleCount: entriesByKey[key]?.count ?? 0,
                now: now,
                reason: String(describing: type(of: error))
            )
            lock.unlock()
            throw error
        }
    }

    func recycleSession(
        _ session: DicomDIMSEPooledAssociationSession,
        configuration: DicomDIMSEConnectionConfiguration,
        now: Date = Date()
    ) {
        guard session.isOpen else {
            discardSession(session, error: nil, now: now)
            return
        }
        _ = closeExpiredIdle(now: now)
        let key = Self.key(for: configuration)
        lock.lock()
        var entries = entriesByKey[key] ?? []
        entries.insert(Entry(session: session, lastUsed: now), at: 0)
        let overflowCount = max(0, entries.count - policy.maximumIdleServicesPerKey)
        let overflow = overflowCount > 0 ? Array(entries.suffix(overflowCount)) : []
        if overflowCount > 0 {
            entries.removeLast(overflowCount)
            for _ in overflow {
                recordLocked(kind: .evicted, key: key, idleCount: entries.count, now: now)
            }
        }
        entriesByKey[key] = entries
        recordLocked(kind: .recycled, key: key, idleCount: entries.count, now: now)
        scheduleIdleSweepLocked(now: now)
        lock.unlock()
        overflow.forEach { $0.session.close(gracefully: true) }
    }

    func releaseSession(_ session: DicomDIMSEPooledAssociationSession, now: Date = Date()) throws {
        do {
            try session.release()
        } catch {
            discardSession(session, error: error, now: now)
            throw error
        }
        lock.lock()
        recordLocked(
            kind: .closedExplicit,
            key: session.key,
            idleCount: entriesByKey[session.key]?.count ?? 0,
            now: now,
            reason: "operationComplete"
        )
        lock.unlock()
    }

    /// Wakes when the oldest idle association expires; the sweep keeps the pool alive while any is idle.
    private func scheduleIdleSweepLocked(now: Date) {
        guard policy.idleTimeout > 0, !isIdleSweepScheduled,
              let oldest = entriesByKey.values.joined().map(\.lastUsed).min() else { return }
        isIdleSweepScheduled = true
        let delay = max(0, oldest.addingTimeInterval(policy.idleTimeout).timeIntervalSince(now)) + 0.05
        idleSweepQueue.asyncAfter(deadline: .now() + delay) {
            _ = self.closeExpiredIdle()
            self.lock.lock()
            self.isIdleSweepScheduled = false
            self.scheduleIdleSweepLocked(now: Date())
            self.lock.unlock()
        }
    }

    func discardSession(
        _ session: DicomDIMSEPooledAssociationSession,
        error: Error?,
        now: Date = Date()
    ) {
        session.close()
        lock.lock()
        recordLocked(
            kind: .failedAssociationEvicted,
            key: session.key,
            idleCount: entriesByKey[session.key]?.count ?? 0,
            now: now,
            reason: error.map { String(describing: type(of: $0)) }
        )
        lock.unlock()
    }

    private func recordLocked(kind: DicomDIMSEAssociationPoolEvent.Kind,
                              key: DicomDIMSEAssociationPoolKey,
                              idleCount: Int,
                              now: Date,
                              reason: String? = nil) {
        logger?.record(DicomDIMSEAssociationPoolEvent(
            timestamp: now,
            kind: kind,
            key: key,
            idleCount: idleCount,
            reason: reason
        ))
    }
}

public struct DicomNetworkRetryPolicy: Codable, Equatable, Hashable, Sendable {
    public var maxAttempts: Int
    public var retryDelay: TimeInterval

    public init(maxAttempts: Int = 1,
                retryDelay: TimeInterval = 0) {
        self.maxAttempts = max(1, maxAttempts)
        self.retryDelay = max(0, retryDelay)
    }

    public static let disabled = DicomNetworkRetryPolicy()
}

public struct DicomCircuitBreakerPolicy: Codable, Equatable, Hashable, Sendable {
    public var failureThreshold: Int
    public var resetInterval: TimeInterval

    public init(failureThreshold: Int = 3,
                resetInterval: TimeInterval = 30) {
        self.failureThreshold = max(1, failureThreshold)
        self.resetInterval = max(0, resetInterval)
    }
}

public final class DicomNetworkCircuitBreaker: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case closed
        case open(openedAt: Date)
        case halfOpen
    }

    public let policy: DicomCircuitBreakerPolicy
    private let lock = NSLock()
    private var failureCount = 0
    private var stateStorage: State = .closed

    public init(policy: DicomCircuitBreakerPolicy) {
        self.policy = policy
    }

    public var state: State {
        lock.lock()
        let value = stateStorage
        lock.unlock()
        return value
    }

    public func allowRequest(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch stateStorage {
        case .closed, .halfOpen:
            return true
        case .open(let openedAt):
            if now.timeIntervalSince(openedAt) >= policy.resetInterval {
                stateStorage = .halfOpen
                return true
            }
            return false
        }
    }

    public func recordSuccess() {
        lock.lock()
        failureCount = 0
        stateStorage = .closed
        lock.unlock()
    }

    public func recordFailure(now: Date = Date()) {
        lock.lock()
        failureCount += 1
        if failureCount >= policy.failureThreshold {
            stateStorage = .open(openedAt: now)
        }
        lock.unlock()
    }
}

public struct DicomNetworkAuditEvent: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case started
        case succeeded
        case failed
        case retrying
        case blocked
    }

    public var timestamp: Date
    public var operation: DicomDIMSEOperation
    public var outcome: Outcome
    public var host: String
    public var port: UInt16
    public var calledAETitle: String
    public var attempt: Int
    public var status: UInt16?
    public var errorDescription: String?

    public init(timestamp: Date = Date(),
                operation: DicomDIMSEOperation,
                outcome: Outcome,
                host: String,
                port: UInt16,
                calledAETitle: String,
                attempt: Int,
                status: UInt16? = nil,
                errorDescription: String? = nil) {
        self.timestamp = timestamp
        self.operation = operation
        self.outcome = outcome
        self.host = host
        self.port = port
        self.calledAETitle = calledAETitle
        self.attempt = attempt
        self.status = status
        self.errorDescription = errorDescription
    }
}

public protocol DicomNetworkAuditLogging: AnyObject, Sendable {
    func record(_ event: DicomNetworkAuditEvent)
}

public final class DicomInMemoryNetworkAuditLog: DicomNetworkAuditLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DicomNetworkAuditEvent] = []

    public init() {}

    public func record(_ event: DicomNetworkAuditEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    public var events: [DicomNetworkAuditEvent] {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return snapshot
    }
}

public final class DicomBandwidthLimitedTransport: DicomCancellableAssociationTransport {
    private let wrapped: DicomAssociationTransport
    private let bytesPerSecond: Int
    private let currentTime: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let throttleLock = NSLock()
    private var availableTokens: Double
    private var lastRefillTime: TimeInterval

    public var isOpen: Bool { wrapped.isOpen }

    public init(wrapping wrapped: DicomAssociationTransport,
                bytesPerSecond: Int) {
        self.wrapped = wrapped
        self.bytesPerSecond = max(1, bytesPerSecond)
        self.currentTime = { ProcessInfo.processInfo.systemUptime }
        self.sleep = { Thread.sleep(forTimeInterval: $0) }
        self.availableTokens = Double(max(1, bytesPerSecond))
        self.lastRefillTime = ProcessInfo.processInfo.systemUptime
    }

    init(
        wrapping wrapped: DicomAssociationTransport,
        bytesPerSecond: Int,
        currentTime: @escaping () -> TimeInterval,
        sleep: @escaping (TimeInterval) -> Void
    ) {
        self.wrapped = wrapped
        self.bytesPerSecond = max(1, bytesPerSecond)
        self.currentTime = currentTime
        self.sleep = sleep
        self.availableTokens = Double(max(1, bytesPerSecond))
        self.lastRefillTime = currentTime()
    }

    public func writePDU(_ data: Data) throws {
        throttle(byteCount: data.count)
        try wrapped.writePDU(data)
    }

    public func readPDU() throws -> Data {
        let data = try wrapped.readPDU()
        throttle(byteCount: data.count)
        return data
    }

    public func close() {
        (wrapped as? DicomCancellableAssociationTransport)?.close()
    }

    private func throttle(byteCount: Int) {
        guard byteCount > 0 else { return }

        throttleLock.lock()
        let now = currentTime()
        let refillStart = min(lastRefillTime, now)
        let elapsed = max(0, now - refillStart)
        let capacity = Double(bytesPerSecond)
        availableTokens = min(capacity, availableTokens + elapsed * capacity)

        let requestedTokens = Double(byteCount)
        let delay: TimeInterval
        if requestedTokens <= availableTokens {
            availableTokens -= requestedTokens
            lastRefillTime = now
            delay = 0
        } else {
            let deficit = requestedTokens - availableTokens
            delay = deficit / capacity
            availableTokens = 0
            lastRefillTime = now + delay
        }
        throttleLock.unlock()

        if delay > 0 {
            sleep(delay)
        }
    }
}

/// C-STORE replay is safe only for the same SOP Instance and representation. Retrieve replay may redeliver instances.
public enum DicomDIMSEReplaySafety: Equatable, Sendable {
    case requestNotSent
    case idempotent
    case outcomeUncertain

    public static func classify(operation: DicomDIMSEOperation, requestWasSent: Bool) -> Self {
        guard requestWasSent else { return .requestNotSent }
        switch operation {
        case .verification, .query, .modalityWorklist, .getRetrieve, .moveRetrieve, .store:
            return .idempotent
        case .mppsCreate, .mppsUpdate, .storageCommitmentReport, .storageCommitmentRequest, .printManagement, .workflowWrite:
            return .outcomeUncertain
        }
    }
}

extension DicomNetworkRetryPolicy {
    public func allowsReplay(_ safety: DicomDIMSEReplaySafety) -> Bool {
        safety != .outcomeUncertain
    }
}

/// Conservatively marks a request before socket submission, since a failed write may have sent a prefix.
final class DicomDIMSEReplayTrackingTransport: DicomCancellableAssociationTransport {
    let underlying: DicomAssociationTransport
    private let lock = NSLock()
    private var sent = false
    var requestWasSent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }
    var isOpen: Bool { underlying.isOpen }

    init(_ underlying: DicomAssociationTransport) { self.underlying = underlying }

    func writePDU(_ data: Data) throws {
        if data.first == DicomPDUType.pData.rawValue {
            lock.lock()
            sent = true
            lock.unlock()
        }
        try underlying.writePDU(data)
    }

    func readPDU() throws -> Data { try underlying.readPDU() }
    func close() { (underlying as? DicomCancellableAssociationTransport)?.close() }
}
