import Foundation

/// The secret tokens of one signed-in client, with the settings they were issued for. Its descriptions are redacted.
public struct DicomWebOIDCTokenSet: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let expiresAt: Date
    public let configuration: DicomWebOIDCConfiguration

    public init(accessToken: String, refreshToken: String?, tokenType: String, expiresAt: Date,
                configuration: DicomWebOIDCConfiguration) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.configuration = configuration
    }

    /// Whether the tokens were issued for `configuration`.
    public func matches(_ configuration: DicomWebOIDCConfiguration) -> Bool {
        self.configuration == configuration
    }

    /// Whether the access token can be sent as it is: issued for `configuration`, a bearer token, and valid for more
    /// than `refreshLeeway` seconds.
    public func isUsable(for configuration: DicomWebOIDCConfiguration, now: Date = Date(),
                         refreshLeeway: TimeInterval = 60) -> Bool {
        matches(configuration) && tokenType.caseInsensitiveCompare("Bearer") == .orderedSame && !accessToken.isEmpty
            && expiresAt.timeIntervalSince(now) > refreshLeeway
    }

    public var description: String { "DICOMweb OIDC tokens (redacted)" }
    public var debugDescription: String { description }
}
