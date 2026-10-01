import DicomCore
import Foundation

/// Loopback-only diagnostic receiver. It records delivery attempts, not exactly-once processing.
public final class DicomWebhookReceiver: Sendable {
    public enum Behavior: Sendable {
        case respond(Int)
        case delay(TimeInterval, thenStatus: Int)
        case redirect(to: URL)
        case dropConnection
        case respondThenDuplicateOK
    }
    public struct Receipt: Sendable {
        public let headers: [String: String]
        public let body: Data
        public let verified: Bool
        public let error: String?
        public var phiIncluded: Bool {
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
            return object["phi"] != nil && !(object["phi"] is NSNull)
        }
    }

    private let state: State
    private let listener: DicomWebHTTPListener
    public var received: [Receipt] { state.received }

    public init(verifier: DicomWebhookVerifier, port: UInt16 = 0, behaviors: [Behavior] = [],
                onReceipt: @escaping @Sendable (Receipt) -> Void = { _ in }) {
        let state = State(verifier: verifier, behaviors: behaviors, onReceipt: onReceipt)
        self.state = state
        var configuration = DicomWebHTTPListenerConfiguration()
        configuration.port = port
        configuration.maximumBodyBytes = 1024 * 1024
        listener = DicomWebHTTPListener(configuration: configuration) { request, stream in
            await state.handle(request, stream: stream)
        }
    }

    public func start() async throws -> URL { try await listener.start() }
    public func stop() async { await listener.stop() }

    private final class State: @unchecked Sendable {
        let verifier: DicomWebhookVerifier
        let behaviors: [Behavior]
        let onReceipt: @Sendable (Receipt) -> Void
        private let lock = NSLock()
        private var receipts = [Receipt]()
        private var nextIndex = 0
        private var duplicateKeys = Set<String>()
        var received: [Receipt] { lock.withLock { receipts } }

        init(verifier: DicomWebhookVerifier, behaviors: [Behavior], onReceipt: @escaping @Sendable (Receipt) -> Void) {
            self.verifier = verifier
            self.behaviors = behaviors
            self.onReceipt = onReceipt
        }

        func handle(_ request: DicomWebHTTPRequest,
                    stream: AsyncThrowingStream<Data, Error>) async -> DicomWebHTTPStreamedResponse {
            let index = lock.withLock { let index = nextIndex; nextIndex += 1; return index }
            var body = Data()
            var errorMessage: String?
            do {
                for try await chunk in stream { body.append(chunk) }
                guard request.method == .post else { throw DicomWebhookDeliveryError.invalidConfiguration }
                let header = request.headers.first { $0.key.lowercased() == "x-isis-signature" }?.value ?? ""
                try await verifier.verify(header: header, body: body)
            } catch { errorMessage = String(describing: error) }
            let receipt = Receipt(headers: request.headers, body: body, verified: errorMessage == nil, error: errorMessage)
            lock.withLock { receipts.append(receipt) }
            onReceipt(receipt)
            let behavior = index < behaviors.count ? behaviors[index] : .respond(200)
            let idempotencyKey = request.headers.first { $0.key.lowercased() == "x-isis-idempotency-key" }?.value
            // This scripted mode deliberately acknowledges a duplicate even if nonce verification rejects it.
            let duplicateOK = lock.withLock { idempotencyKey.map { duplicateKeys.remove($0) != nil } ?? false }
            if duplicateOK { return response(200) }
            guard receipt.verified else { return response(401) }
            switch behavior {
            case .respond(let status): return response(status)
            case .delay(let seconds, let status):
                if seconds.isFinite && seconds > 0 {
                    do { try await Task.sleep(for: .seconds(seconds)) }
                    catch { return response(status) }
                }
                return response(status)
            case .redirect(let url): return response(307, headers: ["Location": url.absoluteString])
            case .dropConnection:
                // Listener checks cancellation before writing response bytes, then closes this connection.
                withUnsafeCurrentTask { $0?.cancel() }
                return response(200)
            case .respondThenDuplicateOK:
                if let idempotencyKey { _ = lock.withLock { duplicateKeys.insert(idempotencyKey) } }
                return response(200)
            }
        }

        private func response(_ status: Int, headers: [String: String] = [:]) -> DicomWebHTTPStreamedResponse {
            .init(statusCode: status, headers: headers, body: AsyncThrowingStream { $0.finish() })
        }
    }
}
