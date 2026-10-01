import Foundation

public enum DicomStorageSCPPressureReason: String, Codable, Equatable, Sendable {
    case associationLimit
    case peerConnectionLimit
    case storeRequestLimit
    case stagedByteLimit
    case associationObjectLimit
    case associationByteLimit
    case insufficientStorage
    case shuttingDown
}

public enum DicomStorageSCPListenerFault: Equatable, Sendable {
    case portUnavailable(String)
    case tlsConfiguration(String)
    case workerTerminated(String)
}

public struct DicomStorageSCPMetrics: Equatable, Sendable {
    public var activeAssociations: Int
    public var queuedAssociations: Int
    public var admittedAssociations: Int
    public var rejectedAssociations: Int
    public var inFlightStoreRequests: Int
    public var outstandingOperations: Int
    public var stagedBytes: Int64
    public var recentFailureCount: Int
    public var lastActivity: Date?
    public var listenerFault: DicomStorageSCPListenerFault?

    public init(
        activeAssociations: Int = 0,
        queuedAssociations: Int = 0,
        admittedAssociations: Int = 0,
        rejectedAssociations: Int = 0,
        inFlightStoreRequests: Int = 0,
        outstandingOperations: Int = 0,
        stagedBytes: Int64 = 0,
        recentFailureCount: Int = 0,
        lastActivity: Date? = nil,
        listenerFault: DicomStorageSCPListenerFault? = nil
    ) {
        self.activeAssociations = activeAssociations
        self.queuedAssociations = queuedAssociations
        self.admittedAssociations = admittedAssociations
        self.rejectedAssociations = rejectedAssociations
        self.outstandingOperations = outstandingOperations
        self.inFlightStoreRequests = inFlightStoreRequests
        self.stagedBytes = stagedBytes
        self.recentFailureCount = recentFailureCount
        self.lastActivity = lastActivity
        self.listenerFault = listenerFault
    }
}

public protocol DicomStoragePreflightChecking: Sendable {
    func checkStorageAvailability(requiredBytes: Int64) throws
}

public struct DicomFileStoragePreflight: DicomStoragePreflightChecking {
    public let directoryURL: URL
    public let reserveBytes: Int64

    public init(directoryURL: URL, reserveBytes: Int64 = 64 * 1_024 * 1_024) {
        self.directoryURL = directoryURL
        self.reserveBytes = reserveBytes
    }

    public func checkStorageAvailability(requiredBytes: Int64) throws {
        let values = try directoryURL.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        guard requiredBytes >= 0,
              let available = values.volumeAvailableCapacityForImportantUsage
                ?? values.volumeAvailableCapacity.map(Int64.init),
              available >= reserveBytes,
              requiredBytes <= available - reserveBytes else {
            throw DicomStorageSCPAdmissionError.insufficientStorage(requiredBytes: requiredBytes)
        }
    }
}

public struct NoopDicomStoragePreflight: DicomStoragePreflightChecking {
    public init() {}
    public func checkStorageAvailability(requiredBytes: Int64) throws {}
}

public enum DicomStorageSCPAdmissionError: LocalizedError, Equatable, Sendable {
    case refused(DicomStorageSCPPressureReason)
    case messageTooLarge(limit: Int64)
    case insufficientStorage(requiredBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .refused(let reason):
            return "Storage SCP refused work because the \(reason.rawValue) limit was reached."
        case .messageTooLarge(let limit):
            return "The incoming DICOM object exceeds the \(limit)-byte receive limit."
        case .insufficientStorage(let requiredBytes):
            return "The Storage SCP does not have reserved capacity for a \(requiredBytes)-byte object."
        }
    }
}

