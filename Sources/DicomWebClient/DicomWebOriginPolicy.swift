import Foundation

public struct DicomWebOriginPolicy: Equatable, Sendable {
    public var configuredURL: URL
    public var allowedOrigins: Set<URL>
    /// How HTTPS servers of the origins this policy allows are trusted. The default is the system's evaluation.
    public var serverTrust = DicomWebServerTrust.system
    /// The certificate presented when the configured origin asks for one; no other origin ever receives it.
    public var clientIdentity: DicomWebClientIdentity? = nil

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

    /// Whether a TLS challenge comes from the configured origin.
    func isConfiguredOrigin(_ space: URLProtectionSpace) -> Bool {
        Self.origin(space).map { $0 == Self.origin(configuredURL) } ?? false
    }

    /// Whether a TLS challenge comes from an origin this policy lets requests reach.
    func allowsOrigin(_ space: URLProtectionSpace) -> Bool {
        guard let origin = Self.origin(space) else { return false }
        return origin == Self.origin(configuredURL) || allowedOrigins.contains(where: { Self.origin($0) == origin })
    }

    private static func origin(_ url: URL) -> String? {
        origin(scheme: url.scheme, host: url.host, port: url.port)
    }

    private static func origin(_ space: URLProtectionSpace) -> String? {
        origin(scheme: space.protocol, host: space.host, port: space.port > 0 ? space.port : nil)
    }

    private static func origin(scheme: String?, host: String?, port: Int?) -> String? {
        guard let scheme = scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(port ?? (scheme == "https" ? 443 : 80))"
    }
}

/// Task delegate of a DICOMweb request (#2893). Redirects are refused, or followed only where the origin policy
/// allows, with credentials removed off the configured origin. HTTP authentication challenges are answered with no
/// credential, so shared credential storage is never consulted and the server's 401 reaches the caller; server trust
/// keeps the system evaluation, with the policy's added trust, and the policy's client certificate goes to the
/// configured origin alone. The created task is kept so a deadline can cancel it.
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
    private var clientCertificateWithheld = false

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

    /// `error`, a timeout when the deadline cancelled the task, or `URLError(.clientCertificateRequired)` when the
    /// connection failed before any response after the server asked for a client certificate that was not presented,
    /// which URLSession reports only as a lost connection.
    public func mapping(_ error: Error) -> Error {
        if didReachDeadline { return URLError(.timedOut) }
        if let failure = error as? URLError, failure.code != .cancelled,
           lock.withLock({ clientCertificateWithheld && task?.response == nil }) {
            return URLError(.clientCertificateRequired)
        }
        return error
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

    /// Server trust keeps the system's evaluation, plus the policy's `serverTrust` for the origins it allows. A client
    /// certificate is presented only to the configured origin; anywhere else, or without an identity, the TLS
    /// handshake goes on without one, and a server that requires it fails the request with
    /// `URLError(.clientCertificateRequired)`. Every other challenge is answered with no credential.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if let trust = space.serverTrust, policy.allowsOrigin(space),
               let evaluated = policy.serverTrust.evaluated(trust, host: space.host) {
                completionHandler(.useCredential, URLCredential(trust: evaluated))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            if let identity = policy.clientIdentity, policy.isConfiguredOrigin(space) {
                completionHandler(.useCredential, identity.credential)
            } else {
                lock.withLock { clientCertificateWithheld = true }
                completionHandler(.rejectProtectionSpace, nil)
            }
        default:
            completionHandler(.rejectProtectionSpace, nil)
        }
    }
}
