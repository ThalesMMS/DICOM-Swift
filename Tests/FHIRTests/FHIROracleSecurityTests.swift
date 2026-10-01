import DicomCore
import Foundation
import HL7v3Transport
import XCTest
@testable import FHIR

final class FHIROracleSecurityTests: XCTestCase {
    private let lab = HL7v3TransportPolicy(timeout: 5, allowInsecureForHosts: ["127.0.0.1"])

    private func authorized(_ server: FHIROracleServer, scopes: String) async throws -> FHIRClient {
        let configuration = try await SMARTDiscovery(policy: lab).discover(issuer: server.baseURL)
        let client = SMARTClientConfiguration(clientID: "isis-app", redirectURI: URL(string: "http://127.0.0.1/callback")!,
                                              scopes: SMARTScope.parse(scopes), audience: server.baseURL)
        let (url, pending) = try SMARTAuthorizationRequest.make(client: client, server: configuration)
        let response = try await HL7v3URLSessionTransport().send(DicomWebHTTPRequest(method: .get, url: url, timeout: 5))
        XCTAssertEqual(response.statusCode, 302)
        let location = try XCTUnwrap(response.headers.first { $0.key.lowercased() == "location" }?.value)
        let code = try SMARTAuthorizationRequest.parseRedirect(try XCTUnwrap(URL(string: location)), client: client, pending: pending)
        let token = try await SMARTTokenClient(server: configuration, client: client, policy: lab).exchange(code: code, pending: pending)
        return server.client { ["Authorization": "Bearer " + token.accessToken] }
    }

    private func observation(_ id: String, patient: String) throws -> FHIRResource {
        try FHIRResource(jsonData: Data("""
        {"resourceType":"Observation","id":"\(id)","status":"final","code":{"text":"synthetic"},"subject":{"reference":"Patient/\(patient)"}}
        """.utf8))
    }

    func test_transactionFailure_rollsBackCreatesUpdatesDeletesAndIDs() async throws {
        let failures = [
            FHIRBundleEntry(request: FHIRBundleRequest(method: "PATCH", url: "Patient/original")),
            FHIRBundleEntry(request: FHIRBundleRequest(method: "GET", url: "Patient/missing")),
            FHIRBundleEntry(resource: FHIRPatient(id: "wrong-id").resource, request: FHIRBundleRequest(method: "PUT", url: "Patient/original"))
        ]
        for failure in failures {
            let server = try await FHIROracleServer.start()
            defer { server.stop() }
            let client = server.client()
            var original = FHIRPatient(id: "original"); original.gender = "female"
            _ = try await client.update(original.resource).get()
            var changed = original; changed.gender = "male"
            let entries = [
                FHIRBundleEntry(fullUrl: "urn:uuid:new-patient", resource: FHIRPatient().resource, request: FHIRBundleRequest(method: "POST", url: "Patient")),
                FHIRBundleEntry(request: FHIRBundleRequest(method: "DELETE", url: "Patient/original")),
                FHIRBundleEntry(resource: changed.resource, request: FHIRBundleRequest(method: "PUT", url: "Patient/original")), failure
            ]
            let rejected = try await client.transaction(FHIRBundle(type: "transaction", entries: entries))
            XCTAssertNotNil(rejected.failure)
            let read = try await client.read("Patient", id: "original").get()
            XCTAssertEqual(read?.as(FHIRPatient.self)?.gender, "female")
            let history = try await client.history("Patient", id: "original").get()
            XCTAssertEqual(history.entries.count, 1)
            let patients = try await client.search(FHIRSearchQuery(resourceType: "Patient")).get()
            XCTAssertEqual(patients.matches.map(\.id), ["original"])
            let created = try await client.create(FHIRPatient().resource).get()
            XCTAssertEqual(created?.id, "1", "failed transactions must not consume IDs")
        }
    }

