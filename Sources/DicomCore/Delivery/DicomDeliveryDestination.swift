import Foundation

public enum DicomDeliveryAttemptResult: Sendable {
    case delivered(DicomDeliveryReceipt)
    case partial(DicomDeliveryReceipt)
    case failed(DicomDeliveryErrorClass, String, retryAfter: TimeInterval?)
    case uncertain(String)
}

public protocol DicomDeliveryDestination: Sendable {
    var id: String { get }
    var kind: DicomDeliveryDestinationKind { get }
    func deliver(_ item: DicomDeliveryItem, isCancelled: @Sendable () -> Bool) async -> DicomDeliveryAttemptResult
}

public struct DicomDIMSEStoreDestination: DicomDeliveryDestination {
    public let id: String
    public let kind = DicomDeliveryDestinationKind.dimseStore
    private let factory: @Sendable () throws -> DicomDIMSEServiceSCU
    public init(id: String, factory: @escaping @Sendable () throws -> DicomDIMSEServiceSCU) {
        self.id = id
        self.factory = factory
    }
    public func deliver(_ item: DicomDeliveryItem,
                        isCancelled: @Sendable () -> Bool) async -> DicomDeliveryAttemptResult {
        guard !isCancelled() else { return .failed(.cancelled, "Cancelled", retryAfter: nil) }
        guard item.destinationKind == kind, case .objects(let files) = item.payload, !files.isEmpty else {
            return .failed(.permanent, "C-STORE requires Part 10 files", retryAfter: nil)
        }
        // SCU performs blocking I/O: construct and execute it off the cooperative executor.
        let operation = DicomDIMSEOperationHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var progress: DicomDeliveryDIMSETransport?
                    do {
                        let requests = try files.map { try DicomStoreRequest(part10FileAt: $0) }
                        let supplied = try factory()
                        var configuration = supplied.configuration
                        configuration.retryPolicy = .disabled
                        let scu = DicomDIMSEServiceSCU(configuration: configuration, auditLogger: supplied.auditLogger,
                            circuitBreaker: supplied.circuitBreaker, operationHandle: operation, transportFactory: {
                                let transport = DicomDeliveryDIMSETransport(base: try supplied.makeTransport())
                                progress = transport
                                return transport
                            })
                        let results = try scu.store(requests: requests)
                        let objects = zip(requests, results).map { request, result -> DicomDeliveryReceipt.Object in
                            switch result {
                            case .success: return .init(sopInstanceUID: request.sopInstanceUID, accepted: true)
                            case .failure(let error):
                                return .init(sopInstanceUID: request.sopInstanceUID, accepted: false,
                                             reason: error.localizedDescription, errorClass: Self.classify(error))
                            }
                        }
                        let receipt = DicomDeliveryReceipt(perObject: objects)
                        if !objects.contains(where: \.accepted), let first = objects.first,
                           objects.allSatisfy({ $0.errorClass == first.errorClass }), let errorClass = first.errorClass {
                            continuation.resume(returning: .failed(errorClass, first.reason ?? "Batch refused", retryAfter: nil))
                            return
                        }
                        continuation.resume(returning: objects.allSatisfy(\.accepted) ? .delivered(receipt) : .partial(receipt))
                    } catch let error as DicomNetworkError {
                        var classification = Self.classify(error)
                        switch error {
                        case .networkTimeout:
                            classification = progress?.requestStarted == true ? .uncertain : .transient
                        case .networkUnavailable, .associationAborted:
                            if progress?.requestStarted == true { classification = .uncertain }
                        default: break
                        }
                        continuation.resume(returning: classification == .uncertain ? .uncertain(error.localizedDescription) :
                            .failed(classification, error.localizedDescription, retryAfter: nil))
                    } catch {
                        continuation.resume(returning: .failed(.permanent, String(describing: error), retryAfter: nil))
                    }
                }
            }
        } onCancel: { operation.cancel() }
    }
    static func classify(_ error: DicomNetworkError) -> DicomDeliveryErrorClass {
        switch error {
        // Batch SCU exposes no send-progress callback. A timeout cannot prove non-delivery.
        case .outcomeUncertain, .networkTimeout: return .uncertain
        case .networkUnavailable, .circuitBreakerOpen: return .transient
        case .operationCancelled: return .cancelled
        case .associationRejected, .presentationContextRejected, .missingAcceptedPresentationContext,
             .dimseStatusFailure, .transferSyntaxMismatch: return .rejectedByDestination
        default: return .permanent
        }
    }
}

