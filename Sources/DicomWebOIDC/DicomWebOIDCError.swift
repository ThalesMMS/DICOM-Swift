import Foundation

/// Why an OpenID Connect sign-in or token renewal failed. No case carries a token, code or other secret.
public enum DicomWebOIDCError: Error, Equatable, LocalizedError, Sendable {
    /// The settings are incomplete or unsafe, or the system could not make the random login values.
    case invalidConfiguration
    /// The discovery document could not be read, does not name the configured issuer, or lists an endpoint that is
    /// not HTTPS.
    case discoveryFailed
    /// The provider does not advertise PKCE with S256.
    case providerDoesNotSupportPKCE
    /// The authorization response does not belong to a pending login, or its state does not match.
    case invalidCallback
    /// The provider answered the authorization request with an error code (sanitized).
    case providerRejectedLogin(code: String)
    /// The token endpoint refused the request or answered something other than a bearer token.
    case tokenExchangeFailed
    /// The ID token's signature, issuer, audience, lifetime, nonce or access-token hash does not verify.
    case invalidIDToken
    /// There are no tokens for this key and configuration, or they expired without a refresh token.
    case signInRequired

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The OpenID Connect settings are incomplete or unsafe."
        case .discoveryFailed: return "The identity provider configuration could not be verified."
        case .providerDoesNotSupportPKCE: return "The identity provider does not advertise PKCE with S256."
        case .invalidCallback: return "The identity provider returned an invalid sign-in response."
        case .providerRejectedLogin(let code): return "The identity provider rejected sign-in (\(code))."
        case .tokenExchangeFailed: return "The identity provider did not issue tokens."
        case .invalidIDToken: return "The identity provider returned an invalid ID token."
        case .signInRequired: return "Sign in before connecting."
        }
    }
}
