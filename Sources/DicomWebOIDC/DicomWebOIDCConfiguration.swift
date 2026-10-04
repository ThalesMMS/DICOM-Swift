import Foundation

/// The OpenID Connect settings of one public client: the issuer, the client registered with it and where the
/// authorization response returns. None of them is secret.
public struct DicomWebOIDCConfiguration: Codable, Equatable, Hashable, Sendable {
    public let issuerURL: String
    public let clientID: String
    /// Space-separated scopes; `openid` is required.
    public let scopes: String
    /// Sent as the `audience` authorization parameter when the provider needs one.
    public let audience: String?
    /// A private-use URI scheme the host's browser session listens for, such as `myapp://oauth2/callback`.
    public let redirectURI: String

    public init(issuerURL: String, clientID: String, scopes: String = "openid offline_access", audience: String? = nil,
                redirectURI: String) {
        self.issuerURL = issuerURL
        self.clientID = clientID
        self.scopes = scopes
        self.audience = audience
        self.redirectURI = redirectURI
    }

    /// The scheme the browser session waits for.
    public var callbackScheme: String? {
        URL(string: redirectURI)?.scheme
    }

    /// The same settings, trimmed and normalized: an HTTPS issuer without credentials, query, fragment or trailing
    /// slash, a client ID, scopes that include `openid` (each once) and a private-use redirect URI.
    public func validated() throws -> Self {
        let issuer = issuerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let issuerComponents = URLComponents(string: issuer),
              issuerComponents.scheme?.lowercased() == "https",
              issuerComponents.host?.isEmpty == false,
              issuerComponents.user == nil, issuerComponents.password == nil,
              issuerComponents.query == nil, issuerComponents.fragment == nil else {
            throw DicomWebOIDCError.invalidConfiguration
        }
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        let scopeValues = scopes.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { seen.insert($0).inserted }
        let redirect = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, scopeValues.contains("openid"),
              let redirectComponents = URLComponents(string: redirect),
              let scheme = redirectComponents.scheme?.lowercased(), !scheme.isEmpty, scheme != "http", scheme != "https",
              redirectComponents.user == nil, redirectComponents.password == nil,
              redirectComponents.query == nil, redirectComponents.fragment == nil else {
            throw DicomWebOIDCError.invalidConfiguration
        }
        let audience = audience?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(issuerURL: issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer, clientID: clientID,
                    scopes: scopeValues.joined(separator: " "), audience: audience?.isEmpty == false ? audience : nil,
                    redirectURI: redirect)
    }
}
