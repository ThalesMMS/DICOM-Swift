import Foundation

/// Fixed errors deliberately omit server diagnostics, distinguished names and credentials.
public enum DicomLDAPError: Error, Equatable, Sendable {
    case invalidConfiguration, insecureTransport, invalidCredentials, identityNotUnique, unmappedIdentity
    case unavailable, tlsFailure, timeout, truncatedResponse, responseLimit, malformedResponse, unsupportedResponse
    case authorizationDenied, expiredPrincipal, unsupportedPlatform
    case serverResult(Int)
}
