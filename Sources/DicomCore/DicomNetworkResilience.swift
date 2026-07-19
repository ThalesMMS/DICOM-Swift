import Foundation

public enum DicomTLSMode: String, Codable, Equatable, Hashable, Sendable {
    case disabled
    case enabled
}

public enum DicomTLSSecurityProfile: String, Codable, Equatable, Hashable, Sendable {
    case none
    case nonDowngradingBCP195
    case bcp195
    case extendedBCP195
    case basicRetired
    case aesRetired
    case authenticatedUnencryptedRetired
}

public struct DicomTLSMaterial: Codable, Equatable, Sendable {
    public var certificatePath: String?
    public var privateKeyPath: String?
    public var trustStorePath: String?
    public var trustedCertificatePaths: [String]

    public init(certificatePath: String? = nil,
                privateKeyPath: String? = nil,
                trustStorePath: String? = nil,
                trustedCertificatePaths: [String] = []) {
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
        self.trustStorePath = trustStorePath
        self.trustedCertificatePaths = trustedCertificatePaths
    }
}

public struct DicomTLSConfiguration: Codable, Equatable, Sendable {
    public var mode: DicomTLSMode
    public var serverName: String?
    public var material: DicomTLSMaterial?
    public var securityProfile: DicomTLSSecurityProfile

    public init(mode: DicomTLSMode = .disabled,
                serverName: String? = nil,
                material: DicomTLSMaterial? = nil,
                securityProfile: DicomTLSSecurityProfile = .none) {
        self.mode = mode
        self.serverName = serverName
        self.material = material
        self.securityProfile = securityProfile
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
        public var trustStorePath: String?
        public var trustedCertificatePaths: [String]

        public init(material: DicomTLSMaterial?) {
            certificatePath = material?.certificatePath
            privateKeyPath = material?.privateKeyPath
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
            String(maximumPDULength),
            transferSyntaxUIDs.joined(separator: ","),
            tlsMode.rawValue,
            tlsServerName ?? "",
            tlsMaterial.certificatePath ?? "",
            tlsMaterial.privateKeyPath ?? "",
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

    init(
        key: DicomDIMSEAssociationPoolKey,
        transport: DicomAssociationTransport,
        association: DicomAssociation,
        request: DicomAssociationRequest
    ) {
        self.key = key
        self.transport = transport
        self.association = association
        self.request = request
    }

    var isOpen: Bool { transport.isOpen }

    func close(gracefully: Bool = false) {
        if gracefully, transport.isOpen {
            do {
                try transport.writePDU(DicomPDUCodec.encode(.releaseRequest))
                let response = try DicomPDUCodec.decode(transport.readPDU())
                guard case .releaseResponse = response else {
                    throw DicomNetworkError.unsupportedPDU(response.type)
                }
            } catch {
                // The transport is closed below even when the peer cannot complete A-RELEASE.
            }
        }
        (transport as? DicomCancellableAssociationTransport)?.close()
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

    func finish(reusable: Bool, error: Error?) {
        let checkedOut = takeSession(cancelled: false)
        guard let checkedOut else { return }
        if reusable, checkedOut.isOpen {
            pool.recycleSession(checkedOut, configuration: configuration)
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
        guard policy.idleTimeout > 0 else { return 0 }
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
        removedEntries.forEach { $0.session.close(gracefully: true) }
        return removedEntries.count
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
        _ = closeExpiredIdle(now: now)
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
                request: request
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
        lock.unlock()
        overflow.forEach { $0.session.close(gracefully: true) }
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

public enum DicomUserIdentityType: UInt8, Codable, Equatable, Hashable, Sendable {
    case username = 1
    case usernameAndPasscode = 2
    case kerberos = 3
    case saml = 4
    case jwt = 5
}

public struct DicomUserIdentity: Codable, Equatable, Sendable {
    public var type: DicomUserIdentityType
    public var primaryField: Data
    public var secondaryField: Data
    public var positiveResponseRequested: Bool

    public init(type: DicomUserIdentityType,
                primaryField: Data,
                secondaryField: Data = Data(),
                positiveResponseRequested: Bool = false) {
        self.type = type
        self.primaryField = primaryField
        self.secondaryField = secondaryField
        self.positiveResponseRequested = positiveResponseRequested
    }

    public static func username(_ username: String,
                                positiveResponseRequested: Bool = false) -> DicomUserIdentity {
        DicomUserIdentity(type: .username,
                          primaryField: Data(username.utf8),
                          positiveResponseRequested: positiveResponseRequested)
    }

    public static func usernameAndPasscode(_ username: String,
                                           passcode: String,
                                           positiveResponseRequested: Bool = false) -> DicomUserIdentity {
        DicomUserIdentity(type: .usernameAndPasscode,
                          primaryField: Data(username.utf8),
                          secondaryField: Data(passcode.utf8),
                          positiveResponseRequested: positiveResponseRequested)
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
