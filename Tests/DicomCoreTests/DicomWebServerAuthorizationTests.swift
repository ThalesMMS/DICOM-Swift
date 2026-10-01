import Foundation
import XCTest
@testable import DicomCore

actor AuthorizationTestPolicy: DicomAuthorizing {
    let policyVersion: Int64 = 0
    var denied: Set<String> = []
    var unavailable = false
    var calls: [DicomResourceRef] = []
    var principals: [DicomPrincipal?] = []
    func deny(_ id: String) { denied.insert(id) }
    func setUnavailable() { unavailable = true }
    func decide(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
                context: DicomAccessContext) -> DicomAuthorizationDecision {
        calls.append(resource); principals.append(principal)
        let reason: DicomAuthorizationDecision.Reason = unavailable ? .policyUnavailable
            : principal == nil || principal?.kind == .anonymous ? .noPrincipal
            : ([resource] + resource.ancestry).contains(where: { denied.contains($0.id) }) ? .resourceRestricted : .allowed
        return .init(outcome: reason == .allowed ? .allow : .deny, reason: reason,
                     policyVersion: 0, recheckInterval: 30, evaluatedAt: context.at)
    }
}

func authorizationPrincipal() -> DicomPrincipal {
    .init(id: "synthetic-user", kind: .localUser, source: .local, scopes: ["export"],
          sessionID: "synthetic-session", authenticatedAt: Date().addingTimeInterval(-1), policyVersion: 0)
}

struct AuthorizationTestPrincipals: DicomWebPrincipalResolving {
    func principal(for request: DicomWebHTTPRequest) async -> DicomPrincipal? { authorizationPrincipal() }
}