public struct DicomSTOWDestination: DicomDeliveryDestination {
    public let id: String
    public let kind = DicomDeliveryDestinationKind.stowRS
    private let client: DicomWebClient
    private let transport: (any DicomWebHTTPTransport)?
    /// An opaque client does not expose response headers. Use configuration/transport to preserve Retry-After.
    public init(id: String, client: DicomWebClient) {
        self.id = id
        self.client = client
        transport = nil
    }
    public init(id: String, configuration: DicomWebClientConfiguration,
                transport: any DicomWebHTTPTransport = URLSessionDicomWebHTTPTransport.shared) {
        self.id = id
        client = DicomWebClient(configuration: configuration, transport: transport)
        self.transport = transport
    }
    public func deliver(_ item: DicomDeliveryItem,
                        isCancelled: @Sendable () -> Bool) async -> DicomDeliveryAttemptResult {
        guard !isCancelled() else { return .failed(.cancelled, "Cancelled", retryAfter: nil) }
        guard item.destinationKind == kind, case .objects(let files) = item.payload, !files.isEmpty else {
            return .failed(.permanent, "STOW requires Part 10 files", retryAfter: nil)
        }
        let observer = transport.map { DicomDeliveryHeaderTransport(base: $0) }
        var attemptClient = observer.map { DicomWebClient(configuration: client.configuration, transport: $0) } ?? client
        attemptClient.configuration.headers["Idempotency-Key"] = item.idempotencyKey
        attemptClient.configuration.headers["X-Isis-Idempotency-Key"] = item.idempotencyKey
        do {
            let requests = try files.map { try DicomStoreRequest(part10FileAt: $0) }
            let result = try await attemptClient.storeInstances(files: files)
            let responses = result.storeResponse?.instances ?? []
            var objects: [DicomDeliveryReceipt.Object] = []
            for request in requests {
                let matches = responses.filter { $0.sopInstanceUID == request.sopInstanceUID }
                guard matches.count == 1, let response = matches.first, response.outcome != .unknown else {
                    return .uncertain("STOW omitted an unambiguous instance outcome")
                }
                let accepted = response.outcome == .accepted || response.outcome == .warning
                let code = response.failureReason
                let errorClass: DicomDeliveryErrorClass? = accepted ? nil :
                    (code.map { $0 & 0xFF00 == 0xA700 } == true ? .transient : .rejectedByDestination)
                objects.append(.init(sopInstanceUID: request.sopInstanceUID, accepted: accepted,
                    reason: code.map { String(format: "0x%04X", $0) }, errorClass: errorClass))
            }
            let receipt = DicomDeliveryReceipt(remoteReference: result.storeResponse?.retrieveURL,
                status: String(result.statusCode), perObject: objects)
            return objects.allSatisfy(\.accepted) ? .delivered(receipt) : .partial(receipt)
        } catch let error as DicomWebError {
            return .failed(Self.classify(status: error.statusCode), error.localizedDescription, retryAfter: observer?.retryAfter)
        } catch let error as DicomWebClientError {
            if case .httpStatus(let code, _, _, _) = error {
                return .failed(Self.classify(status: code), error.localizedDescription, retryAfter: observer?.retryAfter)
            }
            return .failed(.permanent, error.localizedDescription, retryAfter: nil)
        } catch is CancellationError { return .failed(.cancelled, "Cancelled", retryAfter: nil) }
        catch let error as URLError {
            if [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code) {
                return .failed(.transient, error.localizedDescription, retryAfter: nil)
            }
            return .uncertain(error.localizedDescription)
        } catch { return .failed(.permanent, String(describing: error), retryAfter: nil) }
    }
    static func classify(status: Int) -> DicomDeliveryErrorClass {
        [408, 425, 429].contains(status) || (500...599).contains(status) ? .transient : .rejectedByDestination
    }
}