    func test_bundleEntries_enforceResourceAndActionScopes() async throws {
        let server = try await FHIROracleServer.start(behaviors: ["smart": ["require_bearer": true]])
        defer { server.stop() }
        let admin = try await authorized(server, scopes: "user/*.cruds")
        let patient = FHIRPatient(id: "example").resource
        let observation = try observation("obs", patient: "example")
        _ = try await admin.update(patient).get()
        _ = try await admin.update(observation).get()
        for scope in ["user/Patient.read", "user/Patient.rs"] {
            let limited = try await authorized(server, scopes: scope)
            let entries = [
                FHIRBundleEntry(request: FHIRBundleRequest(method: "GET", url: "Patient/example")),
                FHIRBundleEntry(resource: patient, request: FHIRBundleRequest(method: "POST", url: "Patient")),
                FHIRBundleEntry(resource: patient, request: FHIRBundleRequest(method: "PUT", url: "Patient/example")),
                FHIRBundleEntry(request: FHIRBundleRequest(method: "DELETE", url: "Patient/example")),
                FHIRBundleEntry(request: FHIRBundleRequest(method: "GET", url: "Observation/obs")),
                FHIRBundleEntry(resource: observation, request: FHIRBundleRequest(method: "POST", url: "Observation"))
            ]
            let batch = try await limited.transaction(FHIRBundle(type: "batch", entries: entries)).get()
            XCTAssertEqual(batch.entries.map { $0.response?.statusCode }, [200, 403, 403, 403, 403, 403])
            let transaction = try await limited.transaction(FHIRBundle(type: "transaction", entries: entries))
            XCTAssertEqual(transaction.failure?.status, 403)
            let directWrite = try await limited.update(patient)
            XCTAssertEqual(directWrite.failure?.status, 403)
        }
        let history = try await admin.history("Patient", id: "example").get()
        XCTAssertEqual(history.entries.count, 1)
    }

    func test_patientScopes_filterReadsSearchIncludesAndHistory() async throws {
        let server = try await FHIROracleServer.start(behaviors: ["smart": ["require_bearer": true, "patient": "example"]])
        defer { server.stop() }
        let admin = try await authorized(server, scopes: "user/*.cruds")
        for id in ["example", "other"] {
            _ = try await admin.update(FHIRPatient(id: id).resource).get()
            _ = try await admin.update(observation("obs-" + id, patient: id)).get()
        }
        let limited = try await authorized(server, scopes: "patient/Patient.rs patient/Observation.rs")
        let own = try await limited.read("Patient", id: "example")
        XCTAssertEqual(own.metadata?.status, 200)
        for (type, id) in [("Patient", "other"), ("Observation", "obs-other")] {
            let read = try await limited.read(type, id: id)
            let version = try await limited.vread(type, id: id, version: "1")
            let history = try await limited.history(type, id: id)
            XCTAssertEqual(read.failure?.status, 403)
            XCTAssertEqual(version.failure?.status, 403)
            XCTAssertEqual(history.failure?.status, 403)
        }
        let patients = try await limited.searchByPost(FHIRSearchQuery(resourceType: "Patient")).get()
        XCTAssertEqual(patients.matches.map(\.id), ["example"])
        let observations = try await limited.search(FHIRSearchQuery(resourceType: "Observation").include("Observation", "subject")).get()
        XCTAssertEqual(observations.matches.map(\.id), ["obs-example"])
        XCTAssertEqual(observations.included.map(\.id), ["example"])
        let reversed = try await limited.search(FHIRSearchQuery(resourceType: "Patient").revInclude("Observation", "subject")).get()
        XCTAssertEqual(reversed.included.map(\.id), ["obs-example"])
        for type in ["Patient", "Observation", nil] {
            let history = try await limited.history(type).get()
            XCTAssertFalse(history.entries.isEmpty)
            XCTAssertTrue(history.entries.allSatisfy { ["example", "obs-example"].contains($0.resource?.id ?? "") })
        }
        let batch = try await limited.transaction(FHIRBundle(type: "batch", entries: [
            FHIRBundleEntry(request: FHIRBundleRequest(method: "GET", url: "Patient/other")),
            FHIRBundleEntry(request: FHIRBundleRequest(method: "GET", url: "Observation/obs-example"))
        ])).get()
        XCTAssertEqual(batch.entries.map { $0.response?.statusCode }, [403, 200])
    }

