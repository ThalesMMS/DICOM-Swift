import Foundation

public struct DicomWebOriginPolicy: Equatable, Sendable {
    public var configuredURL: URL
    public var allowedOrigins: Set<URL>

    public init(configuredURL: URL, allowedOrigins: Set<URL> = []) {
        self.configuredURL = configuredURL
        self.allowedOrigins = allowedOrigins
    }

    public func forwardsCredentials(to url: URL) -> Bool {
        Self.origin(url) == Self.origin(configuredURL)
    }

    public func resolve(_ reference: String, relativeTo base: URL? = nil) throws -> URL {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: reference, relativeTo: base ?? configuredURL)?.absoluteURL else {
            throw DicomWebError(kind: .originDenied)
        }
        try validate(url, from: base ?? configuredURL)
        return url
    }

    public func validate(_ url: URL, from source: URL? = nil) throws {
        guard let origin = Self.origin(url), url.user == nil, url.password == nil,
              (source ?? configuredURL).scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https",
              configuredURL.scheme?.lowercased() != "https" || url.scheme?.lowercased() == "https",
              origin == Self.origin(configuredURL) || allowedOrigins.contains(where: { Self.origin($0) == origin }) else {
            throw DicomWebError(kind: .originDenied)
        }
    }

    private static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}

/// Task delegate of a DICOMweb request (#2893). Redirects are refused, or followed only where the origin policy
/// allows, with credentials removed off the configured origin. HTTP authentication challenges are answered with no
/// credential, so shared credential storage is never consulted and the server's 401 reaches the caller; server trust
/// keeps the system evaluation. The created task is kept so a deadline can cancel it.
/// A body sent from a file or from segments is streamed; when URLSession must send it again (after an authentication
/// challenge or a redirect), the delegate reopens the file or reads the segments again from the start. Without a new stream URLSession keeps asking and the request only ends
/// at its timeout, so a STOW-RS answered with 401 would wait out the timeout instead of reporting the 401.
public final class DicomWebRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: DicomWebOriginPolicy
    let configuredHeaders: Set<String>
    let followsRedirects: Bool
    let bodyFileURL: URL?
    let streamedBody: DicomWebHTTPRequestBody?
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var deadlineFired = false

    public init(policy: DicomWebOriginPolicy, credentialHeaderNames: Set<String>, followsRedirects: Bool = true,
                bodyFileURL: URL? = nil) {
        self.policy = policy
        self.configuredHeaders = credentialHeaderNames
        self.followsRedirects = followsRedirects
        self.bodyFileURL = bodyFileURL
        self.streamedBody = nil
    }

    /// A delegate whose request sends `streamedBody`, read again from its start whenever URLSession needs it.
    public init(policy: DicomWebOriginPolicy, credentialHeaderNames: Set<String>, followsRedirects: Bool = true,
                bodyFileURL: URL? = nil, streamedBody: DicomWebHTTPRequestBody?) {
        self.policy = policy
        self.configuredHeaders = credentialHeaderNames
        self.followsRedirects = followsRedirects
        self.bodyFileURL = bodyFileURL
        self.streamedBody = streamedBody
    }

    /// Whether the deadline, not the caller, cancelled the task.
    public var didReachDeadline: Bool { lock.withLock { deadlineFired } }

    /// Cancels the task at `deadline`; the returned task is cancelled when the exchange ends first.
    public func enforce(deadline: Date?) -> Task<Void, Never>? {
        guard let deadline else { return nil }
        return Task { [weak self] in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            let task = self.lock.withLock { () -> URLSessionTask? in
                self.deadlineFired = true
                return self.task
            }
            task?.cancel()
        }
    }

    /// `error`, or a timeout when the deadline cancelled the task.
    public func mapping(_ error: Error) -> Error {
        didReachDeadline ? URLError(.timedOut) : error
    }

    public func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let fired = lock.withLock { () -> Bool in
            self.task = task
            return deadlineFired
        }
        if fired { task.cancel() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard followsRedirects, let url = request.url, (try? policy.validate(url, from: response.url)) != nil else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if !policy.forwardsCredentials(to: url) {
            for header in configuredHeaders.union(["authorization", "proxy-authorization", "cookie"]) {
                redirected.setValue(nil, forHTTPHeaderField: header)
            }
            redirected.httpShouldHandleCookies = false
        }
        completionHandler(redirected)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        completionHandler(streamedBody?.makeInputStream() ?? bodyFileURL.flatMap { InputStream(url: $0) })
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.rejectProtectionSpace, nil)
        }
    }
}