final class DicomWebServerAuthorizationTests: XCTestCase, @unchecked Sendable {
    static func dataSet(_ study: String = "2.25.1", instance: String = "2.25.3") -> DicomDataSet {
        .init(elements: [
            a2String(0x0020000D, .UI, study), a2String(0x0020000E, .UI, study + ".2"),
            a2String(0x00080018, .UI, instance),
            a2String(0x00080016, .UI, DicomStorageSOPClassUIDs.secondaryCaptureImageStorage),
            a2String(0x00100010, .PN, "SYNTHETIC^AUTHORIZATION"), a2String(0x00080060, .CS, "OT")
        ])
    }
    func request(_ path: String = "studies", headers: [String: String] = [:]) -> DicomWebHTTPRequest {
        .init(method: .get, url: URL(string: "http://127.0.0.1/dicom-web/" + path)!, headers: headers)
    }
    func test_anonymousRequired_returns401() async throws {
        let response = try await DicomWebServer(authorizer: AuthorizationTestPolicy()).send(request())
        XCTAssertEqual(response.statusCode, 401)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("SYNTHETIC"))
    }
    func test_bearer_resolvesVerifiedServicePrincipal() async throws {
        let policy = AuthorizationTestPolicy()
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.dataSet())
        let server = DicomWebServer(store: store, authentication: DicomWebBearerAuthentication(token: "synthetic"), authorizer: policy)
        let response = try await server.send(request(headers: ["Authorization": "Bearer synthetic"]))
        XCTAssertEqual(response.statusCode, 200)
        let principal = await policy.principals.first!
        XCTAssertEqual(principal?.kind, .serviceAccount)
        XCTAssertEqual(principal?.source, .bearer)
        XCTAssertNotEqual(principal?.id, "synthetic")
    }
    func test_search_filtersBeforePaginationAndEmptyIs200() async throws {
        let policy = AuthorizationTestPolicy()
        await policy.deny("2.25.1")
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.dataSet())
        try store.add(dataSet: Self.dataSet("2.25.4", instance: "2.25.6"))
        let server = DicomWebServer(store: store, principals: AuthorizationTestPrincipals(), authorizer: policy)
        let response = try await server.send(request("studies?limit=1"))
        XCTAssertEqual(response.statusCode, 200)
        let sets = try DicomJSONCodec.decode(response.body)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.dataSet.string(for: .studyInstanceUID), "2.25.4")
        await policy.deny("2.25.4")
        let empty = try await server.send(request())
        XCTAssertEqual(empty.statusCode, 200)
        XCTAssertEqual(String(decoding: empty.body, as: UTF8.self), "[]")
    }
    func test_missingMetadataWithoutAuthorizer_remainsNotFound() async throws {
        let response = try await DicomWebServer().send(request("studies/2.25.404/metadata"))
        XCTAssertEqual(response.statusCode, 404)
    }
    func test_restrictedInstanceAndTransferSyntax_cannotBypassStudy() async throws {
        let policy = AuthorizationTestPolicy()
        await policy.deny("2.25.1")
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.dataSet())
        let server = DicomWebServer(store: store, principals: AuthorizationTestPrincipals(), authorizer: policy)
        for path in ["studies/2.25.1/series/2.25.1.2/instances/2.25.3",
                     "wado?requestType=WADO&studyUID=2.25.1&seriesUID=2.25.1.2&objectUID=2.25.3&contentType=application/dicom"] {
            let response = try await server.send(request(path,
                headers: ["Accept": "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1"]))
            XCTAssertEqual(response.statusCode, 403)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("SYNTHETIC"))
        }
        let representation = DicomAuthorizedRepresentationAccess(representationID: "alternate",
            instance: .instance(study: "2.25.1", series: "2.25.1.2", instance: "2.25.3"))
        let decision = await representation.decide(principal: authorizationPrincipal(), authorizer: policy,
                                                   context: .init(protocol: .dicomweb))
        XCTAssertEqual(decision.outcome, .deny)
    }
    func test_revokedMidStream_stopsBeforePayload() async throws {
        let policy = AuthorizationTestPolicy()
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.dataSet())
        let server = DicomWebServer(store: store, principals: AuthorizationTestPrincipals(), authorizer: policy)
        let response = try await server.stream(request("studies/2.25.1"))
        XCTAssertEqual(response.statusCode, 200)
        var iterator = response.body.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNotNil(first)
        await policy.deny("2.25.1")
        do { _ = try await iterator.next(); XCTFail("Revoked stream continued") } catch {}
    }
    func test_unavailableAuthorizer_returns503WithoutDisclosure() async throws {
        let policy = AuthorizationTestPolicy()
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.dataSet())
        let server = DicomWebServer(store: store, principals: AuthorizationTestPrincipals(),
            authorizer: DicomFailClosedAuthorizer(wrapping: policy, isAvailable: { false }))
        let response = try await server.send(request())
        XCTAssertEqual(response.statusCode, 503)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("SYNTHETIC"))
    }
    func test_failingAuditFailClosed_returns503() async throws {
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.dataSet())
        let server = DicomWebServer(store: store, principals: AuthorizationTestPrincipals(),
            authorizer: AuthorizationTestPolicy(), audit: .init(sinks: [], policy: .failClosed))
        let response = try await server.send(request())
        XCTAssertEqual(response.statusCode, 503)
    }
    func test_workitemStateAndCancel_authorizeBeforeMutation() async throws {
        let uid = "2.25.2352"
        let state = DicomDataSet(elements: [upsString(0x00741000, "IN PROGRESS"),
            upsString(0x00081195, "2.25.1", .UI)])
        let routes: [(DicomWebHTTPMethod, String, DicomDataSet, Int)] = [
            (.put, "state", state, 200), (.post, "cancelrequest", .init(), 202)
        ]
        for denied in [false, true] {
            for (method, suffix, payload, success) in routes {
                let policy = AuthorizationTestPolicy()
                if denied { await policy.deny(uid) }
                let store = DicomInMemoryUnifiedProcedureStepStore()
                try store.transaction(sopInstanceUID: uid) { $0 = upsRecord(.scheduled) }
                let service = DicomUnifiedProcedureStepService(store: store)
                let server = DicomWebServer(unifiedProcedureSteps: service,
                    principals: AuthorizationTestPrincipals(), authorizer: policy)
                let response = try await server.send(.init(method: method,
                    url: URL(string: "http://127.0.0.1/dicom-web/workitems/\(uid)/\(suffix)")!,
                    headers: ["Content-Type": "application/dicom+json"],
                    body: try DicomJSONCodec.encode([payload])))
                XCTAssertEqual(response.statusCode, denied ? 403 : success, suffix)
                if denied {
                    let result = try service.get(sopInstanceUID: uid)
                    XCTAssertEqual(result.dataSet?.string(for: 0x00741000), "SCHEDULED", suffix)
                }
                let calls = await policy.calls
                XCTAssertTrue(calls.contains { $0.kind == .workitem && $0.id == uid }, suffix)
            }
        }
    }
    func test_nonLoopbackExposure_refusesLocalOnlyAndAllowsExplicitLab() async throws {
        do {
            try await DicomWebServer(exposure: .defaults(for: .localOnly))
                .validateExposure(bindAddress: "0.0.0.0", tlsEnabled: false)
            XCTFail("Unprotected exposure accepted")
        } catch is DicomExposureValidationError {}
        let server = DicomWebServer(exposure: .init(mode: .intranetLab, requireTLS: false,
            requireAuthentication: true, allowUnauthorizedIntranetLab: true))
        try await server.validateExposure(bindAddress: "0.0.0.0", tlsEnabled: false)
    }
}

private actor UnauthorizedRepresentationProbe: DicomRepresentationResolving {
    var reads = 0
    func representations(for sourceSOPInstanceUID: String) -> DicomRepresentationSet? { reads += 1; return nil }
    func bytes(for representation: DicomArchiveRepresentation) throws -> Data {
        reads += 1; throw DicomRepresentationRefusal.missingBytes
    }
}

extension DicomWebServerAuthorizationTests {
    func test_restrictedSourceDeniedBeforeRepresentationResolver() async throws {
        let policy = AuthorizationTestPolicy()
        await policy.deny("2.25.1")
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.dataSet())
        let resolver = UnauthorizedRepresentationProbe()
        let server = DicomWebServer(store: store, representationResolver: resolver,
            principals: AuthorizationTestPrincipals(), authorizer: policy)
        let response = try await server.send(request("studies/2.25.1/series/2.25.1.2/instances/2.25.3",
            headers: ["Accept": "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1"]))
        XCTAssertEqual(response.statusCode, 403)
        let reads = await resolver.reads
        XCTAssertEqual(reads, 0)
    }
}
