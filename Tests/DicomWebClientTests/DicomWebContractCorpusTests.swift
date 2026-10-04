import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

final class DicomWebContractCorpusTests: XCTestCase {
    func test_wireSearchPreservesJSONMembersThatDatasetNormalizationChanges() async throws {
        let wire = Data(#"[{"00100010":{"vr":"PN","Value":[null]},"00091001":{"vr":"ZZ","InlineBinary":"AQI=","vendorField":"preserve"}}]"#.utf8)
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!),
            transport: DicomWebContractTransport(response: .init(statusCode: 200,
                headers: ["Content-Type": "application/dicom+json", "Warning": "299 synthetic"], body: wire)))
        let parameters = DicomWebSearchParameters(level: .study)
        let response = try await client.searchResponse(parameters: parameters)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Warning"], "299 synthetic")
        XCTAssertEqual(response.body, wire)
        let page = try await client.search(parameters: parameters)
        let normalized = try DicomJSONCodec.object(from: XCTUnwrap(page.dataSets.first))
        let original = try XCTUnwrap((try JSONSerialization.jsonObject(with: wire) as? [[String: Any]])?.first)
        XCTAssertFalse(NSDictionary(dictionary: normalized).isEqual(to: original))
        XCTAssertEqual((original["00091001"] as? [String: Any])?["vr"] as? String, "ZZ")
        XCTAssertEqual((normalized["00091001"] as? [String: Any])?["vr"] as? String, "UN")
    }

    func test_wireSearchUsesTheExistingResponseBudget() async throws {
        var configuration = DicomWebClientConfiguration(baseURL: URL(string: "https://archive.example")!)
        configuration.maximumMetadataBytes = 2
        let client = DicomWebClient(configuration: configuration,
            transport: DicomWebContractTransport(response: .init(statusCode: 200, body: Data("[{}]".utf8))))
        do {
            _ = try await client.searchResponse(parameters: .init(level: .study))
            XCTFail("wire bytes exceeded the configured metadata budget")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.kind, .tooLarge)
        }
    }

    func testRequestCorpusMatchesToolkitWireContracts() async throws {
        let corpus = try DicomWebContractCorpus.load()
        XCTAssertEqual(corpus.schemaVersion, 1)

        for fixture in corpus.requestCases {
            let transport = DicomWebContractTransport(response: response(for: fixture.operation))
            let client = DicomWebClient(
                configuration: DicomWebClientConfiguration(baseURL: try XCTUnwrap(URL(string: fixture.baseURL))),
                transport: transport
            )

            switch fixture.operation {
            case "qidoStudies":
                _ = try await client.searchStudies(DicomWebQuery(
                    patientName: fixture.input.patientName,
                    limit: fixture.input.limit,
                    offset: fixture.input.offset
                ))
            case "wadoInstance":
                _ = try await client.retrieveInstance(
                    studyInstanceUID: try XCTUnwrap(fixture.input.studyUID),
                    seriesInstanceUID: try XCTUnwrap(fixture.input.seriesUID),
                    sopInstanceUID: try XCTUnwrap(fixture.input.instanceUID)
                )
            case "stowStudy":
                _ = try await client.storeInstances(
                    [DicomWebStoreInstance(data: try fixture.input.payload(), transferSyntax: nil)],
                    studyInstanceUID: try XCTUnwrap(fixture.input.studyUID)
                )
            default:
                XCTFail("Unknown request operation \(fixture.operation)")
                continue
            }

            let capturedRequest = await transport.firstRequest()
            let request = try XCTUnwrap(capturedRequest, fixture.id)
            let actual = try normalizedWireRequest(request, fixture: fixture)
            let expected = fixture.sharedExpectation.merging(fixture.dicomSwiftExpectation)
            assert(actual, matches: expected, fixtureID: fixture.id)
            assertDifferencesAreDeclared(fixture)
        }
    }

    func testHTTPStatusCorpusMatchesToolkitSuccessRange() async throws {
        let corpus = try DicomWebContractCorpus.load()

        for fixture in corpus.statusCases {
            let response = DicomWebHTTPResponse(
                statusCode: fixture.statusCode,
                headers: ["Content-Type": "application/dicom+json"],
                body: try fixture.body()
            )
            let transport = DicomWebContractTransport(response: response)
            let client = DicomWebClient(
                configuration: DicomWebClientConfiguration(
                    baseURL: try XCTUnwrap(URL(string: "https://archive.example/dicom-web"))
                ),
                transport: transport
            )

            do {
                _ = try await client.retrieveStudyMetadata(studyInstanceUID: fixture.id)
                XCTAssertTrue(fixture.accepted, "\(fixture.id) unexpectedly succeeded")
            } catch let error as DicomWebError {
                XCTAssertFalse(fixture.accepted, "\(fixture.id) unexpectedly failed")
                XCTAssertEqual(error.statusCode, fixture.statusCode)
            } catch {
                XCTFail("\(fixture.id) returned an unexpected error: \(error)")
            }
        }
    }

    func testDICOMJSONCorpusAcceptsOnlyDeclaredToolkitShapes() async throws {
        let corpus = try DicomWebContractCorpus.load()

        for fixture in corpus.dicomJSONCases {
            let transport = DicomWebContractTransport(response: DicomWebHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/dicom+json"],
                body: try fixture.body()
            ))
            let client = DicomWebClient(
                configuration: DicomWebClientConfiguration(
                    baseURL: try XCTUnwrap(URL(string: "https://archive.example/dicom-web"))
                ),
                transport: transport
            )

            do {
                let studies = try await client.searchStudies()
                XCTAssertTrue(
                    fixture.dicomSwiftExpectation.accepted,
                    "\(fixture.id) was accepted without being declared"
                )
                XCTAssertEqual(studies.first?.studyInstanceUID, fixture.dicomSwiftExpectation.studyUID)
                XCTAssertEqual(studies.first?.patientName, fixture.dicomSwiftExpectation.patientName)
            } catch {
                XCTAssertFalse(
                    fixture.dicomSwiftExpectation.accepted,
                    "\(fixture.id) was rejected unexpectedly: \(error)"
                )
            }

            assertDifferencesAreDeclared(fixture)
        }
    }

    private func response(for operation: String) -> DicomWebHTTPResponse {
        if operation == "wadoInstance" {
            return DicomWebHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/dicom"],
                body: Data("DICM".utf8)
            )
        }
        return DicomWebHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/dicom+json"],
            body: Data("[]".utf8)
        )
    }

    private func normalizedWireRequest(
        _ request: DicomWebHTTPRequest,
        fixture: DicomWebContractCorpus.RequestCase
    ) throws -> DicomWebContractCorpus.WireExpectation {
        var headers = request.headers
        var body = request.body
        if fixture.operation == "stowStudy" {
            let boundary = try XCTUnwrap(headers.dicomWebContractHeader("Content-Type"))
                .components(separatedBy: "boundary=")
                .last?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let actualBoundary = try XCTUnwrap(boundary)
            let expectedBoundary = try XCTUnwrap(fixture.input.boundary)
            headers = headers.mapValues {
                $0.replacingOccurrences(of: actualBoundary, with: expectedBoundary)
            }
            if let bodyText = body.flatMap({ String(data: $0, encoding: .utf8) }) {
                body = Data(bodyText.replacingOccurrences(of: actualBoundary, with: expectedBoundary).utf8)
                headers["Content-Length"] = body.map { String($0.count) }
            }
        }

        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        return DicomWebContractCorpus.WireExpectation(
            method: request.method.rawValue,
            scheme: components.scheme,
            host: components.host,
            port: components.port,
            path: components.path,
            query: Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }),
            headers: headers,
            multipartBodyBase64: body?.base64EncodedString()
        )
    }

    private func assert(
        _ actual: DicomWebContractCorpus.WireExpectation,
        matches expected: DicomWebContractCorpus.WireExpectation,
        fixtureID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.method, expected.method, fixtureID, file: file, line: line)
        XCTAssertEqual(actual.scheme, expected.scheme, fixtureID, file: file, line: line)
        XCTAssertEqual(actual.host, expected.host, fixtureID, file: file, line: line)
        XCTAssertEqual(actual.port, expected.port, fixtureID, file: file, line: line)
        XCTAssertEqual(actual.path, expected.path, fixtureID, file: file, line: line)
        XCTAssertEqual(actual.query, expected.query, fixtureID, file: file, line: line)
        XCTAssertEqual(
            actual.headers.dicomWebContractLowercasedKeys(),
            expected.headers.dicomWebContractLowercasedKeys(),
            fixtureID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual.multipartBodyBase64,
            expected.multipartBodyBase64,
            fixtureID,
            file: file,
            line: line
        )
    }

    private func assertDifferencesAreDeclared(
        _ fixture: DicomWebContractCorpus.RequestCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertDeclaredDifferences(
            fixture.dicomSwiftExpectation.differingFields(from: fixture.isisExpectation),
            declarations: fixture.intentionalDifferences,
            fixtureID: fixture.id,
            file: file,
            line: line
        )
    }

    private func assertDifferencesAreDeclared(
        _ fixture: DicomWebContractCorpus.DICOMJSONCase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertDeclaredDifferences(
            fixture.dicomSwiftExpectation.differingFields(from: fixture.isisExpectation),
            declarations: fixture.intentionalDifferences,
            fixtureID: fixture.id,
            file: file,
            line: line
        )
    }

    private func assertDeclaredDifferences(
        _ fields: Set<String>,
        declarations: [DicomWebContractCorpus.IntentionalDifference],
        fixtureID: String,
        file: StaticString,
        line: UInt
    ) {
        let declaredFields = Set(declarations.map(\.field))
        XCTAssertEqual(
            fields,
            declaredFields,
            "\(fixtureID) must declare every implementation difference",
            file: file,
            line: line
        )
        XCTAssertEqual(declaredFields.count, declarations.count, "\(fixtureID) has duplicate declarations")
        for declaration in declarations {
            XCTAssertFalse(declaration.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private actor DicomWebContractTransport: DicomWebHTTPTransport {
    private let response: DicomWebHTTPResponse
    private var requests: [DicomWebHTTPRequest] = []

    init(response: DicomWebHTTPResponse) {
        self.response = response
    }

    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        requests.append(request)
        return response
    }

    func firstRequest() -> DicomWebHTTPRequest? {
        requests.first
    }
}

private struct DicomWebContractCorpus: Decodable {
    struct RequestCase: Decodable {
        let id: String
        let operation: String
        let baseURL: String
        let input: RequestInput
        let sharedExpectation: WireExpectation
        let dicomSwiftExpectation: WireExpectation
        let isisExpectation: WireExpectation
        let intentionalDifferences: [IntentionalDifference]
    }

    struct RequestInput: Decodable {
        let patientName: String?
        let limit: Int?
        let offset: Int?
        let studyUID: String?
        let seriesUID: String?
        let instanceUID: String?
        let isisAcceptHeader: String?
        let boundary: String?
        let payloadBase64: String?

        func payload() throws -> Data {
            guard let payloadBase64, let data = Data(base64Encoded: payloadBase64) else {
                throw CorpusError.invalidBase64("request payload")
            }
            return data
        }
    }

    struct WireExpectation: Decodable, Equatable {
        var method: String?
        var scheme: String?
        var host: String?
        var port: Int?
        var path: String?
        var query: [String: String]
        var headers: [String: String]
        var multipartBodyBase64: String?

        func merging(_ other: Self) -> Self {
            var result = self
            result.method = other.method ?? method
            result.scheme = other.scheme ?? scheme
            result.host = other.host ?? host
            result.port = other.port ?? port
            result.path = other.path ?? path
            result.query.merge(other.query) { _, new in new }
            result.headers.merge(other.headers) { _, new in new }
            result.multipartBodyBase64 = other.multipartBodyBase64 ?? multipartBodyBase64
            return result
        }

        func differingFields(from other: Self) -> Set<String> {
            var fields: Set<String> = []
            if method != other.method { fields.insert("method") }
            if scheme != other.scheme { fields.insert("scheme") }
            if host != other.host { fields.insert("host") }
            if port != other.port { fields.insert("port") }
            if path != other.path { fields.insert("path") }
            for key in Set(query.keys).union(other.query.keys) where query[key] != other.query[key] {
                fields.insert("query.\(key)")
            }
            for key in Set(headers.keys).union(other.headers.keys) where headers[key] != other.headers[key] {
                fields.insert("headers.\(key)")
            }
            if multipartBodyBase64 != other.multipartBodyBase64 {
                fields.insert("multipartBodyBase64")
            }
            return fields
        }
    }

    struct StatusCase: Decodable {
        let id: String
        let statusCode: Int
        let accepted: Bool
        let bodyBase64: String

        func body() throws -> Data {
            guard let data = Data(base64Encoded: bodyBase64) else {
                throw CorpusError.invalidBase64(id)
            }
            return data
        }
    }

    struct DICOMJSONCase: Decodable {
        let id: String
        let bodyBase64: String
        let dicomSwiftExpectation: JSONExpectation
        let isisExpectation: JSONExpectation
        let intentionalDifferences: [IntentionalDifference]

        func body() throws -> Data {
            guard let data = Data(base64Encoded: bodyBase64) else {
                throw CorpusError.invalidBase64(id)
            }
            return data
        }
    }

    struct JSONExpectation: Decodable, Equatable {
        let accepted: Bool
        let studyUID: String?
        let patientName: String?

        func differingFields(from other: Self) -> Set<String> {
            var fields: Set<String> = []
            if accepted != other.accepted { fields.insert("accepted") }
            if studyUID != other.studyUID { fields.insert("studyUID") }
            if patientName != other.patientName { fields.insert("patientName") }
            return fields
        }
    }

    struct IntentionalDifference: Decodable {
        let field: String
        let reason: String
    }

    enum CorpusError: Error {
        case missingResource
        case invalidBase64(String)
    }

    let schemaVersion: Int
    let requestCases: [RequestCase]
    let statusCases: [StatusCase]
    let dicomJSONCases: [DICOMJSONCase]

    static func load() throws -> Self {
        guard let url = Bundle.module.url(forResource: "DICOMwebWireContracts", withExtension: "json") else {
            throw CorpusError.missingResource
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

private extension Dictionary where Key == String, Value == String {
    func dicomWebContractHeader(_ name: String) -> String? {
        first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func dicomWebContractLowercasedKeys() -> [String: String] {
        Dictionary(uniqueKeysWithValues: map { ($0.key.lowercased(), $0.value) })
    }
}

extension DicomWebContractCorpusTests {
    func test_A1OperationCorpus_buildsEveryNewResourceRequest() async throws {
        let corpus = try a1Corpus()
        let cases = try XCTUnwrap(corpus["clientOperationCases"] as? [[String: String]])
        for fixture in cases {
            let transport = DicomWebContractTransport(response: .init(statusCode: 200,
                headers: ["Content-Type": "application/dicom+json"], body: Data("[]".utf8)))
            let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
            let sink = DicomWebMemoryRetrieveSink()
            switch fixture["operation"] {
            case "searchSeriesGlobal": _ = try await client.searchSeries()
            case "searchSeriesScoped": _ = try await client.searchSeries(studyInstanceUID: "1")
            case "searchInstancesGlobal": _ = try await client.searchInstances()
            case "searchInstancesStudy": _ = try await client.searchInstances(studyInstanceUID: "1")
            case "searchInstancesSeries": _ = try await client.searchInstances(studyInstanceUID: "1", seriesInstanceUID: "2")
            case "retrieveStudy": try await client.retrieveStudy(studyInstanceUID: "1", sink: sink)
            case "retrieveSeries": try await client.retrieveSeries(studyInstanceUID: "1", seriesInstanceUID: "2", sink: sink)
            case "seriesMetadata": _ = try await client.retrieveSeriesMetadata(studyInstanceUID: "1", seriesInstanceUID: "2")
            case "instanceMetadata": _ = try await client.retrieveInstanceMetadata(studyInstanceUID: "1", seriesInstanceUID: "2", sopInstanceUID: "3")
            case "studyThumbnail": _ = try await client.retrieveThumbnail(studyInstanceUID: "1")
            case "seriesThumbnail": _ = try await client.retrieveThumbnail(studyInstanceUID: "1", seriesInstanceUID: "2")
            case "instanceThumbnail": _ = try await client.retrieveThumbnail(studyInstanceUID: "1", seriesInstanceUID: "2", sopInstanceUID: "3")
            case "renderedInstance": _ = try await client.retrieveRenderedInstance(studyInstanceUID: "1", seriesInstanceUID: "2", sopInstanceUID: "3")
            case "bulkdataStream": try await client.retrieveBulkData(uri: "/bulk/1", sink: sink)
            case "instanceStream": try await client.retrieveInstance(studyInstanceUID: "1", seriesInstanceUID: "2", sopInstanceUID: "3", sink: sink)
            case "framesStream": try await client.retrieveFrames(studyInstanceUID: "1", seriesInstanceUID: "2", sopInstanceUID: "3", frames: .init([1, 2]), sink: sink)
            default: XCTFail("Unknown A1 operation")
            }
            let captured = await transport.firstRequest()
            let request = try XCTUnwrap(captured)
            XCTAssertEqual(request.url.path, fixture["path"])
            XCTAssertEqual(request.method.rawValue, fixture["method"])
            XCTAssertEqual(request.headers["Accept"], fixture["accept"])
        }
    }

    func test_annexIResponseCorpus_decodesJSONXMLAndSTOWStatusOutcomes() async throws {
        let cases = try XCTUnwrap(try a1Corpus()["storeResponseCases"] as? [[String: Any]])
        for fixture in cases {
            let data = Data(try XCTUnwrap(fixture["body"] as? String).utf8)
            let type = try XCTUnwrap(fixture["contentType"] as? String)
            let status = try XCTUnwrap(fixture["statusCode"] as? Int)
            let transport = DicomWebContractTransport(response: .init(statusCode: status, headers: ["Content-Type": type], body: data))
            let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
            let result = try await client.storeInstances([.init(data: Data([1]), transferSyntax: nil)])
            XCTAssertEqual(result.statusCode, status)
            XCTAssertEqual(result.acceptedInstanceCount, fixture["acceptedInstanceCount"] as? Int)
            XCTAssertEqual(result.storeResponse?.instances.map { $0.outcome.rawValue }, fixture["outcomes"] as? [String])
        }
    }

    private func a1Corpus() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "DICOMwebWireContracts", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