    func test_authorizationRedirect_validatesParsedAuthorityAndRegisteredPath() async throws {
        for (prefix, valid) in [("http://127.0.0.1", "http://127.0.0.1:8123/callback"),
                                ("http://127.0.0.1:8123/callback", "http://127.0.0.1:8123/callback"),
                                ("isis://callback", "isis://callback"),
                                ("https://client.example.test/callback", "https://client.example.test/callback")] {
            let server = try await FHIROracleServer.start(behaviors: ["smart": ["redirect_prefix": prefix]])
            defer { server.stop() }
            let invalid = ["http://127.0.0.1.evil.example/callback", "http://127.0.0.1@evil.example/callback", "http://127.0.0.1/callback#fragment",
                           "isis://callback.evil", "https://client.example.test/callback.evil"] +
                (prefix.contains("8123") ? ["http://127.0.0.1:8124/callback", "http://127.0.0.1:8123/callback.evil"] : [])
            for redirect in invalid + [valid] {
                var url = URLComponents(url: server.baseURL.appendingPathComponent("auth/authorize"), resolvingAgainstBaseURL: false)!
                url.queryItems = [URLQueryItem(name: "client_id", value: "isis-app"), URLQueryItem(name: "response_type", value: "code"),
                                  URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "code_challenge", value: "test"),
                                  URLQueryItem(name: "state", value: "test-state"), URLQueryItem(name: "redirect_uri", value: redirect)]
                let response = try await HL7v3URLSessionTransport().send(DicomWebHTTPRequest(method: .get, url: url.url!, timeout: 5))
                XCTAssertEqual(response.statusCode, invalid.contains(redirect) ? 400 : 302, redirect)
                if invalid.contains(redirect) { XCTAssertNil(response.headers.first { $0.key.lowercased() == "location" }) }
            }
        }
    }

    func test_webhookRegistration_requiresExplicitLoopbackOrigin() async throws {
        let server = try await FHIROracleServer.start(behaviors: ["webhook_origins": ["http://127.0.0.1:8123", "http://127.0.0.1"]])
        defer { server.stop() }
        let manager = FHIRSubscriptionManager(client: server.client())
        for endpoint in ["http://127.0.0.1:8124/hook", "http://127.0.0.1.evil.example/hook", "http://169.254.169.254/hook",
                         "http://10.0.0.1/hook", "https://example.test/hook", "file:///tmp/hook", "http://user@127.0.0.1:8123/hook", "http://127.0.0.1:0/hook"] {
            let rejected = try await manager.create(criteria: "Observation", endpoint: endpoint)
            XCTAssertEqual(rejected.failure?.status, 400, endpoint)
        }
        let allowed = try await manager.create(criteria: "Observation", endpoint: "http://127.0.0.1:8123/hook")
        XCTAssertEqual(allowed.metadata?.status, 201)
    }

    func test_webhookDelivery_doesNotFollowRedirects() async throws {
        let destination = FHIRClientBehaviorTests.StubServer { _, _ in (200, [:], Data()) }
        let destinationURL = try await destination.start()
        addTeardownBlock { await destination.stop() }
        let redirect = FHIRClientBehaviorTests.StubServer { _, _ in (302, ["Location": destinationURL.absoluteString + "/sink"], Data()) }
        let redirectURL = try await redirect.start()
        addTeardownBlock { await redirect.stop() }
        let server = try await FHIROracleServer.start(behaviors: ["webhook_origins": [redirectURL.absoluteString]])
        defer { server.stop() }
        let manager = FHIRSubscriptionManager(client: server.client())
        let subscription = try await manager.create(criteria: "Observation", endpoint: redirectURL.absoluteString + "/hook").get()
        _ = try await server.client().create(observation("obs", patient: "example")).get()
        let deadline = ContinuousClock.now + .seconds(3)
        var status: String?
        while ContinuousClock.now < deadline {
            status = try await manager.status(id: try XCTUnwrap(subscription.id)).get().status
            if status == "error" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(status, "error")
        XCTAssertEqual(redirect.received.count, 1)
        XCTAssertTrue(destination.received.isEmpty)
    }
}
