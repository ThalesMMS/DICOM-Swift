import DicomCore
import Foundation
import HL7v3Transport

/// Tokens issued by the authorization server. Never place these in URLs or logs.
public struct SMARTToken: Equatable, Sendable {
    public var accessToken: String
    public var tokenType: String
    public var expiresAt: Date?
    public var scopes: [SMARTScope]
    public var refreshToken: String?
    public var idToken: String?
    public var patient: String?
    public var encounter: String?
    public var fhirUser: String?
    public var issuedAt: Date

    public init(accessToken: String, tokenType: String = "Bearer", expiresAt: Date? = nil, scopes: [SMARTScope] = [], refreshToken: String? = nil,
                idToken: String? = nil, patient: String? = nil, encounter: String? = nil, fhirUser: String? = nil, issuedAt: Date = Date()) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.patient = patient
        self.encounter = encounter
        self.fhirUser = fhirUser
        self.issuedAt = issuedAt
    }

    public func isExpired(at date: Date = Date(), skew: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return date.addingTimeInterval(skew) >= expiresAt
    }

    /// Parses the token endpoint JSON (RFC 6749 + SMART context fields).
    public init(tokenResponse data: Data, now: Date = Date()) throws {
        let object = try FHIRJSONParser().parseObject(data)
        guard let accessToken = object["access_token"]?.string, !accessToken.isEmpty else { throw SMARTAuthorizationError.tokenResponseInvalid("access_token") }
        guard (object["token_type"]?.string ?? "").lowercased() == "bearer" else { throw SMARTAuthorizationError.tokenResponseInvalid("token_type") }
        let expiresIn = object["expires_in"]?.number?.intValue ?? object["expires_in"]?.string.flatMap(Int.init)
        self.init(accessToken: accessToken, tokenType: "Bearer", expiresAt: expiresIn.map { now.addingTimeInterval(TimeInterval($0)) },
                  scopes: SMARTScope.parse(object["scope"]?.string ?? ""), refreshToken: object["refresh_token"]?.string,
                  idToken: object["id_token"]?.string, patient: object["patient"]?.string, encounter: object["encounter"]?.string,
                  fhirUser: object["fhirUser"]?.string, issuedAt: now)
    }
}

/// Claims of an `id_token`. The signature is NOT verified here: hosts that need identity assertions
/// must verify it with their JWKS verifier before trusting `sub`/`fhirUser`.
public struct SMARTIDTokenClaims: Equatable, Sendable {
    public let issuer: String?
    public let subject: String?
    public let audience: [String]
    public let nonce: String?
    public let expiresAt: Date?
    public let fhirUser: String?
    public let algorithm: String?

    public init(idToken: String) throws {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw SMARTAuthorizationError.idTokenInvalid("segments") }
        func decode(_ segment: Substring) throws -> FHIRJSONObject {
            var text = String(segment).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while text.count % 4 != 0 { text += "=" }
            guard let data = Data(base64Encoded: text) else { throw SMARTAuthorizationError.idTokenInvalid("base64url") }
            return try FHIRJSONParser().parseObject(data)
        }
        let header = try decode(parts[0])
        let payload = try decode(parts[1])
        algorithm = header["alg"]?.string
        issuer = payload["iss"]?.string
        subject = payload["sub"]?.string
        audience = payload["aud"]?.string.map { [$0] } ?? payload["aud"]?.array?.compactMap(\.string) ?? []
        nonce = payload["nonce"]?.string
        expiresAt = (payload["exp"]?.number?.decimalValue).map { Date(timeIntervalSince1970: NSDecimalNumber(decimal: $0).doubleValue) }
        fhirUser = payload["fhirUser"]?.string
    }

    /// Checks issuer, audience, nonce and expiry; `alg=none` is always refused.
    public func validate(issuer expectedIssuer: URL, clientID: String, nonce expectedNonce: String?, now: Date = Date()) throws {
        guard algorithm?.lowercased() != "none" else { throw SMARTAuthorizationError.idTokenInvalid("alg none") }
        guard issuer == expectedIssuer.absoluteString else { throw SMARTAuthorizationError.issuerMismatch }
        guard audience.contains(clientID) else { throw SMARTAuthorizationError.idTokenInvalid("aud") }
        if let expectedNonce, nonce != expectedNonce { throw SMARTAuthorizationError.nonceMismatch }
        if let expiresAt, expiresAt <= now { throw SMARTAuthorizationError.tokenExpired }
    }
}

