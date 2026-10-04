import Foundation

/// A pending sign-in: the host opens `authorizationURL` in a browser session that waits for `callbackScheme`, then
/// hands the callback URL to `DicomWebOIDCProvider.completeLogin(id:callbackURL:)`. Its descriptions are redacted.
public struct DicomWebOIDCLoginRequest: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let authorizationURL: URL
    public let callbackScheme: String

    public init(id: UUID, authorizationURL: URL, callbackScheme: String) {
        self.id = id
        self.authorizationURL = authorizationURL
        self.callbackScheme = callbackScheme
    }

    public var description: String { "DICOMweb OIDC login request (URL redacted)" }
    public var debugDescription: String { description }
}