public struct DicomWebhookDestination: DicomDeliveryDestination {
    public let id: String
    public let kind = DicomDeliveryDestinationKind.webhook
    private let url: URL
    private let transport: any DicomWebHTTPTransport
    private let policy: DicomWebhookTargetPolicy
    private let signer: DicomWebhookSigner
    public init(id: String, url: URL, transport: any DicomWebHTTPTransport = DicomWebhookURLSessionTransport(),
                policy: DicomWebhookTargetPolicy, signer: DicomWebhookSigner) {
        self.id = id
        self.url = url
        self.transport = transport
        self.policy = policy
        self.signer = signer
    }
    public func deliver(_ item: DicomDeliveryItem,
                        isCancelled: @Sendable () -> Bool) async -> DicomDeliveryAttemptResult {
        guard !isCancelled() else { return .failed(.cancelled, "Cancelled", retryAfter: nil) }
        guard item.destinationKind == kind, case .event(let event) = item.payload else {
            return .failed(.permanent, "Webhook requires an event", retryAfter: nil)
        }
        let observer = DicomDeliveryHeaderTransport(base: transport)
        let client = DicomWebhookDeliveryClient(transport: observer, policy: policy, signer: signer)
        do {
            switch try await client.deliver(event: event, to: url, idempotencyKey: item.idempotencyKey) {
            case .delivered(let status): return .delivered(.init(status: String(status)))
            case .uncertain(let message): return .uncertain(message)
            case .transient(let reason, let retry):
                return .failed(.transient, String(describing: reason), retryAfter: observer.retryAfter ?? retry)
            case .rejected(let reason):
                return .failed(observer.signatureRejected ? .signatureRejected : .rejectedByDestination,
                               String(describing: reason), retryAfter: nil)
            }
        } catch { return .failed(.permanent, String(describing: error), retryAfter: nil) }
    }
}

private final class DicomDeliveryHeaderTransport: DicomWebHTTPTransport, @unchecked Sendable {
    let base: any DicomWebHTTPTransport
    private let lock = NSLock()
    private var rejected = false
    private var delay: TimeInterval?
    init(base: any DicomWebHTTPTransport) { self.base = base }
    var signatureRejected: Bool { lock.withLock { rejected } }
    var retryAfter: TimeInterval? { lock.withLock { delay } }
    private func observe(_ status: Int, _ headers: [String: String]) {
        lock.withLock {
            if let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value {
                if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { delay = seconds }
                else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    delay = formatter.date(from: raw).map { max(0, $0.timeIntervalSinceNow) }
                }
            }
            rejected = [401, 403].contains(status) && headers.keys.contains {
                $0.lowercased() == "x-isis-signature-error"
            }
        }
    }
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        let response = try await base.send(request)
        observe(response.statusCode, response.headers)
        return response
    }
    func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        let response = try await base.stream(request)
        observe(response.statusCode, response.headers)
        return response
    }
}

/// Tracks request submission conservatively: even a failed P-DATA write may have sent a prefix.
private final class DicomDeliveryDIMSETransport: DicomCancellableAssociationTransport {
    let base: DicomAssociationTransport
    private(set) var requestStarted = false
    init(base: DicomAssociationTransport) { self.base = base }
    var isOpen: Bool { base.isOpen }
    func writePDU(_ data: Data) throws {
        if data.first == DicomPDUType.pData.rawValue { requestStarted = true }
        try base.writePDU(data)
    }
    func readPDU() throws -> Data { try base.readPDU() }
    func close() { (base as? DicomCancellableAssociationTransport)?.close() }
}
