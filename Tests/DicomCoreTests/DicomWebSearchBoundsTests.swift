import Foundation
import XCTest
@testable import DicomCore

final class DicomWebSearchBoundsTests: XCTestCase {
    private func request(_ path: String) -> DicomWebHTTPRequest {
        .init(method: .get, url: URL(string: "http://127.0.0.1/dicom-web/" + path)!)
    }

    func test_authorizedSmallPage_boundsProviderRowsAndAuthorizationCalls() async throws {
        for path in ["studies", "series", "instances"] {
            let storage = DicomWebSearchRecordingStorage()
            let policy = AuthorizationTestPolicy()
            let server = DicomWebServer(storage: storage, principals: AuthorizationTestPrincipals(), authorizer: policy)
            let response = try await server.send(request(path + "?limit=1"))
            XCTAssertEqual(response.statusCode, 200)
            let sets = try DicomJSONCodec.decode(response.body)
            XCTAssertEqual(sets.map { $0.dataSet.string(for: .studyInstanceUID) }, ["2.25.100000"])
            XCTAssertTrue(response.headers["Warning"]?.contains("299") == true)
            let requests = await storage.requests
            XCTAssertTrue(requests.allSatisfy { $0.limit.map { $0 > 0 && $0 <= 2 } == true })
            let returned = await storage.returnedCount
            let calls = await policy.calls.count
            XCTAssertLessThanOrEqual(returned, 2)
            XCTAssertLessThanOrEqual(calls, 2)
        }
    }

    func test_authorizedOffset_skipsDeniedRowsAcrossProviderPages() async throws {
        let storage = DicomWebSearchRecordingStorage()
        let policy = AuthorizationTestPolicy()
        for index in 0..<4 { await policy.deny("2.25.\(index + 100_000)") }
        let server = DicomWebServer(storage: storage, principals: AuthorizationTestPrincipals(), authorizer: policy)
        let response = try await server.send(request("studies?limit=1&offset=1"))
        XCTAssertEqual(response.statusCode, 200)
        let sets = try DicomJSONCodec.decode(response.body)
        XCTAssertEqual(sets.map { $0.dataSet.string(for: .studyInstanceUID) }, ["2.25.100005"])
        let requests = await storage.requests
        XCTAssertGreaterThan(requests.count, 1)
        XCTAssertEqual(requests.first?.offset, 0)
        for (previous, next) in zip(requests, requests.dropFirst()) {
            XCTAssertEqual(try XCTUnwrap(next.offset), try XCTUnwrap(previous.offset) + XCTUnwrap(previous.limit))
        }
        let calls = await policy.calls.count
        XCTAssertEqual(calls, 7)
    }

    func test_deniedTail_exhaustsBudgetWithoutReturningPartialResults() async throws {
        for firstAllowed in [false, true] {
            let storage = DicomWebSearchRecordingStorage()
            let policy = AuthorizationTestPolicy()
            for index in (firstAllowed ? 1 : 0)..<100 { await policy.deny("2.25.\(index + 100_000)") }
            var configuration = DicomWebServerConfiguration()
            configuration.maximumSearchCandidates = 5
            let server = DicomWebServer(configuration: configuration, storage: storage,
                principals: AuthorizationTestPrincipals(), authorizer: policy)
            let response = try await server.send(request("studies?limit=1"))
            XCTAssertEqual(response.statusCode, 413)
            XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("2.25.100000"))
            let calls = await policy.calls.count
            let returned = await storage.returnedCount
            XCTAssertEqual(calls, 5)
            XCTAssertEqual(returned, 5)
        }
    }

    func test_zeroLimitAndExcessiveOffset_doNotFetchCandidates() async throws {
        let storage = DicomWebSearchRecordingStorage()
        let server = DicomWebServer(storage: storage, principals: AuthorizationTestPrincipals(),
                                    authorizer: AuthorizationTestPolicy())
        let empty = try await server.send(request("studies?limit=0"))
        XCTAssertEqual(empty.statusCode, 204)
        XCTAssertTrue(empty.body.isEmpty)
        let excessive = try await server.send(request("studies?limit=1&offset=\(Int.max)"))
        XCTAssertEqual(excessive.statusCode, 413)
        let requests = await storage.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func test_largeLimit_boundsPagesAndDetectsExhaustionWithoutOverflow() async throws {
        let storage = DicomWebSearchRecordingStorage(count: 200)
        var configuration = DicomWebServerConfiguration()
        configuration.maximumSearchResults = Int.max
        let server = DicomWebServer(configuration: configuration, storage: storage)
        let response = try await server.send(request("instances?limit=\(Int.max)"))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(try DicomJSONCodec.decode(response.body).count, 200)
        XCTAssertNil(response.headers["Warning"])
        let requests = await storage.requests
        XCTAssertGreaterThan(requests.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.limit.map { $0 > 0 && $0 <= 128 } == true })
    }
}
