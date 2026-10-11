import Foundation
import XCTest
@testable import DicomCore

/// Strong ETags, Vary: Accept and conditional GET on search and retrieve (RFC 9110, issue #3033).
final class DicomWebServerEntityTagTests: XCTestCase {
    private let json = "application/dicom+json"
    private let xml = "multipart/related; type=\"application/dicom+xml\""

    func test_repeatedGETWithTheSameAccept_is304WithoutABody() async throws {
        let server = DicomWebServer(store: try Self.store())
        for (path, accept) in [("studies", json), ("studies/2.25.1/metadata", json), ("studies/2.25.1/metadata", xml),
                               ("studies/2.25.1/series/2.25.1.2/instances/2.25.3", "multipart/related; type=\"application/dicom\"")] {
            let first = try await server.send(request(path, ["Accept": accept]))
            XCTAssertEqual(first.statusCode, 200, path)
            let tag = try XCTUnwrap(first.headers["ETag"], path)
            XCTAssertTrue(tag.hasPrefix("\"") && tag.hasSuffix("\""), "a strong tag: \(tag)")
            XCTAssertEqual(first.headers["Vary"], "Accept", path)
            XCTAssertNil(first.headers["Cache-Control"], "unauthenticated responses are not private")

            let second = try await server.send(request(path, ["Accept": accept, "If-None-Match": tag]))
            XCTAssertEqual(second.statusCode, 304, path)
            XCTAssertTrue(second.body.isEmpty, path)
            XCTAssertEqual(second.headers["ETag"], tag, path)
            let wildcard = try await server.send(request(path, ["Accept": accept, "If-None-Match": "*"]))
            XCTAssertEqual(wildcard.statusCode, 304, path)
            let other = try await server.send(request(path, ["Accept": accept, "If-None-Match": "\"other\""]))
            XCTAssertEqual(other.statusCode, 200, path)
        }
    }

    func test_anotherRepresentation_hasAnotherTag() async throws {
        let server = DicomWebServer(store: try Self.store())
        for path in ["studies/2.25.1/metadata", "studies"] {
            let asJSON = try await server.send(request(path, ["Accept": json]))
            let asXML = try await server.send(request(path, ["Accept": xml]))
            XCTAssertEqual(asJSON.statusCode, 200, path)
            XCTAssertEqual(asXML.statusCode, 200, path)
            XCTAssertNotEqual(asJSON.headers["ETag"], asXML.headers["ETag"], path)
            let crossed = try await server.send(request(path, ["Accept": xml, "If-None-Match": asJSON.headers["ETag"]!]))
            XCTAssertEqual(crossed.statusCode, 200, "a JSON tag must not validate the XML representation")
        }
    }

    func test_STOW_changesTheTagsOfTheAffectedResources() async throws {
        let store = try Self.store()
        let server = DicomWebServer(store: store)
        var before: [String: String] = [:]
        for path in ["studies", "studies/2.25.1/metadata", "studies/2.25.1"] {
            before[path] = try await server.send(request(path)).headers["ETag"]
        }
        let added = try DicomDataSetWriter.part10Data(
            from: DicomWebServerAuthorizationTests.dataSet("2.25.1", instance: "2.25.9"),
            options: DicomPart10WriterOptions(mediaStorageSOPClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage,
                                              mediaStorageSOPInstanceUID: "2.25.9"))
        let client = DicomWebClient(configuration: DicomWebClientConfiguration(baseURL: URL(string: "http://127.0.0.1/dicom-web")!),
                                    transport: server)
        _ = try await client.storeInstances([DicomWebStoreInstance(data: added, transferSyntax: nil)])

        for (path, tag) in before {
            let after = try await server.send(request(path, ["If-None-Match": try XCTUnwrap(tag)]))
            XCTAssertEqual(after.statusCode, 200, "\(path) must not validate against its tag from before the STOW")
            XCTAssertNotEqual(after.headers["ETag"], tag, path)
        }
    }

    func test_unauthorizedRequests_neverBecome304() async throws {
        let bearer = DicomWebServer(store: try Self.store(), authentication: DicomWebBearerAuthentication(token: "synthetic"),
                                    authorizer: AuthorizationTestPolicy())
        let authorized = try await bearer.send(request("studies/2.25.1/metadata", ["Authorization": "Bearer synthetic"]))
        XCTAssertEqual(authorized.statusCode, 200)
        XCTAssertEqual(authorized.headers["Cache-Control"], "private")
        let tag = try XCTUnwrap(authorized.headers["ETag"])
        let anonymous = try await bearer.send(request("studies/2.25.1/metadata", ["If-None-Match": tag]))
        XCTAssertEqual(anonymous.statusCode, 401)
        let revalidated = try await bearer.send(request("studies/2.25.1/metadata",
            ["Authorization": "Bearer synthetic", "If-None-Match": tag]))
        XCTAssertEqual(revalidated.statusCode, 304)
        XCTAssertEqual(revalidated.headers["Cache-Control"], "private")

        let policy = AuthorizationTestPolicy()
        await policy.deny("2.25.1")
        let denied = DicomWebServer(store: try Self.store(), principals: AuthorizationTestPrincipals(), authorizer: policy)
        for path in ["studies/2.25.1/series/2.25.1.2/instances/2.25.3", "studies/2.25.1/series/2.25.1.2/instances/2.25.3/frames/1"] {
            let response = try await denied.send(request(path, ["If-None-Match": "*"]))
            XCTAssertEqual(response.statusCode, 403, path)
        }
    }

    private func request(_ path: String, _ headers: [String: String] = [:]) -> DicomWebHTTPRequest {
        .init(method: .get, url: URL(string: "http://127.0.0.1/dicom-web/" + path)!, headers: headers)
    }

    private static func store() throws -> DicomWebInMemoryStore {
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: DicomWebServerAuthorizationTests.dataSet())
        return store
    }
}
