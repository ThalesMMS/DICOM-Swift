import DicomCore
import Foundation
import HL7v3Transport

public enum SMARTAuthorizationError: Error, Equatable, Sendable {
    case discoveryFailed(status: Int?)
    case discoveryInvalid(String)
    case issuerMismatch
    case insecureEndpoint(String)
    case pkceUnsupported
    case invalidRedirect(String)
    case stateMismatch
    case authorizationDenied(error: String, description: String?)
    case tokenRequestFailed(status: Int?, error: String?, description: String?)
    case tokenResponseInvalid(String)
    case insufficientScope(missing: [String])
    case nonceMismatch
    case idTokenInvalid(String)
    case tokenExpired
    case noRefreshToken
    case notAuthorized
    case revoked
}

/// `.well-known/smart-configuration` (SMART App Launch 2.x) as advertised by the server.
public struct SMARTServerConfiguration: Equatable, Sendable {
    public var issuer: URL
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var revocationEndpoint: URL?
    public var introspectionEndpoint: URL?
    public var jwksURI: URL?
    public var capabilities: [String]
    public var scopesSupported: [String]
    public var codeChallengeMethodsSupported: [String]
    public var grantTypesSupported: [String]
    public var tokenEndpointAuthMethodsSupported: [String]

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL, revocationEndpoint: URL? = nil, introspectionEndpoint: URL? = nil,
                jwksURI: URL? = nil, capabilities: [String] = [], scopesSupported: [String] = [], codeChallengeMethodsSupported: [String] = ["S256"],
                grantTypesSupported: [String] = ["authorization_code"], tokenEndpointAuthMethodsSupported: [String] = []) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.introspectionEndpoint = introspectionEndpoint
        self.jwksURI = jwksURI
        self.capabilities = capabilities
        self.scopesSupported = scopesSupported
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.grantTypesSupported = grantTypesSupported
        self.tokenEndpointAuthMethodsSupported = tokenEndpointAuthMethodsSupported
    }

    /// Parses the discovery document; the `issuer` claim (when present) must equal the expected issuer.
    public init(discoveryDocument data: Data, expectedIssuer: URL, policy: HL7v3TransportPolicy, allowedOrigins: Set<String> = []) throws {
        let object = try FHIRJSONParser().parseObject(data)
        func url(_ key: String, required: Bool) throws -> URL? {
            guard let text = object[key]?.string else {
                if required { throw SMARTAuthorizationError.discoveryInvalid(key + " missing") }
                return nil
            }
            guard let url = URL(string: text), url.host != nil else { throw SMARTAuthorizationError.discoveryInvalid(key + " invalid") }
            return url
        }
        if let issuerText = object["issuer"]?.string {
            guard issuerText == expectedIssuer.absoluteString else {
                throw SMARTAuthorizationError.issuerMismatch
            }
        }
        let strings: (String) -> [String] = { object[$0]?.array?.compactMap(\.string) ?? [] }
        self.init(issuer: expectedIssuer,
                  authorizationEndpoint: try url("authorization_endpoint", required: true)!,
                  tokenEndpoint: try url("token_endpoint", required: true)!,
                  revocationEndpoint: try url("revocation_endpoint", required: false),
                  introspectionEndpoint: try url("introspection_endpoint", required: false),
                  jwksURI: try url("jwks_uri", required: false),
                  capabilities: strings("capabilities"),
                  scopesSupported: strings("scopes_supported"),
                  codeChallengeMethodsSupported: strings("code_challenge_methods_supported"),
                  grantTypesSupported: strings("grant_types_supported"),
                  tokenEndpointAuthMethodsSupported: strings("token_endpoint_auth_methods_supported"))
        try validate(policy: policy, allowedOrigins: allowedOrigins)
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && (a.port ?? -1) == (b.port ?? -1)
    }

    static func origin(_ url: URL) -> String {
        (url.scheme?.lowercased() ?? "") + "://" + (url.host?.lowercased() ?? "") + (url.port.map { ":\($0)" } ?? "")
    }

    /// Every endpoint must be `https` (or an allow-listed lab host) and live on the issuer's origin or an allowed origin.
    public func validate(policy: HL7v3TransportPolicy, allowedOrigins: Set<String> = []) throws {
        for (name, endpoint) in [("authorization_endpoint", authorizationEndpoint), ("token_endpoint", tokenEndpoint),
                                 ("revocation_endpoint", revocationEndpoint), ("introspection_endpoint", introspectionEndpoint),
                                 ("jwks_uri", jwksURI)] {
            guard let endpoint else { continue }
            do { try policy.validate(endpoint) } catch { throw SMARTAuthorizationError.insecureEndpoint(name) }
            guard Self.sameOrigin(endpoint, issuer) || allowedOrigins.contains(Self.origin(endpoint)) else {
                throw SMARTAuthorizationError.discoveryInvalid(name + " outside the issuer origin")
            }
        }
        guard codeChallengeMethodsSupported.isEmpty || codeChallengeMethodsSupported.contains("S256") else {
            throw SMARTAuthorizationError.pkceUnsupported
        }
    }
}

/// Fetches `[issuer]/.well-known/smart-configuration` through the bounded transport.
public struct SMARTDiscovery: Sendable {
    public let policy: HL7v3TransportPolicy
    public let allowedOrigins: Set<String>
    private let transport: any DicomWebHTTPTransport

    public init(policy: HL7v3TransportPolicy = .init(), allowedOrigins: Set<String> = [], transport: (any DicomWebHTTPTransport)? = nil) {
        self.policy = policy
        self.allowedOrigins = allowedOrigins
        self.transport = transport ?? HL7v3URLSessionTransport(maximumResponseBytes: policy.maximumResponseBytes, trust: policy.trust, serverName: policy.serverName)
    }

    public func discover(issuer: URL) async throws -> SMARTServerConfiguration {
        try policy.validate(issuer)
        let url = issuer.appendingPathComponent(".well-known/smart-configuration")
        let request = DicomWebHTTPRequest(method: .get, url: url, headers: ["Accept": "application/json"], timeout: policy.timeout)
        let response: DicomWebHTTPResponse
        do { response = try await transport.send(request) } catch is CancellationError { throw CancellationError() } catch {
            throw SMARTAuthorizationError.discoveryFailed(status: nil)
        }
        guard (200...299).contains(response.statusCode) else { throw SMARTAuthorizationError.discoveryFailed(status: response.statusCode) }
        return try SMARTServerConfiguration(discoveryDocument: response.body, expectedIssuer: issuer, policy: policy, allowedOrigins: allowedOrigins)
    }
}
