import DicomCore
import Foundation
import HL7v3Transport
import XCTest
@testable import FHIR

/// SMART App Launch against the loopback issuer of the Python oracle (authorize, token, revoke,
/// bearer-protected FHIR endpoints).
final class SMARTTests: XCTestCase {
    private let lab = HL7v3TransportPolicy(timeout: 5, allowInsecureForHosts: ["127.0.0.1"])

    func test_jwksEndpoint_requiresSecureAllowedOrigin() throws {
        let issuer = URL(string: "https://auth.example.test")!
        var server = SMARTServerConfiguration(issuer: issuer, authorizationEndpoint: issuer.appendingPathComponent("authorize"),
                                              tokenEndpoint: issuer.appendingPathComponent("token"), jwksURI: issuer.appendingPathComponent("jwks"))
        XCTAssertNoThrow(try server.validate(policy: .init()))
        server.jwksURI = URL(string: "http://auth.example.test/jwks")!
        XCTAssertThrowsError(try server.validate(policy: .init())) {
            XCTAssertEqual($0 as? SMARTAuthorizationError, .insecureEndpoint("jwks_uri"))
        }
        server.jwksURI = URL(string: "https://keys.example.test/jwks")!
        XCTAssertThrowsError(try server.validate(policy: .init()))
        XCTAssertNoThrow(try server.validate(policy: .init(), allowedOrigins: ["https://keys.example.test"]))
    }

