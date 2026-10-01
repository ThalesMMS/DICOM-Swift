import Foundation
import XCTest
@testable import FHIR

final class FHIRSearchQueryTests: XCTestCase {
    func test_query_buildsTypedParametersWithEscapingAndModifiers() {
        let query = FHIRSearchQuery(resourceType: "Observation")
            .where(.token("code", system: "http://loinc.org", code: "8480-6"))
            .where(.reference("subject", "Patient/123"))
            .where(.date("date", .ge, "2026-01-01"))
            .where(.quantity("value-quantity", .lt, "120", system: "http://unitsofmeasure.org", code: "mm[Hg]"))
            .where(.string("_id", "a,b|c$d\\e"))
            .where(.string("code", "x", modifier: .missing))
            .where(.chained("subject", targetType: "Patient", "name", "Chalmers"))
            .where(.has("Observation", "patient", "code", "1234-5"))
            .include("Observation", "subject", target: "Patient")
            .revInclude("Provenance", "target")
            .sorted(by: "-date", "code")
            .count(50).summary("true").elements(["code", "subject"]).total("accurate")
        let items = query.queryItems
        XCTAssertEqual(items.first?.name, "code")
        XCTAssertEqual(items.first?.value, "http://loinc.org|8480-6")
        XCTAssertEqual(items[2].value, "ge2026-01-01")
        XCTAssertEqual(items[3].value, "lt120|http://unitsofmeasure.org|mm[Hg]")
        XCTAssertEqual(items[4].value, "a\\,b\\|c\\$d\\\\e")
        XCTAssertEqual(items[5].name, "code:missing")
        XCTAssertEqual(items[6].name, "subject:Patient.name")
        XCTAssertEqual(items[7].name, "_has:Observation:patient:code")
        XCTAssertEqual(items[8], URLQueryItem(name: "_include", value: "Observation:subject:Patient"))
        XCTAssertEqual(items[9], URLQueryItem(name: "_revinclude", value: "Provenance:target"))
        XCTAssertEqual(items[10], URLQueryItem(name: "_sort", value: "-date,code"))
        XCTAssertEqual(items[11], URLQueryItem(name: "_count", value: "50"))
        XCTAssertEqual(items[14], URLQueryItem(name: "_total", value: "accurate"))
        let url = query.url(baseURL: URL(string: "https://fhir.example.test/base")!)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://fhir.example.test/base/Observation?code=http%3A%2F%2Floinc.org%7C8480-6&subject=Patient%2F123&date=ge2026-01-01"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("_id=a%5C%2Cb%5C%7Cc%5C%24d%5C%5Ce"))
        XCTAssertEqual(String(decoding: query.formBody, as: UTF8.self), query.queryString)
        XCTAssertEqual(FHIRSearchQuery(resourceType: "Patient").url(baseURL: URL(string: "https://x.test/r4")!).absoluteString, "https://x.test/r4/Patient")
        XCTAssertEqual(FHIRSearchQuery(resourceType: "Patient").where(.string("name", "a b")).url(baseURL: URL(string: "https://x.test/r4")!).absoluteString, "https://x.test/r4/Patient?name=a%20b")
    }

    func test_searchPage_splitsMatchesIncludesAndOutcomes() throws {
        let bundle = try XCTUnwrap(FHIRFixtures.resource("bundle-example").as(FHIRBundle.self))
        let page = FHIRSearchPage(bundle: bundle, url: URL(string: "https://example.com/base/MedicationRequest")!)
        XCTAssertEqual(page.matches.map(\.resourceType), ["MedicationRequest"])
        XCTAssertEqual(page.included.map(\.resourceType), ["Medication"])
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.nextURL?.host, "example.com")
        XCTAssertTrue(page.outcomes.isEmpty)
        let configuration = FHIRClientConfiguration(baseURL: URL(string: "https://example.com/base")!, allowedOrigins: ["https://other.test:8443"])
        XCTAssertTrue(configuration.isAllowedOrigin(page.nextURL!))
        XCTAssertTrue(configuration.isAllowedOrigin(URL(string: "https://other.test:8443/fhir/Patient")!))
        XCTAssertFalse(configuration.isAllowedOrigin(URL(string: "https://other.test/fhir/Patient")!))
        XCTAssertFalse(configuration.isAllowedOrigin(URL(string: "http://example.com/base/Patient")!))
    }

    func test_responseMetadata_extractsVersionsFromETagAndLocation() {
        XCTAssertEqual(FHIRResponseMetadata(status: 201, headers: ["ETag": "W/\"3\""]).versionId, "3")
        XCTAssertEqual(FHIRResponseMetadata(status: 201, headers: ["etag": "\"7\""]).versionId, "7")
        XCTAssertEqual(FHIRResponseMetadata(status: 201, headers: ["Location": "https://x/Patient/1/_history/9"]).versionId, "9")
        XCTAssertNil(FHIRResponseMetadata(status: 200, headers: [:]).versionId)
        XCTAssertTrue(FHIRFailure(reason: .status, status: 412, message: "").isVersionConflict)
        XCTAssertTrue(FHIRFailure(reason: .status, status: 410, message: "").isNotFound)
    }

    func test_searchPage_resolvesRelativeLinksAgainstItsURLAndRetainsOriginChecks() throws {
        let base = URL(string: "https://example.com/r4/Patient?_count=2")!
        let configuration = FHIRClientConfiguration(baseURL: URL(string: "https://example.com/r4")!)
        for (link, expected, allowed) in [
            ("?_page=2", "https://example.com/r4/Patient?_page=2", true),
            ("Patient?_page=2", "https://example.com/r4/Patient?_page=2", true),
            ("/r4/Patient?_page=2", "https://example.com/r4/Patient?_page=2", true),
            ("//other.test/r4/Patient", "https://other.test/r4/Patient", false)
        ] {
            let resource = try FHIRResource(jsonData: Data("{\"resourceType\":\"Bundle\",\"type\":\"searchset\",\"link\":[{\"relation\":\"next\",\"url\":\"\(link)\"}]}".utf8))
            let page = FHIRSearchPage(bundle: try XCTUnwrap(resource.as(FHIRBundle.self)), url: base)
            let next = try XCTUnwrap(page.nextURL)
            XCTAssertEqual(next.absoluteString, expected)
            XCTAssertEqual(configuration.isAllowedOrigin(next), allowed)
        }
    }
}
