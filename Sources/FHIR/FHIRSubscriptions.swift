import DicomCore
import DicomWebHTTP
import Foundation

/// Client-side R4 `Subscription` lifecycle (rest-hook channel) with bounded status polling.
public struct FHIRSubscriptionManager: Sendable {
    public let client: FHIRClient
    public init(client: FHIRClient) { self.client = client }

    public func create(criteria: String, endpoint: String, headers: [String] = [], payload: String = "application/fhir+json",
                       reason: String = "Isis subscription", end: String? = nil) async throws -> FHIRResult<FHIRSubscription> {
        let subscription = FHIRSubscription(criteria: criteria, endpoint: endpoint, payload: payload, headers: headers, reason: reason, end: end)
        switch try await client.create(subscription.resource) {
        case .failure(let failure): return .failure(failure)
        case .success(let resource, let metadata):
            guard let created = resource?.as(FHIRSubscription.self) else {
                return .failure(.init(reason: .malformedResponse, status: metadata.status, message: "server did not return the Subscription"))
            }
            return .success(created, metadata)
        }
    }

    public func status(id: String) async throws -> FHIRResult<FHIRSubscription> {
        switch try await client.read("Subscription", id: id) {
        case .failure(let failure): return .failure(failure)
        case .success(let resource, let metadata):
            guard let subscription = resource?.as(FHIRSubscription.self) else {
                return .failure(.init(reason: .malformedResponse, status: metadata.status, message: "not a Subscription"))
            }
            return .success(subscription, metadata)
        }
    }

    /// Polls at most `maxPolls` times; returns the last observed state (active, error or still requested).
    public func waitUntilActive(id: String, maxPolls: Int = 10, interval: Duration = .milliseconds(200)) async throws -> FHIRResult<FHIRSubscription> {
        var last: FHIRResult<FHIRSubscription> = .failure(.init(reason: .invalidRequest, message: "no poll executed"))
        for attempt in 0..<max(1, maxPolls) {
            last = try await status(id: id)
            guard case .success(let subscription, _) = last else { return last }
            if subscription.status == "active" || subscription.status == "error" || subscription.status == "off" { return last }
            if attempt + 1 < maxPolls { try await Task.sleep(for: interval) }
        }
        return last
    }

    public func cancel(id: String) async throws -> FHIRResult<FHIROperationOutcome?> {
        try await client.delete("Subscription", id: id)
    }
}

public struct FHIRRestHookNotification: Sendable {
    public let receivedAt: Date
    public let method: String
    public let path: String
    public let contentType: String?
    /// Present for `payload` subscriptions; empty pings carry no body.
    public let resource: FHIRResource?
    public let bodyBytes: Int
}

/// Loopback rest-hook receiver on the shared HTTP listener. Notifications must carry the configured
/// shared-secret header; bodies are bounded and parsed with the safe parsers. Nothing is ever fetched
/// back from the server automatically.
public final class FHIRRestHookReceiver: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var secretHeader: (name: String, value: String)
        public var maximumBodyBytes: Int
        public var limits: FHIRLimits
        public var tls: DicomTLSConfiguration?
        public init(secretHeader: (name: String, value: String), maximumBodyBytes: Int = 4 * 1024 * 1024,
                    limits: FHIRLimits = FHIRLimits(), tls: DicomTLSConfiguration? = nil) {
            self.secretHeader = secretHeader
            self.maximumBodyBytes = maximumBodyBytes
            self.limits = limits
            self.tls = tls
        }
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var received: [FHIRRestHookNotification] = []
    private var rejected = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var listener: DicomWebHTTPListener?

    public init(configuration: Configuration) { self.configuration = configuration }

    public var notifications: [FHIRRestHookNotification] { lock.withLock { received } }
    public var rejectedCount: Int { lock.withLock { rejected } }

    public func start() async throws -> URL {
        var listenerConfiguration = DicomWebHTTPListenerConfiguration()
        listenerConfiguration.tls = configuration.tls
        listenerConfiguration.maximumBodyBytes = configuration.maximumBodyBytes
        let listener = DicomWebHTTPListener(configuration: listenerConfiguration) { [weak self] request, stream in
            guard let self else { return Self.response(500) }
            return await self.handle(request, stream)
        }
        lock.withLock { self.listener = listener }
        return try await listener.start()
    }

    public func stop() async {
        let listener = lock.withLock { self.listener }
        await listener?.stop()
    }

    /// Waits until at least `count` notifications arrived or the timeout elapsed.
    public func waitForNotifications(count: Int, timeout: Duration) async -> [FHIRRestHookNotification] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = notifications
            if current.count >= count { return current }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return notifications
    }

    private func handle(_ request: DicomWebHTTPRequest, _ stream: AsyncThrowingStream<Data, Error>) async -> DicomWebHTTPStreamedResponse {
        guard request.method == .post || request.method == .put else { return Self.response(405) }
        let header = request.headers.first { $0.key.lowercased() == configuration.secretHeader.name.lowercased() }?.value
        guard header == configuration.secretHeader.value else {
            lock.withLock { rejected += 1 }
            return Self.response(401)
        }
        var body = Data()
        do {
            for try await chunk in stream {
                guard body.count + chunk.count <= configuration.maximumBodyBytes else { return Self.response(413) }
                body.append(chunk)
            }
        } catch { return Self.response(400) }
        if body.isEmpty, let direct = request.body { body = direct }
        let contentType = request.headers.first { $0.key.lowercased() == "content-type" }?.value
        var resource: FHIRResource?
        if !body.isEmpty {
            do {
                resource = (contentType?.lowercased().contains("xml") ?? false)
                    ? try FHIRResource(xmlData: body, limits: configuration.limits)
                    : try FHIRResource(jsonData: body, limits: configuration.limits)
            } catch { return Self.response(400) }
        }
        let notification = FHIRRestHookNotification(receivedAt: Date(), method: request.method.rawValue, path: request.url.path,
                                                    contentType: contentType, resource: resource, bodyBytes: body.count)
        lock.withLock { received.append(notification) }
        return Self.response(200)
    }

    private static func response(_ status: Int) -> DicomWebHTTPStreamedResponse {
        .init(statusCode: status, headers: ["Content-Length": "0"], body: AsyncThrowingStream { $0.finish() })
    }
}
