import CryptoKit
import DicomWebClient
import Foundation
import XCTest
@testable import DicomWebOIDC

/// The OIDC flow against a fake identity provider served through a URL protocol stub: discovery, PKCE login, ID-token
/// verification, shared refresh, JWKS reload on a new key ID, discovery expiry, and the 401 renewal of a client.
final class DicomWebOIDCProviderTests: XCTestCase {
    override func tearDown() {
        OIDCStubURLProtocol.handler = nil
        super.tearDown()
    }

    func test_beginLogin_discoversProviderAndBuildsAuthorizationCodePKCERequest() async throws {
        OIDCStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/.well-known/openid-configuration")
            return Self.response(for: request, body: Self.discoveryDocument)
        }
        let provider = makeProvider(tokenStore: MemoryTokenStore())

        let prompt = try await provider.beginLogin(key: "node", configuration: Self.configuration)
        let values = Self.queryValues(prompt.authorizationURL)

        XCTAssertEqual(prompt.authorizationURL.host, "login.example.com")
        XCTAssertEqual(prompt.callbackScheme, "dicomweb-test")
        XCTAssertEqual(values["response_type"], "code")
        XCTAssertEqual(values["client_id"], "public-client")
        XCTAssertEqual(values["redirect_uri"], Self.configuration.redirectURI)
        XCTAssertEqual(values["scope"], Self.configuration.scopes)
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["code_challenge"]?.isEmpty, false)
        XCTAssertEqual(values["state"]?.isEmpty, false)
        XCTAssertEqual(values["nonce"]?.isEmpty, false)
        XCTAssertNil(values["client_secret"])
    }

    func test_completeLogin_rejectsDuplicateCallbackParametersBeforeTokenExchange() async throws {
        OIDCStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/.well-known/openid-configuration", "no token request")
            return Self.response(for: request, body: Self.discoveryDocument)
        }
        let provider = makeProvider(tokenStore: MemoryTokenStore())
        let prompt = try await provider.beginLogin(key: "node", configuration: Self.configuration)
        let state = try XCTUnwrap(Self.queryValues(prompt.authorizationURL)["state"])
        let callback = try XCTUnwrap(URL(string: "dicomweb-test://oauth2/callback?state=\(state)&code=one&code=two"))

        do {
            try await provider.completeLogin(id: prompt.id, callbackURL: callback)
            XCTFail("Expected duplicate callback parameters to be rejected")
        } catch let error as DicomWebOIDCError {
            XCTAssertEqual(error, .invalidCallback)
        }
    }

    func test_accessToken_refreshesExpiredTokenOnceForConcurrentCallersAndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = MemoryTokenStore()
        try tokenStore.store(Self.tokens(access: "expired-access", refresh: "refresh-one", expiresAt: now - 1),
                             forKey: "node")
        let recorder = OIDCRequestRecorder()
        OIDCStubURLProtocol.handler = { request in
            recorder.record(path: request.url?.path ?? "")
            if request.url?.path == "/.well-known/openid-configuration" {
                return Self.response(for: request, body: Self.discoveryDocument)
            }
            XCTAssertEqual(request.url?.path, "/oauth/token")
            let body = String(decoding: try Self.requestBody(request), as: UTF8.self)
            XCTAssertTrue(body.contains("grant_type=refresh_token"))
            XCTAssertTrue(body.contains("refresh_token=refresh-one"))
            return Self.response(for: request, body: Self.tokenResponse(access: "fresh-access", refresh: "refresh-two"))
        }
        let provider = makeProvider(tokenStore: tokenStore, now: { now })

        async let first = provider.accessToken(key: "node", configuration: Self.configuration)
        async let second = provider.accessToken(key: "node", configuration: Self.configuration)
        let tokens = try await (first, second)

        XCTAssertEqual(tokens.0, "fresh-access")
        XCTAssertEqual(tokens.1, "fresh-access")
        XCTAssertEqual(recorder.count(for: "/oauth/token"), 1)
        XCTAssertEqual(try tokenStore.tokens(forKey: "node")?.refreshToken, "refresh-two")
        XCTAssertEqual(try tokenStore.tokens(forKey: "node")?.expiresAt, now.addingTimeInterval(3600))
    }

    func test_jwtVerifier_acceptsSignedES256IDTokenWithNonceAndAccessTokenHash() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let idToken = try Self.idToken(key: key, keyID: "test-key", nonce: "expected-nonce",
                                       accessToken: "access-token", now: now)

        XCTAssertNoThrow(try DicomWebOIDCJWTVerifier.verify(
            idToken: idToken, accessToken: "access-token", jwksData: try Self.jwks([("test-key", key)]),
            configuration: Self.configuration, nonce: "expected-nonce", now: now))
        XCTAssertThrowsError(try DicomWebOIDCJWTVerifier.verify(
            idToken: idToken, accessToken: "access-token", jwksData: try Self.jwks([("test-key", key)]),
            configuration: Self.configuration, nonce: "other-nonce", now: now))
    }

    func test_completeLogin_reloadsTheJWKSOnceWhenTheIDTokenNamesANewKeyID() async throws {
        let now = Date()
        let oldKey = P256.Signing.PrivateKey()
        let newKey = P256.Signing.PrivateKey()
        let tokenStore = MemoryTokenStore()
        let provider = makeProvider(tokenStore: tokenStore, now: { now })
        let recorder = OIDCRequestRecorder()
        let nonce = LockedString()
        let signingKey = LockedString("old")
        OIDCStubURLProtocol.handler = { request in
            recorder.record(path: request.url?.path ?? "")
            switch request.url?.path {
            case "/.well-known/openid-configuration":
                return Self.response(for: request, body: Self.discoveryDocument)
            case "/oauth/jwks":
                // The provider rotates its keys after the first sign-in: the second fetch lists the new key too.
                let keys = recorder.count(for: "/oauth/jwks") == 1 ? [("old", oldKey)] : [("old", oldKey), ("new", newKey)]
                return Self.response(for: request, body: try Self.jwks(keys))
            default:
                let kid = signingKey.value
                let idToken = try Self.idToken(key: kid == "old" ? oldKey : newKey, keyID: kid, nonce: nonce.value,
                                               accessToken: "access-\(kid)", now: now)
                return Self.response(for: request, body: Self.tokenResponse(access: "access-\(kid)",
                                                                            refresh: "refresh", idToken: idToken))
            }
        }

        try await signIn(provider, nonce: nonce)
        XCTAssertEqual(try tokenStore.tokens(forKey: "node")?.accessToken, "access-old")
        signingKey.value = "new"
        try await signIn(provider, nonce: nonce)

        XCTAssertEqual(try tokenStore.tokens(forKey: "node")?.accessToken, "access-new")
        XCTAssertEqual(recorder.count(for: "/oauth/jwks"), 2, "the cached set is used until a key ID is unknown")
    }

    func test_completeLogin_rejectsAKeyIDStillUnknownAfterOneReload() async throws {
        let now = Date()
        let listed = P256.Signing.PrivateKey()
        let unlisted = P256.Signing.PrivateKey()
        let tokenStore = MemoryTokenStore()
        let provider = makeProvider(tokenStore: tokenStore, now: { now })
        let recorder = OIDCRequestRecorder()
        let nonce = LockedString()
        let signingKey = LockedString("listed")
        OIDCStubURLProtocol.handler = { request in
            recorder.record(path: request.url?.path ?? "")
            switch request.url?.path {
            case "/.well-known/openid-configuration":
                return Self.response(for: request, body: Self.discoveryDocument)
            case "/oauth/jwks":
                return Self.response(for: request, body: try Self.jwks([("listed", listed)]))
            default:
                let kid = signingKey.value
                let idToken = try Self.idToken(key: kid == "listed" ? listed : unlisted, keyID: kid,
                                               nonce: nonce.value, accessToken: "access-\(kid)", now: now)
                return Self.response(for: request, body: Self.tokenResponse(access: "access-\(kid)", refresh: nil,
                                                                            idToken: idToken))
            }
        }
        try await signIn(provider, nonce: nonce)
        signingKey.value = "unlisted"

        do {
            try await signIn(provider, nonce: nonce)
            XCTFail("an ID token signed by an unlisted key must be refused")
        } catch let error as DicomWebOIDCError {
            XCTAssertEqual(error, .invalidIDToken)
        }
        XCTAssertEqual(recorder.count(for: "/oauth/jwks"), 2, "one reload, then the token is refused")
        XCTAssertEqual(try tokenStore.tokens(forKey: "node")?.accessToken, "access-listed")
    }

    func test_discovery_isFetchedAgainOnlyAfterItsLifetime() async throws {
        let clock = LockedDate(Date(timeIntervalSince1970: 2_000_000_000))
        let recorder = OIDCRequestRecorder()
        OIDCStubURLProtocol.handler = { request in
            recorder.record(path: request.url?.path ?? "")
            return Self.response(for: request, body: Self.discoveryDocument)
        }
        let provider = makeProvider(tokenStore: MemoryTokenStore(), discoveryLifetime: 600, now: { clock.value })

        _ = try await provider.beginLogin(key: "node", configuration: Self.configuration)
        clock.value += 599
        _ = try await provider.beginLogin(key: "node", configuration: Self.configuration)
        XCTAssertEqual(recorder.count(for: "/.well-known/openid-configuration"), 1)
        clock.value += 2
        _ = try await provider.beginLogin(key: "node", configuration: Self.configuration)
        XCTAssertEqual(recorder.count(for: "/.well-known/openid-configuration"), 2)
    }

    func test_client401_refreshesAValidTokenAndRepeatsTheRequestOnce() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = MemoryTokenStore()
        try tokenStore.store(Self.tokens(access: "revoked-access", refresh: "refresh-one", expiresAt: now + 3600),
                             forKey: "node")
        let recorder = OIDCRequestRecorder()
        OIDCStubURLProtocol.handler = { request in
            recorder.record(path: request.url?.path ?? "")
            if request.url?.path == "/.well-known/openid-configuration" {
                return Self.response(for: request, body: Self.discoveryDocument)
            }
            return Self.response(for: request, body: Self.tokenResponse(access: "fresh-access", refresh: "refresh-two"))
        }
        let provider = makeProvider(tokenStore: tokenStore, now: { now })
        let archive = BearerArchive(accepted: "Bearer fresh-access")
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://pacs.example/dicom-web")!),
                                    transport: archive,
                                    authorizationProvider: provider.authorization(key: "node",
                                                                                  configuration: Self.configuration))

        let page = try await client.search(parameters: .init(level: .study, includeFields: [], limit: 1))

        XCTAssertEqual(page.statusCode, 200)
        XCTAssertEqual(archive.authorizations, ["Bearer revoked-access", "Bearer fresh-access"])
        XCTAssertEqual(recorder.count(for: "/oauth/token"), 1)
        XCTAssertEqual(try tokenStore.tokens(forKey: "node")?.accessToken, "fresh-access")
    }

    func test_client401_afterRefreshEndsWithAnAuthenticationFailure() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let tokenStore = MemoryTokenStore()
        try tokenStore.store(Self.tokens(access: "revoked-access", refresh: "refresh-one", expiresAt: now + 3600),
                             forKey: "node")
        let recorder = OIDCRequestRecorder()
        OIDCStubURLProtocol.handler = { request in
            recorder.record(path: request.url?.path ?? "")
            if request.url?.path == "/.well-known/openid-configuration" {
                return Self.response(for: request, body: Self.discoveryDocument)
            }
            return Self.response(for: request, body: Self.tokenResponse(access: "fresh-access", refresh: "refresh-two"))
        }
        let provider = makeProvider(tokenStore: tokenStore, now: { now })
        let archive = BearerArchive(accepted: nil)
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://pacs.example/dicom-web")!),
                                    transport: archive,
                                    authorizationProvider: provider.authorization(key: "node",
                                                                                  configuration: Self.configuration))

        do {
            _ = try await client.search(parameters: .init(level: .study, includeFields: [], limit: 1))
            XCTFail("a second 401 must fail")
        } catch {
            XCTAssertEqual(DicomWebConnectionFailure(classifying: error).kind, .authentication)
        }
        XCTAssertEqual(archive.authorizations, ["Bearer revoked-access", "Bearer fresh-access"])
        XCTAssertEqual(recorder.count(for: "/oauth/token"), 1)
    }

    // MARK: - Fake identity provider

    private func signIn(_ provider: DicomWebOIDCProvider, nonce: LockedString) async throws {
        let prompt = try await provider.beginLogin(key: "node", configuration: Self.configuration)
        let values = Self.queryValues(prompt.authorizationURL)
        nonce.value = try XCTUnwrap(values["nonce"])
        let state = try XCTUnwrap(values["state"])
        let callback = try XCTUnwrap(URL(string: "dicomweb-test://oauth2/callback?state=\(state)&code=synthetic-code"))
        try await provider.completeLogin(id: prompt.id, callbackURL: callback)
    }

    private func makeProvider(tokenStore: any DicomWebOIDCTokenStore, discoveryLifetime: TimeInterval = 3_600,
                              now: @escaping @Sendable () -> Date = { Date() }) -> DicomWebOIDCProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OIDCStubURLProtocol.self]
        return DicomWebOIDCProvider(tokenStore: tokenStore, session: URLSession(configuration: configuration),
                                    discoveryLifetime: discoveryLifetime, now: now)
    }

    private static let configuration = DicomWebOIDCConfiguration(
        issuerURL: "https://login.example.com", clientID: "public-client", scopes: "openid profile offline_access",
        redirectURI: "dicomweb-test://oauth2/callback")

    private static let discoveryDocument = Data(
        #"{"issuer":"https://login.example.com","authorization_endpoint":"https://login.example.com/oauth/authorize","token_endpoint":"https://login.example.com/oauth/token","jwks_uri":"https://login.example.com/oauth/jwks","code_challenge_methods_supported":["S256"],"id_token_signing_alg_values_supported":["ES256"]}"#.utf8
    )

    private static func tokens(access: String, refresh: String?, expiresAt: Date) -> DicomWebOIDCTokenSet {
        DicomWebOIDCTokenSet(accessToken: access, refreshToken: refresh, tokenType: "Bearer", expiresAt: expiresAt,
                             configuration: configuration)
    }

    private static func tokenResponse(access: String, refresh: String?, idToken: String? = nil) -> Data {
        var body: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": 3600]
        if let refresh { body["refresh_token"] = refresh }
        if let idToken { body["id_token"] = idToken }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func idToken(key: P256.Signing.PrivateKey, keyID: String, nonce: String, accessToken: String,
                                now: Date) throws -> String {
        let accessDigest = Array(SHA256.hash(data: Data(accessToken.utf8)))
        let claims: [String: Any] = [
            "iss": "https://login.example.com", "aud": "public-client", "sub": "user-1",
            "exp": now.timeIntervalSince1970 + 300, "iat": now.timeIntervalSince1970, "nonce": nonce,
            "at_hash": Data(accessDigest.prefix(accessDigest.count / 2)).base64URL
        ]
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"]).base64URL
        let signingInput = "\(header).\(try JSONSerialization.data(withJSONObject: claims).base64URL)"
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation.base64URL
        return "\(signingInput).\(signature)"
    }

    private static func jwks(_ keys: [(String, P256.Signing.PrivateKey)]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["keys": keys.map { keyID, key -> [String: String] in
            let point = key.publicKey.x963Representation
            return ["kty": "EC", "kid": keyID, "use": "sig", "alg": "ES256", "crv": "P-256",
                    "x": Data(point[1..<33]).base64URL, "y": Data(point[33..<65]).base64URL]
        }])
    }

    private static func queryValues(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private static func response(for request: URLRequest, body: Data) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                         headerFields: ["Content-Type": "application/json"])!, body)
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private final class OIDCStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MemoryTokenStore: DicomWebOIDCTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokensByKey: [String: DicomWebOIDCTokenSet] = [:]

    func tokens(forKey key: String) throws -> DicomWebOIDCTokenSet? { lock.withLock { tokensByKey[key] } }
    func store(_ tokens: DicomWebOIDCTokenSet, forKey key: String) throws { lock.withLock { tokensByKey[key] = tokens } }
    func deleteTokens(forKey key: String) throws { _ = lock.withLock { tokensByKey.removeValue(forKey: key) } }
}

/// A DICOMweb archive that answers an empty QIDO result to `accepted` and 401 to any other Authorization.
private final class BearerArchive: DicomWebHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let accepted: String?
    private var received: [String] = []

    init(accepted: String?) { self.accepted = accepted }

    var authorizations: [String] { lock.withLock { received } }

    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        let authorization = request.headers["Authorization"] ?? ""
        lock.withLock { received.append(authorization) }
        guard authorization == accepted else { return .init(statusCode: 401) }
        return .init(statusCode: 200, headers: ["Content-Type": "application/dicom+json"], body: Data("[]".utf8))
    }
}

private final class OIDCRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(path: String) { lock.withLock { counts[path, default: 0] += 1 } }
    func count(for path: String) -> Int { lock.withLock { counts[path, default: 0] } }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String = "") { stored = value }
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ value: Date) { stored = value }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
