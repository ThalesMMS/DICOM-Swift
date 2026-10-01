import Foundation

/// Persistence contract for tokens, keyed by issuer + client. The Keychain implementation lives in the host.
public protocol SMARTTokenStore: Sendable {
    func load(issuer: URL, clientID: String) async throws -> SMARTToken?
    func save(_ token: SMARTToken, issuer: URL, clientID: String) async throws
    func delete(issuer: URL, clientID: String) async throws
}

public actor SMARTInMemoryTokenStore: SMARTTokenStore {
    private var tokens: [String: SMARTToken] = [:]
    public init() {}
    private func key(_ issuer: URL, _ clientID: String) -> String { issuer.absoluteString + "|" + clientID }
    public func load(issuer: URL, clientID: String) async throws -> SMARTToken? { tokens[key(issuer, clientID)] }
    public func save(_ token: SMARTToken, issuer: URL, clientID: String) async throws { tokens[key(issuer, clientID)] = token }
    public func delete(issuer: URL, clientID: String) async throws { tokens[key(issuer, clientID)] = nil }
}

/// Token lifecycle for one client/issuer pair: hands out bearer headers, refreshes expiring tokens
/// exactly once even under concurrent callers, and revokes on sign-out.
public actor SMARTSession {
    public let tokenClient: SMARTTokenClient
    public let store: any SMARTTokenStore
    public let skew: TimeInterval
    private var token: SMARTToken?
    private var refreshTask: Task<SMARTToken, Error>?
    private(set) public var refreshCount = 0

    public init(tokenClient: SMARTTokenClient, store: any SMARTTokenStore = SMARTInMemoryTokenStore(), skew: TimeInterval = 30) {
        self.tokenClient = tokenClient
        self.store = store
        self.skew = skew
    }

    private var issuer: URL { tokenClient.server.issuer }
    private var clientID: String { tokenClient.client.clientID }

    public var currentToken: SMARTToken? { token }

    /// Completes the authorization code flow and stores the token.
    public func complete(code: String, pending: SMARTPendingAuthorization) async throws -> SMARTToken {
        let token = try await tokenClient.exchange(code: code, pending: pending)
        self.token = token
        try await store.save(token, issuer: issuer, clientID: clientID)
        return token
    }

    /// Restores a token from the store (for example on app start).
    public func restore() async throws -> Bool {
        token = try await store.load(issuer: issuer, clientID: clientID)
        return token != nil
    }

    /// A non-expired access token, refreshing when needed; concurrent callers share one refresh.
    public func validToken() async throws -> SMARTToken {
        guard let current = token else { throw SMARTAuthorizationError.notAuthorized }
        if !current.isExpired(skew: skew) { return current }
        if let inFlight = refreshTask { return try await inFlight.value }
        let task = Task<SMARTToken, Error> { [tokenClient] in try await tokenClient.refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            token = refreshed
            refreshCount += 1
            try await store.save(refreshed, issuer: issuer, clientID: clientID)
            return refreshed
        } catch {
            if case SMARTAuthorizationError.tokenRequestFailed(let status, _, _) = error, status == 400 || status == 401 {
                token = nil
                try? await store.delete(issuer: issuer, clientID: clientID)
            }
            throw error
        }
    }

    /// Headers for `FHIRClient.additionalHeaders`; the value never appears in URLs.
    public func authorizationHeaders() async throws -> [String: String] {
        ["Authorization": "Bearer " + (try await validToken()).accessToken]
    }

    public func revoke() async throws {
        guard let current = token else { return }
        token = nil
        try await store.delete(issuer: issuer, clientID: clientID)
        try await tokenClient.revoke(current)
    }
}
