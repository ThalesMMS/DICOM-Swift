import CryptoKit
import Foundation

public enum SMARTLaunch: Equatable, Sendable {
    case standalone
    /// EHR launch: the `launch` token received from the EHR and the `iss` it was launched from.
    case ehr(launch: String, iss: URL)
}

/// Client registration facts. Public clients never hold a secret; confidential clients inject one
/// through `clientSecret` so it is never stored by the toolkit.
public struct SMARTClientConfiguration: Sendable {
    public var clientID: String
    public var redirectURI: URL
    public var scopes: [SMARTScope]
    public var launch: SMARTLaunch
    /// Resource server the token is intended for (`aud`); defaults to the FHIR base URL.
    public var audience: URL
    public var clientSecret: (@Sendable () async throws -> String)?
    /// Extra redirect schemes accepted besides https (for example an app custom scheme).
    public var allowedRedirectSchemes: Set<String>

    public init(clientID: String, redirectURI: URL, scopes: [SMARTScope], audience: URL, launch: SMARTLaunch = .standalone,
                clientSecret: (@Sendable () async throws -> String)? = nil, allowedRedirectSchemes: Set<String> = []) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.launch = launch
        self.audience = audience
        self.clientSecret = clientSecret
        self.allowedRedirectSchemes = allowedRedirectSchemes
    }

    public var isConfidential: Bool { clientSecret != nil }
    public var scopeString: String { scopes.map(\.raw).joined(separator: " ") }
    public var requestsOpenID: Bool { scopes.contains { $0.raw == "openid" } }
}

/// State the host keeps between building the authorization URL and receiving the redirect.
/// Contains the PKCE verifier and nonce; it is not a token and must not be logged.
public struct SMARTPendingAuthorization: Equatable, Sendable {
    public let state: String
    public let codeVerifier: String
    public let nonce: String?
    public let createdAt: Date
    public let lifetime: TimeInterval
    public let issuer: URL

    public init(state: String, codeVerifier: String, nonce: String?, createdAt: Date, lifetime: TimeInterval, issuer: URL) {
        self.state = state
        self.codeVerifier = codeVerifier
        self.nonce = nonce
        self.createdAt = createdAt
        self.lifetime = lifetime
        self.issuer = issuer
    }

    public var isExpired: Bool { Date().timeIntervalSince(createdAt) > lifetime }

    /// S256 challenge of the verifier.
    public var codeChallenge: String { SMARTAuthorizationRequest.challenge(for: codeVerifier) }
}

public enum SMARTAuthorizationRequest {
    /// Random URL-safe string of the given byte length (verifier: 32 bytes -> 43 chars).
    static func randomToken(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// Builds the authorization URL (response_type=code, PKCE S256, state, optional nonce/launch/aud).
    public static func make(client: SMARTClientConfiguration, server: SMARTServerConfiguration, lifetime: TimeInterval = 600) throws -> (url: URL, pending: SMARTPendingAuthorization) {
        let redirectScheme = client.redirectURI.scheme?.lowercased() ?? ""
        guard redirectScheme == "https" || client.allowedRedirectSchemes.contains(redirectScheme) ||
              (redirectScheme == "http" && ["127.0.0.1", "localhost"].contains(client.redirectURI.host ?? "")) else {
            throw SMARTAuthorizationError.invalidRedirect("redirect scheme not allowed")
        }
        if case .ehr(_, let iss) = client.launch, iss.absoluteString != server.issuer.absoluteString {
            throw SMARTAuthorizationError.issuerMismatch
        }
        let pending = SMARTPendingAuthorization(state: randomToken(bytes: 16), codeVerifier: randomToken(bytes: 32),
                                                nonce: client.requestsOpenID ? randomToken(bytes: 16) : nil,
                                                createdAt: Date(), lifetime: lifetime, issuer: server.issuer)
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: client.redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: client.scopeString),
            URLQueryItem(name: "state", value: pending.state),
            URLQueryItem(name: "aud", value: client.audience.absoluteString),
            URLQueryItem(name: "code_challenge", value: pending.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if let nonce = pending.nonce { items.append(URLQueryItem(name: "nonce", value: nonce)) }
        if case .ehr(let launch, _) = client.launch { items.append(URLQueryItem(name: "launch", value: launch)) }
        guard var components = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw SMARTAuthorizationError.discoveryInvalid("authorization_endpoint")
        }
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else { throw SMARTAuthorizationError.discoveryInvalid("authorization_endpoint") }
        return (url, pending)
    }

    /// Validates the redirect back to the client and extracts the authorization code.
    public static func parseRedirect(_ redirect: URL, client: SMARTClientConfiguration, pending: SMARTPendingAuthorization) throws -> String {
        guard let components = URLComponents(url: redirect, resolvingAgainstBaseURL: false) else { throw SMARTAuthorizationError.invalidRedirect("unparseable") }
        var expected = URLComponents(url: client.redirectURI, resolvingAgainstBaseURL: false)
        expected?.query = nil
        var actual = components
        actual.query = nil
        guard expected?.url?.absoluteString == actual.url?.absoluteString else { throw SMARTAuthorizationError.invalidRedirect("redirect_uri differs") }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard !pending.isExpired else { throw SMARTAuthorizationError.stateMismatch }
        guard query["state"] == pending.state else { throw SMARTAuthorizationError.stateMismatch }
        if let iss = query["iss"], iss != pending.issuer.absoluteString {
            throw SMARTAuthorizationError.issuerMismatch
        }
        if let error = query["error"] { throw SMARTAuthorizationError.authorizationDenied(error: error, description: query["error_description"]) }
        guard let code = query["code"], !code.isEmpty else { throw SMARTAuthorizationError.invalidRedirect("code missing") }
        return code
    }
}