/// Token endpoint interactions: code exchange (PKCE), refresh and revocation over the bounded transport.
public struct SMARTTokenClient: Sendable {
    public let server: SMARTServerConfiguration
    public let client: SMARTClientConfiguration
    public let policy: HL7v3TransportPolicy
    private let transport: any DicomWebHTTPTransport

    public init(server: SMARTServerConfiguration, client: SMARTClientConfiguration, policy: HL7v3TransportPolicy = .init(), transport: (any DicomWebHTTPTransport)? = nil) {
        self.server = server
        self.client = client
        self.policy = policy
        self.transport = transport ?? HL7v3URLSessionTransport(maximumResponseBytes: policy.maximumResponseBytes, trust: policy.trust, serverName: policy.serverName)
    }

    public func exchange(code: String, pending: SMARTPendingAuthorization) async throws -> SMARTToken {
        let token = try await post(server.tokenEndpoint, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": client.redirectURI.absoluteString,
            "client_id": client.clientID, "code_verifier": pending.codeVerifier
        ])
        let missing = SMARTScope.missing(requested: client.scopes.filter(\.isResourceScope), granted: token.scopes)
        if !missing.isEmpty { throw SMARTAuthorizationError.insufficientScope(missing: missing.map(\.raw)) }
        if client.requestsOpenID {
            guard let idToken = token.idToken else { throw SMARTAuthorizationError.idTokenInvalid("missing") }
            try SMARTIDTokenClaims(idToken: idToken).validate(issuer: server.issuer, clientID: client.clientID, nonce: pending.nonce)
        }
        return token
    }

    public func refresh(_ token: SMARTToken) async throws -> SMARTToken {
        guard let refreshToken = token.refreshToken else { throw SMARTAuthorizationError.noRefreshToken }
        var refreshed = try await post(server.tokenEndpoint, form: ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": client.clientID])
        if refreshed.refreshToken == nil { refreshed.refreshToken = refreshToken }
        if refreshed.scopes.isEmpty { refreshed.scopes = token.scopes }
        refreshed.patient = refreshed.patient ?? token.patient
        refreshed.encounter = refreshed.encounter ?? token.encounter
        refreshed.fhirUser = refreshed.fhirUser ?? token.fhirUser
        return refreshed
    }

    /// RFC 7009 revocation of the refresh token (or the access token when no refresh token exists).
    public func revoke(_ token: SMARTToken) async throws {
        guard let endpoint = server.revocationEndpoint else { return }
        try policy.validate(endpoint)
        let value = token.refreshToken ?? token.accessToken
        let hint = token.refreshToken == nil ? "access_token" : "refresh_token"
        var request = DicomWebHTTPRequest(method: .post, url: endpoint, headers: try await headers(), body: Self.encode(["token": value, "token_type_hint": hint, "client_id": client.clientID]), timeout: policy.timeout)
        request.credentialHeaderNames = ["Authorization"]
        let response = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else { throw SMARTAuthorizationError.tokenRequestFailed(status: response.statusCode, error: nil, description: nil) }
    }

    private func headers() async throws -> [String: String] {
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"]
        if let secretProvider = client.clientSecret {
            let secret = try await secretProvider()
            headers["Authorization"] = "Basic " + Data((client.clientID + ":" + secret).utf8).base64EncodedString()
        }
        return headers
    }

    private func post(_ url: URL, form: [String: String]) async throws -> SMARTToken {
        try policy.validate(url)
        var request = DicomWebHTTPRequest(method: .post, url: url, headers: try await headers(), body: Self.encode(form), timeout: policy.timeout)
        request.credentialHeaderNames = ["Authorization"]
        let response: DicomWebHTTPResponse
        do { response = try await transport.send(request) } catch is CancellationError { throw CancellationError() } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SMARTAuthorizationError.tokenRequestFailed(status: nil, error: "transport", description: nil)
        }
        guard (200...299).contains(response.statusCode) else {
            let object = try? FHIRJSONParser().parseObject(response.body)
            throw SMARTAuthorizationError.tokenRequestFailed(status: response.statusCode, error: object?["error"]?.string, description: object?["error_description"]?.string)
        }
        return try SMARTToken(tokenResponse: response.body)
    }

    static func encode(_ form: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(form.keys.sorted().map { key in
            key + "=" + (form[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&").utf8)
    }
}
