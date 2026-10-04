import DicomWebClient
import Foundation

/// The per-request provider of one signed-in key, for `DicomWebClient.authorizationProvider`: each request carries the
/// key's current access token as a bearer header, and a 401 renews the token once.
public struct DicomWebOIDCAuthorization: DicomWebAuthorizationProvider {
    public let provider: DicomWebOIDCProvider
    public let key: String
    public let configuration: DicomWebOIDCConfiguration

    public init(provider: DicomWebOIDCProvider, key: String, configuration: DicomWebOIDCConfiguration) {
        self.provider = provider
        self.key = key
        self.configuration = configuration
    }

    public func authorizationHeaders() async throws -> [String: String] {
        let token = try await provider.accessToken(key: key, configuration: configuration)
        return try DicomWebAuthentication.bearer(token: token).authorizationHeaders()
    }

    public func renewAuthorization(afterRejecting rejected: [String: String]) async throws -> Bool {
        let header = rejected.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
        let token = header.flatMap { value -> String? in
            let prefix = "Bearer "
            return value.lowercased().hasPrefix(prefix.lowercased()) ? String(value.dropFirst(prefix.count)) : nil
        }
        return try await provider.renewAccessToken(key: key, configuration: configuration, rejectedAccessToken: token)
    }
}
