import Foundation

/// When `DicomWebClient` repeats a request that failed for a reason that may pass. The default, `.none`, makes one
/// attempt, so a caller that already repeats requests does not multiply its own attempts.
///
/// - GET (search, metadata, retrieve, bulk data) repeats on HTTP 408, 429, 502, 503 and 504 and on a transient
///   connection failure. A streamed retrieve repeats only until its response headers arrive: a body already handed to
///   the sink is never fetched again.
/// - STOW-RS repeats a request only on 429 and 503, or when the connection failed before any byte of the answer
///   arrived; never after an answer began.
/// - Any other 4xx, TLS and authentication failures, and cancellation are never repeated.
///
/// Between attempts the client waits the server's `Retry-After`, given in seconds or as an HTTP date. A `Retry-After`
/// longer than `maximumRetryAfter` ends the attempts, and the error keeps it so the caller can schedule its own retry.
/// Without `Retry-After` the wait doubles from `initialBackoff` up to `maximumBackoff`, with random jitter.
/// Cancelling the task ends a wait at once.
public struct DicomWebRetryPolicy: Equatable, Sendable {
    /// One attempt, no repetition.
    public static let none = DicomWebRetryPolicy(maximumAttempts: 1)

    /// Attempts in all, the first included; 1 never repeats.
    public var maximumAttempts: Int
    /// The longest `Retry-After` the client waits, in seconds.
    public var maximumRetryAfter: TimeInterval
    /// The wait after the first failure without `Retry-After`, in seconds.
    public var initialBackoff: TimeInterval
    /// The longest wait without `Retry-After`, in seconds.
    public var maximumBackoff: TimeInterval

    public init(maximumAttempts: Int = 3, maximumRetryAfter: TimeInterval = 60,
                initialBackoff: TimeInterval = 1, maximumBackoff: TimeInterval = 30) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.maximumRetryAfter = max(0, maximumRetryAfter)
        self.initialBackoff = max(0, initialBackoff)
        self.maximumBackoff = max(0, maximumBackoff)
    }

    /// Which repetition rules a request follows.
    enum Request {
        /// GET: repeated on the transient statuses and connection failures.
        case idempotent
        /// STOW-RS: repeated only on 429 and 503 or when no answer arrived.
        case store
    }

    /// The seconds to wait before attempt `attempt + 1`, or nil when `error` ends the request.
    func delay(after error: Error, attempt: Int, for request: Request) -> TimeInterval? {
        guard attempt < maximumAttempts, Self.isTransient(error, for: request) else { return nil }
        if let retryAfter = (error as? DicomWebError)?.retryAfter {
            return retryAfter <= maximumRetryAfter ? retryAfter : nil
        }
        let backoff = min(maximumBackoff, initialBackoff * pow(2, Double(attempt - 1)))
        return backoff * Double.random(in: 0.5...1)
    }

    /// Whether `error` is one this policy repeats for `request`, whatever the attempt count.
    static func isTransient(_ error: Error, for request: Request) -> Bool {
        if let error = error as? DicomWebError {
            // `init(statusCode:)` files every status without a kind of its own under `.server`; the kinds made by the
            // client itself (invalid response, too large, origin denied) are never transient.
            guard error.kind == .server else { return false }
            return (request == .idempotent ? [408, 429, 502, 503, 504] : [429, 503]).contains(error.statusCode)
        }
        guard let error = error as? URLError else { return false }
        // The connection never got an answer. A timeout may mean the server is still working on an upload.
        let lost: Set<URLError.Code> = [.networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                                        .dnsLookupFailed, .notConnectedToInternet]
        return lost.contains(error.code) || (request == .idempotent && error.code == .timedOut)
    }
}
