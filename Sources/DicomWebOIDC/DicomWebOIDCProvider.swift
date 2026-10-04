import CryptoKit
import DicomWebClient
import Foundation
import Security

/// OpenID Connect sign-in for a public client (authorization code with PKCE S256), and the access tokens of the
/// signed-in keys, renewed with their refresh tokens. It has no user interface: the host opens the authorization URL
/// in its own browser session and returns the callback here.
///
/// - Discovery and the token endpoint must be HTTPS. Their requests use an ephemeral session without cookies or cache
///   that refuses redirects, unless the host passes its own session.
/// - The callback must match the redirect URI and the pending login's state (compared in constant time). The ID token
///   must verify with RS256 or ES256 against the provider's JWKS, which is fetched again once when the token names a
///   key ID it does not have, and must carry the login's nonce.
/// - Discovery documents are kept for `discoveryLifetime` seconds, then fetched again.
/// - An access token is used until 60 seconds before it expires; then, or after a 401, it is refreshed. Concurrent
///   refreshes of one key share a single token request.
public actor DicomWebOIDCProvider {
    private struct PendingLogin: Sendable {
        let key: String
        let configuration: DicomWebOIDCConfiguration
        let metadata: DicomWebOIDCProviderMetadata
        let state: String
        let nonce: String
        let codeVerifier: String
    }

    private struct TokenResponse: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String
        let expiresIn: TimeInterval
        let idToken: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case idToken = "id_token"
        }
    }

    private struct CachedMetadata: Sendable {
        let metadata: DicomWebOIDCProviderMetadata
        let expiresAt: Date
    }

    private static let maximumResponseBytes = 1_048_576
    private static let refreshLeeway: TimeInterval = 60

    private let tokenStore: any DicomWebOIDCTokenStore
    private let session: URLSession
    private let redirectBlocker: DicomWebOIDCRedirectBlocker?
    private let discoveryLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private var metadataByIssuer: [String: CachedMetadata] = [:]
    private var jwksByURL: [URL: Data] = [:]
    private var pendingLogins: [UUID: PendingLogin] = [:]
    private var refreshTasksByKey: [String: Task<DicomWebOIDCTokenSet, any Error>] = [:]

    /// - Parameters:
    ///   - tokenStore: where tokens are kept, one set per key.
    ///   - session: the session for discovery, JWKS and token requests; nil makes an ephemeral one that keeps no
    ///     cookies or cache and refuses redirects.
    ///   - discoveryLifetime: how long a discovery document is used before it is fetched again, in seconds.
    public init(tokenStore: any DicomWebOIDCTokenStore, session: URLSession? = nil,
                discoveryLifetime: TimeInterval = 3_600, now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokenStore = tokenStore
        self.discoveryLifetime = max(0, discoveryLifetime)
        self.now = now
        if let session {
            self.session = session
            redirectBlocker = nil
        } else {
            let blocker = DicomWebOIDCRedirectBlocker()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration, delegate: blocker, delegateQueue: nil)
            redirectBlocker = blocker
        }
    }

    /// Starts a sign-in for `key`: discovers the provider and returns the authorization URL, with PKCE S256, state
    /// and nonce, for the host's browser session.
    public func beginLogin(key: String, configuration: DicomWebOIDCConfiguration) async throws
        -> DicomWebOIDCLoginRequest {
        let configuration = try configuration.validated()
        let metadata = try await discover(configuration: configuration)
        let state = try randomURLToken(byteCount: 32)
        let nonce = try randomURLToken(byteCount: 32)
        let verifier = try randomURLToken(byteCount: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).dicomWebBase64URLEncodedString()

        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        let controlledParameters: Set<String> = [
            "response_type", "client_id", "redirect_uri", "scope", "state", "nonce",
            "code_challenge", "code_challenge_method", "audience"
        ]
        var items = (components?.queryItems ?? []).filter { !controlledParameters.contains($0.name) }
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: configuration.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if let audience = configuration.audience {
            items.append(URLQueryItem(name: "audience", value: audience))
        }
        components?.queryItems = items
        guard let authorizationURL = components?.url, let callbackScheme = configuration.callbackScheme else {
            throw DicomWebOIDCError.invalidConfiguration
        }

        let id = UUID()
        pendingLogins[id] = PendingLogin(key: key, configuration: configuration, metadata: metadata, state: state,
                                         nonce: nonce, codeVerifier: verifier)
        return DicomWebOIDCLoginRequest(id: id, authorizationURL: authorizationURL, callbackScheme: callbackScheme)
    }

    /// Ends the sign-in `id` with the browser's callback: checks it, exchanges the code, verifies the ID token and
    /// stores the tokens under the login's key.
    public func completeLogin(id: UUID, callbackURL: URL) async throws {
        guard let pending = pendingLogins.removeValue(forKey: id) else {
            throw DicomWebOIDCError.invalidCallback
        }
        guard callbackMatches(callbackURL, redirectURI: pending.configuration.redirectURI),
              callbackURL.fragment == nil,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw DicomWebOIDCError.invalidCallback
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil else { throw DicomWebOIDCError.invalidCallback }
            values[item.name] = item.value ?? ""
        }
        if let providerError = values["error"], !providerError.isEmpty {
            throw DicomWebOIDCError.providerRejectedLogin(code: sanitizedProviderCode(providerError))
        }
        guard let state = values["state"], Data.dicomWebConstantTimeEqual(state, pending.state),
              let code = values["code"], !code.isEmpty else {
            throw DicomWebOIDCError.invalidCallback
        }

        let response = try await requestTokens(endpoint: pending.metadata.tokenEndpoint, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": pending.configuration.redirectURI,
            "client_id": pending.configuration.clientID,
            "code_verifier": pending.codeVerifier
        ])
        guard response.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame, !response.accessToken.isEmpty,
              response.expiresIn > 0, let idToken = response.idToken else {
            throw DicomWebOIDCError.tokenExchangeFailed
        }
        try await verify(idToken: idToken, accessToken: response.accessToken, pending: pending)
        let tokens = DicomWebOIDCTokenSet(accessToken: response.accessToken, refreshToken: response.refreshToken,
                                          tokenType: response.tokenType,
                                          expiresAt: now().addingTimeInterval(response.expiresIn),
                                          configuration: pending.configuration)
        try tokenStore.store(tokens, forKey: pending.key)
    }

    /// Forgets the sign-in `id`.
    public func cancelLogin(id: UUID) {
        pendingLogins[id] = nil
    }

    /// Whether `key` has tokens issued for `configuration`.
    public func hasTokens(key: String, configuration: DicomWebOIDCConfiguration) -> Bool {
        guard let configuration = try? configuration.validated(),
              let tokens = try? tokenStore.tokens(forKey: key) else {
            return false
        }
        return tokens.matches(configuration)
    }

    /// Stops any refresh of `key` and deletes its tokens.
    public func signOut(key: String) throws {
        refreshTasksByKey[key]?.cancel()
        refreshTasksByKey[key] = nil
        try tokenStore.deleteTokens(forKey: key)
    }

    /// The access token of `key`, refreshed first when it expires within 60 seconds. Throws `signInRequired` when
    /// there are no tokens for `configuration` or they expired without a refresh token.
    public func accessToken(key: String, configuration: DicomWebOIDCConfiguration) async throws -> String {
        let configuration = try configuration.validated()
        let stored = try storedTokens(key: key, configuration: configuration)
        if stored.isUsable(for: configuration, now: now(), refreshLeeway: Self.refreshLeeway) {
            return stored.accessToken
        }
        return try await refresh(key: key, configuration: configuration, stored: stored).accessToken
    }

    /// Called after the server refused `rejectedAccessToken` with 401. Returns true when a different token is ready:
    /// one another request already obtained, or one refreshed now even though the rejected token had not expired.
    /// Returns false when there is nothing to renew with (no refresh token).
    public func renewAccessToken(key: String, configuration: DicomWebOIDCConfiguration,
                                 rejectedAccessToken: String?) async throws -> Bool {
        let configuration = try configuration.validated()
        let stored = try storedTokens(key: key, configuration: configuration)
        if refreshTasksByKey[key] == nil, let rejectedAccessToken,
           !Data.dicomWebConstantTimeEqual(stored.accessToken, rejectedAccessToken),
           stored.isUsable(for: configuration, now: now(), refreshLeeway: Self.refreshLeeway) {
            return true
        }
        guard refreshTasksByKey[key] != nil || stored.refreshToken?.isEmpty == false else { return false }
        _ = try await refresh(key: key, configuration: configuration, stored: stored)
        return true
    }

    /// The per-request provider of `key` for a `DicomWebClient`: it sends the current access token and renews it once
    /// after a 401.
    public nonisolated func authorization(key: String, configuration: DicomWebOIDCConfiguration)
        -> DicomWebOIDCAuthorization {
        DicomWebOIDCAuthorization(provider: self, key: key, configuration: configuration)
    }

    private func storedTokens(key: String, configuration: DicomWebOIDCConfiguration) throws -> DicomWebOIDCTokenSet {
        guard let stored = try tokenStore.tokens(forKey: key), stored.matches(configuration) else {
            throw DicomWebOIDCError.signInRequired
        }
        return stored
    }

    /// Joins the refresh of `key` in flight, or starts one with the stored refresh token.
    private func refresh(key: String, configuration: DicomWebOIDCConfiguration,
                         stored: DicomWebOIDCTokenSet) async throws -> DicomWebOIDCTokenSet {
        if let refreshTask = refreshTasksByKey[key] {
            return try await refreshTask.value
        }
        guard let refreshToken = stored.refreshToken, !refreshToken.isEmpty else {
            throw DicomWebOIDCError.signInRequired
        }
        let refreshTask = Task { [self] in
            try await refreshTokenSet(refreshToken: refreshToken, configuration: configuration, key: key)
        }
        refreshTasksByKey[key] = refreshTask
        defer { refreshTasksByKey[key] = nil }
        return try await refreshTask.value
    }

    private func refreshTokenSet(refreshToken: String, configuration: DicomWebOIDCConfiguration,
                                 key: String) async throws -> DicomWebOIDCTokenSet {
        let metadata = try await discover(configuration: configuration)
        let response = try await requestTokens(endpoint: metadata.tokenEndpoint, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
            "scope": configuration.scopes
        ])
        guard response.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame, !response.accessToken.isEmpty,
              response.expiresIn > 0 else {
            throw DicomWebOIDCError.tokenExchangeFailed
        }
        let refreshed = DicomWebOIDCTokenSet(accessToken: response.accessToken,
                                             refreshToken: response.refreshToken ?? refreshToken,
                                             tokenType: response.tokenType,
                                             expiresAt: now().addingTimeInterval(response.expiresIn),
                                             configuration: configuration)
        try tokenStore.store(refreshed, forKey: key)
        return refreshed
    }

    /// Verifies the ID token, fetching the JWKS again once when the token names a key ID the cached set lacks.
    private func verify(idToken: String, accessToken: String, pending: PendingLogin) async throws {
        var reloaded = jwksByURL[pending.metadata.jwksURI] == nil
        var jwks = try await loadJWKS(from: pending.metadata.jwksURI, reload: false)
        while true {
            do {
                try DicomWebOIDCJWTVerifier.verify(idToken: idToken, accessToken: accessToken, jwksData: jwks,
                                                   configuration: pending.configuration, nonce: pending.nonce,
                                                   now: now())
                return
            } catch is DicomWebOIDCJWTVerifier.UnknownKeyID {
                guard !reloaded else { throw DicomWebOIDCError.invalidIDToken }
                reloaded = true
                jwks = try await loadJWKS(from: pending.metadata.jwksURI, reload: true)
            }
        }
    }

    private func discover(configuration: DicomWebOIDCConfiguration) async throws -> DicomWebOIDCProviderMetadata {
        if let cached = metadataByIssuer[configuration.issuerURL], cached.expiresAt > now() {
            return cached.metadata
        }
        guard let url = URL(string: configuration.issuerURL + "/.well-known/openid-configuration") else {
            throw DicomWebOIDCError.discoveryFailed
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await responseData(for: request, error: .discoveryFailed)
        guard let metadata = try? JSONDecoder().decode(DicomWebOIDCProviderMetadata.self, from: data),
              metadata.issuer == configuration.issuerURL,
              secureEndpoint(metadata.authorizationEndpoint),
              secureEndpoint(metadata.tokenEndpoint),
              secureEndpoint(metadata.jwksURI) else {
            throw DicomWebOIDCError.discoveryFailed
        }
        guard metadata.codeChallengeMethodsSupported.contains(where: {
            $0.caseInsensitiveCompare("S256") == .orderedSame
        }) else {
            throw DicomWebOIDCError.providerDoesNotSupportPKCE
        }
        if !metadata.idTokenSigningAlgValuesSupported.isEmpty,
           metadata.idTokenSigningAlgValuesSupported.allSatisfy({ !["RS256", "ES256"].contains($0) }) {
            throw DicomWebOIDCError.discoveryFailed
        }
        metadataByIssuer[configuration.issuerURL] = CachedMetadata(
            metadata: metadata, expiresAt: now().addingTimeInterval(discoveryLifetime))
        return metadata
    }

    private func loadJWKS(from url: URL, reload: Bool) async throws -> Data {
        if !reload, let cached = jwksByURL[url] { return cached }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await responseData(for: request, error: .invalidIDToken)
        jwksByURL[url] = data
        return data
    }

    private func requestTokens(endpoint: URL, form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formURLEncoded(form)
        let data = try await responseData(for: request, error: .tokenExchangeFailed)
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw DicomWebOIDCError.tokenExchangeFailed
        }
        return response
    }

    private func responseData(for request: URLRequest, error: DicomWebOIDCError) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              data.count <= Self.maximumResponseBytes else {
            throw error
        }
        return data
    }

    private func callbackMatches(_ callback: URL, redirectURI: String) -> Bool {
        guard let expected = URL(string: redirectURI) else { return false }
        return callback.scheme?.caseInsensitiveCompare(expected.scheme ?? "") == .orderedSame &&
            (callback.host ?? "").caseInsensitiveCompare(expected.host ?? "") == .orderedSame &&
            callback.port == expected.port &&
            callback.path == expected.path
    }

    private func secureEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https" && components.host?.isEmpty == false &&
            components.user == nil && components.password == nil && components.fragment == nil
    }

    private func randomURLToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DicomWebOIDCError.invalidConfiguration
        }
        return Data(bytes).dicomWebBase64URLEncodedString()
    }

    private func formURLEncoded(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let body = values.keys.sorted().map { "\(encode($0))=\(encode(values[$0] ?? ""))" }.joined(separator: "&")
        return Data(body.utf8)
    }

    private func sanitizedProviderCode(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0)
        }
        return String(allowed.prefix(64))
    }
}