public final class DicomStorageSCPResourceGovernor: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: DicomStorageSCPConfiguration
    private var metrics = DicomStorageSCPMetrics()
    private var activePeers: [String: Int] = [:]
    private var accepting = true

    public init(configuration: DicomStorageSCPConfiguration) {
        self.configuration = configuration
    }

    func admitAssociation(peer: String) -> DicomStorageSCPPressureReason? {
        lock.withLock {
            guard accepting else { return .shuttingDown }
            guard metrics.activeAssociations < configuration.maximumConcurrentAssociations else {
                rejectLocked()
                return .associationLimit
            }
            guard activePeers[peer, default: 0] < configuration.maximumConnectionsPerPeer else {
                rejectLocked()
                return .peerConnectionLimit
            }
            metrics.activeAssociations += 1
            metrics.admittedAssociations += 1
            metrics.lastActivity = Date()
            activePeers[peer, default: 0] += 1
            return nil
        }
    }

    func releaseAssociation(peer: String) {
        lock.withLock {
            metrics.activeAssociations = max(0, metrics.activeAssociations - 1)
            if let count = activePeers[peer], count > 1 {
                activePeers[peer] = count - 1
            } else {
                activePeers.removeValue(forKey: peer)
            }
            metrics.lastActivity = Date()
        }
    }

    func beginOperation(limit: Int) -> Bool {
        lock.withLock {
            guard accepting, metrics.outstandingOperations < limit else { return false }
            metrics.outstandingOperations += 1
            metrics.lastActivity = Date()
            return true
        }
    }

    func endOperation() {
        lock.withLock {
            metrics.outstandingOperations = max(0, metrics.outstandingOperations - 1)
            metrics.lastActivity = Date()
        }
    }

    func beginStore() -> DicomStorageSCPPressureReason? {
        lock.withLock {
            guard accepting else { return .shuttingDown }
            guard metrics.inFlightStoreRequests < configuration.maximumInFlightStoreRequests else {
                return .storeRequestLimit
            }
            metrics.inFlightStoreRequests += 1
            metrics.lastActivity = Date()
            return nil
        }
    }

    func endStore() {
        lock.withLock {
            metrics.inFlightStoreRequests = max(0, metrics.inFlightStoreRequests - 1)
            metrics.lastActivity = Date()
        }
    }

    func reserveStagedBytes(_ bytes: Int64) -> Bool {
        lock.withLock {
            guard bytes >= 0, metrics.stagedBytes <= configuration.maximumStagedBytes - bytes else {
                return false
            }
            metrics.stagedBytes += bytes
            metrics.lastActivity = Date()
            return true
        }
    }

    func releaseStagedBytes(_ bytes: Int64) {
        lock.withLock {
            metrics.stagedBytes = max(0, metrics.stagedBytes - bytes)
            metrics.lastActivity = Date()
        }
    }

    /// Serialize capacity checks and writes across associations sharing this governor.
    func appendReceivedFragment(_ fragment: Data, to file: DicomReceivedPart10File,
                                preflight: any DicomStoragePreflightChecking) throws {
        try lock.withLock {
            try preflight.checkStorageAvailability(requiredBytes: Int64(fragment.count))
            try file.append(fragment)
        }
    }

    func recordFailure() {
        lock.withLock { failureLocked() }
    }

    func stopAccepting() {
        lock.withLock {
            accepting = false
            metrics.lastActivity = Date()
        }
    }

    func setFault(_ fault: DicomStorageSCPListenerFault) {
        lock.withLock {
            metrics.listenerFault = fault
            failureLocked()
        }
    }

    func snapshot() -> DicomStorageSCPMetrics {
        lock.withLock { metrics }
    }

    private func rejectLocked() {
        metrics.rejectedAssociations += 1
        failureLocked()
    }

    private func failureLocked() {
        metrics.recentFailureCount += 1
        metrics.lastActivity = Date()
    }
}


extension DicomFileStoragePreflight: DicomIngestDiskCapacityChecking {
    public func checkCapacity(required: Int64, at root: URL) throws {
        do { try checkStorageAvailability(requiredBytes: required) }
        catch is DicomStorageSCPAdmissionError { throw DicomIngestError.diskFull(required: required, available: nil) }
        catch { throw DicomIngestError.mapped(error, path: root, required: required) }
    }
}