    func test_refresh_preservesOmittedContextAndUsesReturnedContext() async throws {
        for returnsContext in [false, true] {
            let body = Data((returnsContext
                ? #"{"access_token":"new","token_type":"Bearer","patient":"p2","encounter":"e2","fhirUser":"Practitioner/u2"}"#
                : #"{"access_token":"new","token_type":"Bearer"}"#).utf8)
            let endpoint = FHIRClientBehaviorTests.StubServer { _, _ in (200, ["Content-Type": "application/json"], body) }
            addTeardownBlock { await endpoint.stop() }
            let url = try await endpoint.start()
            let configuration = SMARTServerConfiguration(issuer: url, authorizationEndpoint: url, tokenEndpoint: url)
            let client = SMARTClientConfiguration(clientID: "isis-app", redirectURI: URL(string: "http://127.0.0.1/callback")!, scopes: [], audience: url)
            let original = SMARTToken(accessToken: "old", refreshToken: "refresh", patient: "p1", encounter: "e1", fhirUser: "Practitioner/u1")
            let refreshed = try await SMARTTokenClient(server: configuration, client: client, policy: lab).refresh(original)
            XCTAssertEqual(refreshed.patient, returnsContext ? "p2" : "p1")
            XCTAssertEqual(refreshed.encounter, returnsContext ? "e2" : "e1")
            XCTAssertEqual(refreshed.fhirUser, returnsContext ? "Practitioner/u2" : "Practitioner/u1")
        }
    }

    func test_postSearch_acceptsReadScopeWhileCreateRequiresWriteScope() async throws {
        let server = try await smartServer()
        defer { server.stop() }
        let configuration = try await SMARTDiscovery(policy: lab).discover(issuer: server.baseURL)
        let client = client(server, scopes: [.patient("Patient")])
        let (url, pending) = try SMARTAuthorizationRequest.make(client: client, server: configuration)
        let code = try SMARTAuthorizationRequest.parseRedirect(try await consent(url), client: client, pending: pending)
        let token = try await SMARTTokenClient(server: configuration, client: client, policy: lab).exchange(code: code, pending: pending)
        let fhir = server.client { ["Authorization": "Bearer " + token.accessToken] }
        let search = try await fhir.searchByPost(FHIRSearchQuery(resourceType: "Patient"))
        XCTAssertEqual(search.metadata?.status, 200)
        let create = try await fhir.create(FHIRPatient(id: "example").resource)
        XCTAssertEqual(create.failure?.status, 403)
    }

    private func smartServer(_ extra: [String: Any] = [:]) async throws -> FHIROracleServer {
        var smart: [String: Any] = ["require_bearer": true, "client_id": "isis-app", "patient": "example"]
        for (key, value) in extra { smart[key] = value }
        return try await FHIROracleServer.start(behaviors: ["smart": smart])
    }

    private func client(_ server: FHIROracleServer, scopes: [SMARTScope] = [.openid, .fhirUser, .launchPatient, .offlineAccess, .patient("Patient", .all), .patient("Observation")],
                        secret: String? = nil) -> SMARTClientConfiguration {
        SMARTClientConfiguration(clientID: "isis-app", redirectURI: URL(string: "http://127.0.0.1/callback")!, scopes: scopes, audience: server.baseURL,
                                 clientSecret: secret.map { value in { @Sendable in value } })
    }

    /// Simulates the browser: the authorize endpoint answers 302 and the transport never follows it.
    private func consent(_ url: URL) async throws -> URL {
        let response = try await HL7v3URLSessionTransport().send(DicomWebHTTPRequest(method: .get, url: url, timeout: 5))
        XCTAssertEqual(response.statusCode, 302)
        let location = try XCTUnwrap(response.headers.first { $0.key.lowercased() == "location" }?.value)
        return try XCTUnwrap(URL(string: location))
    }

    private func log(_ server: FHIROracleServer) async throws -> [[String: Any]] {
        let data = try await FHIRClient(baseURL: server.baseURL, policy: lab).fetch(url: server.baseURL.appendingPathComponent("auth/_log")).get()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["entries"] as? [[String: Any]] ?? []
    }

    func test_standaloneLaunch_discoveryPKCEExchangeAndBearerAccess() async throws {
        let server = try await smartServer()
        defer { server.stop() }
        let configuration = try await SMARTDiscovery(policy: lab).discover(issuer: server.baseURL)
        XCTAssertEqual(configuration.tokenEndpoint.path, "/auth/token")
        XCTAssertTrue(configuration.capabilities.contains("launch-standalone"))
        let client = client(server)
        let (url, pending) = try SMARTAuthorizationRequest.make(client: client, server: configuration)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(query.first { $0.name == "code_challenge" }?.value, pending.codeChallenge)
        XCTAssertNotNil(query.first { $0.name == "nonce" })
        XCTAssertNil(query.first { $0.name == "client_secret" })
        let redirect = try await consent(url)
        let code = try SMARTAuthorizationRequest.parseRedirect(redirect, client: client, pending: pending)
        let session = SMARTSession(tokenClient: SMARTTokenClient(server: configuration, client: client, policy: lab))
        let token = try await session.complete(code: code, pending: pending)
        XCTAssertEqual(token.patient, "example")
        XCTAssertNotNil(token.refreshToken)
        XCTAssertTrue(SMARTScope.patient("Observation").isCovered(by: token.scopes))
        let claims = try SMARTIDTokenClaims(idToken: try XCTUnwrap(token.idToken))
        XCTAssertEqual(claims.nonce, pending.nonce)
        XCTAssertEqual(claims.audience, ["isis-app"])

        let unauthenticated = try await FHIRClient(baseURL: server.baseURL, policy: lab).read("Patient", id: "example")
        XCTAssertEqual(unauthenticated.failure?.status, 401)
        let fhir = FHIRClient(baseURL: server.baseURL, policy: lab) { try await session.authorizationHeaders() }
        var patient = FHIRPatient(id: "example")
        patient.gender = "female"
        let updated = try await fhir.update(patient.resource)
        XCTAssertEqual(updated.metadata?.status, 201)
        let read = try await fhir.read("Patient", id: "example")
        XCTAssertEqual(read.value??.as(FHIRPatient.self)?.gender, "female")
        let forbidden = try await fhir.read("Practitioner", id: "x")
        XCTAssertEqual(forbidden.failure?.status, 403, "scope covers Patient/Observation only")
        let entries = try await log(server)
        XCTAssertFalse(entries.contains { (($0["query_keys"] as? [String]) ?? []).contains("access_token") }, "tokens never travel in URLs")
        XCTAssertEqual(entries.filter { $0["grant"] as? String == "authorization_code" }.count, 1)
        XCTAssertEqual(entries.first { $0["grant"] as? String == "authorization_code" }?["basic"] as? Bool, false, "public clients send no secret")
    }

    func test_expiredToken_isRefreshedOnceUnderConcurrentCallers() async throws {
        let server = try await smartServer(["token_ttl": 1])
        defer { server.stop() }
        let configuration = try await SMARTDiscovery(policy: lab).discover(issuer: server.baseURL)
        let client = client(server, scopes: [.offlineAccess, .patient("Patient")])
        let (url, pending) = try SMARTAuthorizationRequest.make(client: client, server: configuration)
        let code = try SMARTAuthorizationRequest.parseRedirect(try await consent(url), client: client, pending: pending)
        let session = SMARTSession(tokenClient: SMARTTokenClient(server: configuration, client: client, policy: lab), skew: 0)
        let first = try await session.complete(code: code, pending: pending)
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertTrue(first.isExpired(skew: 0))
        let fhir = FHIRClient(baseURL: server.baseURL, policy: lab) { try await session.authorizationHeaders() }
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 { group.addTask { try await fhir.read("Patient", id: "nope").failure?.status ?? 0 } }
            for try await status in group { XCTAssertEqual(status, 404, "refreshed token is accepted; the resource simply does not exist") }
        }
        let refreshCount = await session.refreshCount
        XCTAssertEqual(refreshCount, 1)
        let refreshes = try await log(server).filter { $0["grant"] as? String == "refresh_token" }
        XCTAssertEqual(refreshes.count, 1, "single-flight refresh")
        let current = await session.currentToken
        XCTAssertNotEqual(current?.accessToken, first.accessToken)
        XCTAssertNotEqual(current?.refreshToken, first.refreshToken, "refresh tokens rotate")
    }

    func test_wrongIssuerInsufficientScopeDeniedConsentAndPKCE() async throws {
        let wrongIssuer = try await smartServer(["issuer_override": "https://other.example.test"])
        defer { wrongIssuer.stop() }
        do {
            _ = try await SMARTDiscovery(policy: lab).discover(issuer: wrongIssuer.baseURL)
            XCTFail("issuer mismatch must be refused")
        } catch { XCTAssertEqual(error as? SMARTAuthorizationError, .issuerMismatch) }
        let insecure = try await smartServer(["insecure_endpoints": true])
        defer { insecure.stop() }
        do {
            _ = try await SMARTDiscovery(policy: lab).discover(issuer: insecure.baseURL)
            XCTFail("endpoints outside the issuer origin must be refused")
        } catch { XCTAssertEqual(error as? SMARTAuthorizationError, .insecureEndpoint("token_endpoint"), "plain-http endpoints are refused before origin checks") }

        let reduced = try await smartServer(["granted_scope": "patient/Patient.rs"])
        defer { reduced.stop() }
        let configuration = try await SMARTDiscovery(policy: lab).discover(issuer: reduced.baseURL)
        let reducedClient = client(reduced, scopes: [.patient("Patient"), .patient("Observation")])
        let (url, pending) = try SMARTAuthorizationRequest.make(client: reducedClient, server: configuration)
        let code = try SMARTAuthorizationRequest.parseRedirect(try await consent(url), client: reducedClient, pending: pending)
        let tokenClient = SMARTTokenClient(server: configuration, client: reducedClient, policy: lab)
        do {
            _ = try await tokenClient.exchange(code: code, pending: pending)
            XCTFail("missing scopes must be reported")
        } catch { XCTAssertEqual(error as? SMARTAuthorizationError, .insufficientScope(missing: ["patient/Observation.rs"])) }

        let (url2, pending2) = try SMARTAuthorizationRequest.make(client: reducedClient, server: configuration)
        let redirect2 = try await consent(url2)
        var tampered = URLComponents(url: redirect2, resolvingAgainstBaseURL: false)!
        tampered.queryItems = tampered.queryItems?.map { $0.name == "state" ? URLQueryItem(name: "state", value: "forged") : $0 }
        XCTAssertThrowsError(try SMARTAuthorizationRequest.parseRedirect(tampered.url!, client: reducedClient, pending: pending2)) {
            XCTAssertEqual($0 as? SMARTAuthorizationError, .stateMismatch)
        }
        let code2 = try SMARTAuthorizationRequest.parseRedirect(redirect2, client: reducedClient, pending: pending2)
        let wrongVerifier = SMARTPendingAuthorization(state: pending2.state, codeVerifier: "not-the-verifier", nonce: nil, createdAt: pending2.createdAt, lifetime: 600, issuer: pending2.issuer)
        do {
            _ = try await tokenClient.exchange(code: code2, pending: wrongVerifier)
            XCTFail("PKCE mismatch must be rejected by the server")
        } catch { XCTAssertEqual(error as? SMARTAuthorizationError, .tokenRequestFailed(status: 400, error: "invalid_grant", description: "pkce")) }

        let denied = try await smartServer(["deny": true])
        defer { denied.stop() }
        let deniedConfiguration = try await SMARTDiscovery(policy: lab).discover(issuer: denied.baseURL)
        let deniedClient = client(denied)
        let (url3, pending3) = try SMARTAuthorizationRequest.make(client: deniedClient, server: deniedConfiguration)
        let deniedRedirect = try await consent(url3)
        XCTAssertThrowsError(try SMARTAuthorizationRequest.parseRedirect(deniedRedirect, client: deniedClient, pending: pending3)) {
            XCTAssertEqual($0 as? SMARTAuthorizationError, .authorizationDenied(error: "access_denied", description: nil))
        }
    }

    func test_confidentialClientRevocationAndCancellation() async throws {
        let server = try await smartServer(["confidential_secret": "s3cret", "token_delay": 0.5])
        defer { server.stop() }
        let configuration = try await SMARTDiscovery(policy: lab).discover(issuer: server.baseURL)
        let client = client(server, scopes: [.offlineAccess, .patient("Patient")], secret: "s3cret")
        XCTAssertTrue(client.isConfidential)
        let (url, pending) = try SMARTAuthorizationRequest.make(client: client, server: configuration)
        let code = try SMARTAuthorizationRequest.parseRedirect(try await consent(url), client: client, pending: pending)
        let tokenClient = SMARTTokenClient(server: configuration, client: client, policy: lab)
        let cancelled = Task { try await tokenClient.exchange(code: code, pending: pending) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("cancelled exchange must not complete")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let (url2, pending2) = try SMARTAuthorizationRequest.make(client: client, server: configuration)
        let code2 = try SMARTAuthorizationRequest.parseRedirect(try await consent(url2), client: client, pending: pending2)
        let store = SMARTInMemoryTokenStore()
        let session = SMARTSession(tokenClient: tokenClient, store: store)
        _ = try await session.complete(code: code2, pending: pending2)
        let restored = SMARTSession(tokenClient: tokenClient, store: store)
        let wasRestored = try await restored.restore()
        XCTAssertTrue(wasRestored)
        let fhir = FHIRClient(baseURL: server.baseURL, policy: lab) { try await restored.authorizationHeaders() }
        let restoredRead = try await fhir.read("Patient", id: "nope")
        XCTAssertEqual(restoredRead.failure?.status, 404)
        try await restored.revoke()
        let afterRevoke = await restored.currentToken
        XCTAssertNil(afterRevoke)
        let stored = try await store.load(issuer: server.baseURL, clientID: "isis-app")
        XCTAssertNil(stored)
        do {
            _ = try await restored.authorizationHeaders()
            XCTFail("revoked session has no token")
        } catch { XCTAssertEqual(error as? SMARTAuthorizationError, .notAuthorized) }
        let entries = try await log(server)
        XCTAssertTrue(entries.contains { $0["path"] as? String == "/auth/revoke" })
        XCTAssertTrue(entries.filter { $0["grant"] as? String == "authorization_code" }.allSatisfy { $0["basic"] as? Bool == true }, "confidential clients authenticate with Basic")
        let tokenRequests = entries.filter { $0["grant"] as? String == "authorization_code" }
        XCTAssertFalse(tokenRequests.isEmpty)
        for entry in tokenRequests {
            let queryKeys = try XCTUnwrap(entry["query_keys"] as? [String])
            XCTAssertFalse(queryKeys.contains("client_secret"))
            XCTAssertFalse(queryKeys.contains { $0.contains("s3cret") })
            XCTAssertEqual(entry["secret_in_query"] as? Bool, false)
        }
    }

    func test_scopeGrammar_v1v2WildcardsAndCoverage() {
        XCTAssertEqual(SMARTScope("patient/Observation.read").permissions, .readOnly)
        XCTAssertEqual(SMARTScope("user/*.write").permissions, .writeOnly)
        XCTAssertEqual(SMARTScope("patient/Patient.cruds").permissions, .all)
        XCTAssertEqual(SMARTScope("patient/Patient.rs?category=vital-signs").permissions?.v2, "rs")
        let granular = SMARTScope("patient/Observation.rs?category=http://loinc.org|8867-4")
        XCTAssertEqual(granular.context, .patient)
        XCTAssertEqual(granular.resourceType, "Observation")
        XCTAssertEqual(granular.permissions, .readOnly)
        XCTAssertNil(SMARTScope("launch/patient").permissions)
        XCTAssertNil(SMARTScope("patient/Patient.xyz").permissions)
        XCTAssertTrue(SMARTScope.patient("Observation").isCovered(by: SMARTScope.parse("patient/*.read openid")))
        XCTAssertTrue(SMARTScope("patient/Observation.rs").isCovered(by: [SMARTScope("patient/Observation.cruds")]))
        XCTAssertFalse(SMARTScope("patient/Observation.c").isCovered(by: [SMARTScope("patient/Observation.rs")]))
        XCTAssertFalse(SMARTScope.patient("Observation").isCovered(by: [SMARTScope.user("Observation")]), "contexts differ")
        XCTAssertEqual(SMARTScope.missing(requested: [.openid, .patient("Patient")], granted: [.patient("Patient")]).map(\.raw), ["openid"])
        XCTAssertEqual(SMARTScope.patient("ImagingStudy", .all).raw, "patient/ImagingStudy.cruds")
        let claims = try? SMARTIDTokenClaims(idToken: "eyJhbGciOiJub25lIn0.eyJpc3MiOiJodHRwczovL3guaW52YWxpZCIsImF1ZCI6ImlzaXMtYXBwIn0.")
        XCTAssertEqual(claims?.algorithm, "none")
        XCTAssertThrowsError(try claims?.validate(issuer: URL(string: "https://x.invalid")!, clientID: "isis-app", nonce: nil)) {
            XCTAssertEqual($0 as? SMARTAuthorizationError, .idTokenInvalid("alg none"))
        }
    }

    func test_idTokenIssuer_requiresExactIssuerIncludingTenantPath() throws {
        let expected = URL(string: "https://auth.example.test/tenant-a")!
        for issuer in [expected.absoluteString, "https://auth.example.test/tenant-b", "https://auth.example.test/tenant-a/", "https://auth.example.test/tenant-a?other=1"] {
            let payload = try JSONSerialization.data(withJSONObject: ["iss": issuer, "aud": "isis-app", "exp": 4_102_444_800] as [String: Any])
            let token = SMARTAuthorizationRequest.base64URL(Data(#"{"alg":"RS256"}"#.utf8)) + "." + SMARTAuthorizationRequest.base64URL(payload) + ".signature"
            let claims = try SMARTIDTokenClaims(idToken: token)
            let discovery = try JSONSerialization.data(withJSONObject: ["issuer": issuer, "authorization_endpoint": expected.appendingPathComponent("authorize").absoluteString, "token_endpoint": expected.appendingPathComponent("token").absoluteString])
            if issuer == expected.absoluteString {
                XCTAssertNoThrow(try claims.validate(issuer: expected, clientID: "isis-app", nonce: nil))
                XCTAssertNoThrow(try SMARTServerConfiguration(discoveryDocument: discovery, expectedIssuer: expected, policy: .init()))
            } else {
                XCTAssertThrowsError(try claims.validate(issuer: expected, clientID: "isis-app", nonce: nil)) {
                    XCTAssertEqual($0 as? SMARTAuthorizationError, .issuerMismatch)
                }
                XCTAssertThrowsError(try SMARTServerConfiguration(discoveryDocument: discovery, expectedIssuer: expected, policy: .init())) {
                    XCTAssertEqual($0 as? SMARTAuthorizationError, .issuerMismatch)
                }
            }
        }
    }

    func test_launchAndRedirect_refuseAnotherTenantOnTheSameOrigin() throws {
        let issuer = URL(string: "https://auth.example.test/tenant-a")!
        let server = SMARTServerConfiguration(issuer: issuer, authorizationEndpoint: issuer.appendingPathComponent("authorize"), tokenEndpoint: issuer.appendingPathComponent("token"))
        var client = SMARTClientConfiguration(clientID: "isis-app", redirectURI: URL(string: "https://app.example.test/callback")!, scopes: [], audience: issuer)
        client.launch = .ehr(launch: "launch-1", iss: URL(string: "https://auth.example.test/tenant-b")!)
        XCTAssertThrowsError(try SMARTAuthorizationRequest.make(client: client, server: server)) {
            XCTAssertEqual($0 as? SMARTAuthorizationError, .issuerMismatch)
        }
        client.launch = .standalone
        let pending = try SMARTAuthorizationRequest.make(client: client, server: server).pending
        var redirect = URLComponents(url: client.redirectURI, resolvingAgainstBaseURL: false)!
        redirect.queryItems = [URLQueryItem(name: "code", value: "code-1"), URLQueryItem(name: "state", value: pending.state), URLQueryItem(name: "iss", value: "https://auth.example.test/tenant-b")]
        XCTAssertThrowsError(try SMARTAuthorizationRequest.parseRedirect(redirect.url!, client: client, pending: pending)) {
            XCTAssertEqual($0 as? SMARTAuthorizationError, .issuerMismatch)
        }
        redirect.queryItems?[2].value = issuer.absoluteString
        XCTAssertEqual(try SMARTAuthorizationRequest.parseRedirect(redirect.url!, client: client, pending: pending), "code-1")
    }
}
