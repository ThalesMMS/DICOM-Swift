import Foundation
#if canImport(Network)
import Network
#if canImport(Security)
import Security
#endif
#endif

#if canImport(Network)
/// `NWConnection` delivers callbacks on `queue`; the only transport-owned
/// mutable field, `isOpenStorage`, is serialized by `stateLock`. Per-operation
/// callback results use `DicomSynchronousResult`.
public final class DicomTCPAssociationTransport: DicomCancellableAssociationTransport, @unchecked Sendable {
    private static let hardMaximumIncomingPDUSize: UInt32 = 64 * 1_024 * 1_024
    /// The negotiated maximum length only bounds P-DATA-TF (PS3.8 §9.3.1);
    /// association and release PDUs get this fixed ceiling instead (issue #2791).
    static let maximumControlPDUSize = 1_024 * 1_024
    private static let pDataPDUType: UInt8 = 0x04

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "DicomTCPAssociationTransport")
    /// Only so a failure can say which peer it was talking to.
    private let host: String
    private let timeout: TimeInterval
    private var responseTimeout: TimeInterval
    private let associationTimeout: TimeInterval
    private let dimseResponseTimeout: TimeInterval
    private let releaseTimeout: TimeInterval
    private let maximumIncomingPDUSize: Int
    private let tlsContext: DicomAppliedTLSContext?
    private let tlsSetupError: Error?
    private let stateLock = NSLock()
    private var isOpenStorage = false

    public var isOpen: Bool {
        stateLock.lock()
        let value = isOpenStorage
        stateLock.unlock()
        return value
    }

    public init(host: String,
                port: UInt16,
                timeout: TimeInterval = 10,
                tls: DicomTLSConfiguration = .disabled,
                maximumIncomingPDUSize: UInt32 = 16_384,
                associationTimeout: TimeInterval? = nil,
                dimseResponseTimeout: TimeInterval? = nil,
                releaseTimeout: TimeInterval? = nil) {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 104
        let prepared: DicomPreparedNetworkParameters
        do {
            prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .client)
            tlsSetupError = nil
        } catch {
            prepared = DicomPreparedNetworkParameters(parameters: .tcp, tlsContext: nil)
            tlsSetupError = error
        }
        self.connection = NWConnection(host: NWEndpoint.Host(host),
                                       port: nwPort,
                                       using: prepared.parameters)
        self.host = host
        self.timeout = timeout
        self.responseTimeout = associationTimeout ?? timeout
        self.associationTimeout = associationTimeout ?? timeout
        self.dimseResponseTimeout = dimseResponseTimeout ?? timeout
        self.releaseTimeout = releaseTimeout ?? timeout
        self.maximumIncomingPDUSize = Self.resolvedIncomingPDUSize(maximumIncomingPDUSize)
        self.tlsContext = prepared.tlsContext
    }

    public init(acceptedConnection: NWConnection,
                timeout: TimeInterval = 10,
                maximumIncomingPDUSize: UInt32 = 16_384) {
        self.connection = acceptedConnection
        self.host = acceptedConnection.endpoint.debugDescription
        self.timeout = timeout
        self.responseTimeout = timeout
        self.associationTimeout = timeout
        self.dimseResponseTimeout = timeout
        self.releaseTimeout = timeout
        self.maximumIncomingPDUSize = Self.resolvedIncomingPDUSize(maximumIncomingPDUSize)
        self.tlsContext = nil
        self.tlsSetupError = nil
    }

    public func open() throws {
        if let tlsSetupError {
            throw tlsSetupError
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = DicomSynchronousResult<Void>()
        let host = self.host
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setIsOpen(true)
                if result.resolve(.success(())) {
                    semaphore.signal()
                }
            case .failed(let error):
                self?.setIsOpen(false)
                if result.resolve(.failure(Self.openFailure(from: error, host: host))) {
                    semaphore.signal()
                }
            case .waiting(let error):
                guard Self.isTerminalOpenWaitingError(error) else { break }
                self?.connection.cancel()
                self?.setIsOpen(false)
                if result.resolve(.failure(Self.openFailure(from: error, host: host))) {
                    semaphore.signal()
                }
            case .cancelled:
                self?.setIsOpen(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            setIsOpen(false)
            throw DicomNetworkError.networkTimeout("opening TCP connection")
        }
        try result.get()
    }

    static func isTerminalOpenWaitingError(_ error: NWError) -> Bool {
        switch error {
        case .tls:
            return true
        case .posix(let code):
            return code == .ECONNREFUSED
        default:
            return false
        }
    }

    /// Gives a TLS failure a name the layers above can act on.
    ///
    /// A bare `NWError` is opaque to every `switch` that follows: the callers'
    /// mappers key off `DicomNetworkError`, and anything else becomes a generic
    /// connection failure. `.tlsTrustEvaluationFailed` is a case they already
    /// translate into the app's own TLS error, which is how a refused
    /// certificate can be reported as a certificate problem rather than as a
    /// network one.
    ///
    /// Everything else keeps its own error: a POSIX refusal already reads as a
    /// refusal, and inventing a wrapper for it would only hide it.
    private static func openFailure(from error: NWError, host: String) -> Error {
        guard case .tls(let status) = error else { return error }
        return DicomNetworkError.tlsTrustEvaluationFailed(
            "TLS handshake with \(host) failed (status \(status))."
        )
    }

    public func startAcceptedConnection() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setIsOpen(true)
            case .failed, .cancelled:
                self?.setIsOpen(false)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func writePDU(_ data: Data) throws {
        stateLock.lock()
        switch data.first {
        case DicomPDUType.associationRequest.rawValue: responseTimeout = associationTimeout
        case DicomPDUType.pData.rawValue: responseTimeout = dimseResponseTimeout
        case DicomPDUType.releaseRequest.rawValue: responseTimeout = releaseTimeout
        default: break
        }
        stateLock.unlock()
        let semaphore = DispatchSemaphore(value: 0)
        let result = DicomSynchronousResult<Void>()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.setIsOpen(false)
                result.resolve(.failure(error))
            } else {
                result.resolve(.success(()))
            }
            semaphore.signal()
        })
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw DicomNetworkError.networkTimeout("writing PDU")
        }
        try result.get()
    }

    private var currentResponseTimeout: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return responseTimeout
    }

    public func readPDU() throws -> Data {
        let header = try readExact(count: 6)
        let length = try Self.validatedPDUBodyLength(
            from: header,
            maximumIncomingPDUSize: maximumIncomingPDUSize
        )
        var data = header
        data.append(try readExact(count: length))
        return data
    }

    static func validatedPDUBodyLength(
        from header: Data,
        maximumIncomingPDUSize: Int
    ) throws -> Int {
        guard header.count == 6 else {
            throw DicomNetworkError.invalidPDULength(expected: 6, actual: header.count)
        }
        let length = Int(header.dicomInteger(at: 2, as: UInt32.self, littleEndian: false))
        let limit = header[header.startIndex] == pDataPDUType ? maximumIncomingPDUSize : maximumControlPDUSize
        guard length <= limit else {
            throw DicomNetworkError.invalidPDULength(expected: limit, actual: length)
        }
        return length
    }

    private static func resolvedIncomingPDUSize(_ configuredSize: UInt32) -> Int {
        if configuredSize == 0 {
            return Int(hardMaximumIncomingPDUSize)
        }
        return Int(min(configuredSize, hardMaximumIncomingPDUSize))
    }

    public func close() {
        setIsOpen(false)
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }

    private func setIsOpen(_ value: Bool) {
        stateLock.lock()
        isOpenStorage = value
        stateLock.unlock()
    }

    private func readExact(count: Int) throws -> Data {
        try Self.readExact(count: count) { minimumIncompleteLength, maximumLength in
            try receive(
                minimumIncompleteLength: minimumIncompleteLength,
                maximumLength: maximumLength
            )
        }
    }

    static func readExact(
        count: Int,
        receive: (_ minimumIncompleteLength: Int, _ maximumLength: Int) throws -> Data
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            let remaining = count - data.count
            let chunk = try receive(remaining, remaining)
            guard !chunk.isEmpty else {
                throw DicomNetworkError.networkUnavailable("Peer closed the TCP connection.")
            }
            if data.isEmpty, chunk.count == count {
                return chunk
            }
            data.append(chunk)
        }
        return data
    }

    private func receive(minimumIncompleteLength: Int, maximumLength: Int) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let result = DicomSynchronousResult<Data>()
        connection.receive(minimumIncompleteLength: minimumIncompleteLength,
                           maximumLength: maximumLength) { [weak self] content, _, isComplete, error in
            if isComplete || error != nil {
                // The peer half-closed or the connection faulted. Record it even when this callback
                // still carries payload — a PACS routinely sends the final response and its FIN
                // together, and without this the association looks alive and gets recycled dead.
                self?.setIsOpen(false)
            }
            if let error {
                result.resolve(.failure(error))
            } else if let content, !content.isEmpty {
                result.resolve(.success(content))
            } else {
                result.resolve(.success(Data()))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + currentResponseTimeout) == .success else {
            throw DicomNetworkError.networkTimeout("reading PDU")
        }
        return try result.get() ?? Data()
    }
}
#endif
