import DicomData
import Foundation
import XCTest
@testable import DicomWebClient
import DicomTestUtilities

final class DicomWebClientTests: XCTestCase {
    func test_streamingOverloads_preserveExplicitAcceptAndStatus() async throws {
        let transport = DicomWebScriptedTransport(responses: Array(repeating:
            .init(statusCode: 206, headers: ["Content-Type": "application/octet-stream"], body: Data([1, 2])), count: 5))
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example/dicom-web")!),
                                    transport: transport)
        let media = try DicomWebMediaType("multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.4.90")
        let sink = DicomWebMemoryRetrieveSink()
        var statuses: [Int] = []
        statuses.append(try await client.retrieveStudy(studyInstanceUID: "1", accept: media, sink: sink))
        statuses.append(try await client.retrieveSeries(studyInstanceUID: "1", seriesInstanceUID: "2", accept: media, sink: sink))
        statuses.append(try await client.retrieveInstance(studyInstanceUID: "1", seriesInstanceUID: "2", sopInstanceUID: "3", accept: media, sink: sink))
        statuses.append(try await client.retrieveFrames(studyInstanceUID: "1", seriesInstanceUID: "2", sopInstanceUID: "3", frames: .init([1]), accept: media, sink: sink))
        statuses.append(try await client.retrieveBulkData(uri: "bulkdata/1", accept: media, sink: sink))
        XCTAssertEqual(statuses, Array(repeating: 206, count: 5))
        XCTAssertEqual(transport.requests.count, 5)
        for request in transport.requests { XCTAssertEqual(try DicomWebMediaType(XCTUnwrap(request.headers["Accept"])), media) }
        let parts = await sink.result()
        XCTAssertEqual(parts.count, 5)
    }

    func test_bulkDataForeignOrigin_isRejectedByDefaultBeforeTransport() async throws {
        for uri in ["https://other.invalid/bulk/1", "https://archive.example:8443/bulk/1", "//127.0.0.1/bulk/1"] {
            let transport = DicomWebScriptedTransport(responses: [.init(statusCode: 200)])
            let client = DicomWebClient(configuration: .init(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ), transport: transport)
            do {
                _ = try await client.retrieveBulkData(uri: uri)
                XCTFail("Foreign BulkDataURI was accepted without an allowlist")
            } catch let error as DicomWebClientError {
                guard case .invalidBulkDataURI = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func test_bulkDataOriginMutation_keepsConfiguredCredentialsOnOriginalOriginOnly() async throws {
        let origins = [URL(string: "https://archive.example.other.invalid")!,
                       URL(string: "https://archive.example:8443")!, URL(string: "https://other.invalid")!]
        for useBulkDataInitializer in [false, true] {
            for (uri, forwardsHeaders) in [
                ("https://archive.example:443/bulk/1", true),
                ("https://archive.example.other.invalid/bulk/1", false),
                ("https://archive.example:8443/bulk/1", false),
                ("//other.invalid/bulk/1", false)
            ] {
                let transport = DicomWebScriptedTransport(responses: [.init(statusCode: 200, body: Data([1, 2]))])
                var client = DicomWebClient(configuration: .init(
                    baseURL: URL(string: "https://archive.example/dicom-web")!,
                    headers: ["Authorization": "Bearer synthetic-test-value", "Cookie": "synthetic=value",
                              "X-Archive-Key": "synthetic-test-key"],
                    allowedBulkDataOrigins: useBulkDataInitializer ? origins : []
                ), transport: transport)
                if !useBulkDataInitializer { client.configuration.allowedOrigins = Set(origins) }
                _ = try await client.retrieveBulkData(uri: uri)
                let request = try XCTUnwrap(transport.requests.first)
                for name in ["Authorization", "Cookie", "X-Archive-Key"] {
                    XCTAssertEqual(request.headers[name] != nil, forwardsHeaders, "\(uri): \(name)")
                }
                XCTAssertNotNil(request.headers["Accept"])
            }
        }
    }

    func test_bulkDataUnsafeSchemeOrUserInfo_rejectsBeforeTransport() async throws {
        for uri in ["file:///tmp/synthetic.dcm", "data:application/octet-stream;base64,AA==",
                    "https://synthetic:synthetic@archive.example/bulk/1", "http://archive.example/bulk/1"] {
            let transport = DicomWebScriptedTransport(responses: [.init(statusCode: 200)])
            let client = DicomWebClient(configuration: .init(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ), transport: transport)
            do {
                _ = try await client.retrieveBulkData(uri: uri)
                XCTFail("Unsafe BulkDataURI was accepted")
            } catch let error as DicomWebClientError {
                guard case .invalidBulkDataURI = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func test_responseStatusAndJSONMutations_areRejectedInsteadOfBecomingSuccessfulSearches() async throws {
        for status in [401, 403, 404, 409, 500, 503] {
            let transport = DicomWebScriptedTransport(responses: [.init(statusCode: status, body: Data("[]".utf8))])
            let client = DicomWebClient(configuration: .init(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ), transport: transport)
            do {
                _ = try await client.searchStudies(.init())
                XCTFail("Mutated HTTP status was ignored")
            } catch let error as DicomWebError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertEqual(error.bodyPreview, "[]")
            }
        }
        for body in ["[", "{", "null", "[1]", "[{\"0020000D\":"] {
            let transport = DicomWebScriptedTransport(responses: [.init(statusCode: 200,
                headers: ["Content-Type": "application/dicom+json"], body: Data(body.utf8))])
            let client = DicomWebClient(configuration: .init(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ), transport: transport)
            do {
                _ = try await client.searchStudies(.init())
                XCTFail("Malformed JSON was accepted: \(body)")
            } catch let error as DicomWebClientError {
                XCTAssertEqual(error, .invalidJSONResponse)
            }
        }
    }

    func test_cancelledBulkDataRequest_doesNotInvokeInjectedTransport() async throws {
        let transport = DicomWebScriptedTransport(responses: [.init(statusCode: 200)])
        let client = DicomWebClient(configuration: .init(
            baseURL: URL(string: "https://archive.example/dicom-web")!
        ), transport: transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.retrieveBulkData(uri: "bulk/1")
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation was converted into successful transport")
        } catch is CancellationError {}
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testConfigurationDefaultsAndTracksSTOWRequestBudget() {
        let baseURL = URL(string: "https://archive.example/dicom-web")!
        let headerConfiguration = DicomWebClientConfiguration(baseURL: baseURL)
        let bearerConfiguration = DicomWebClientConfiguration(baseURL: baseURL, bearerToken: "token")
        let customBearerConfiguration = DicomWebClientConfiguration(
            baseURL: baseURL,
            bearerToken: "token",
            maximumSTOWRequestBodyBytes: 42
        )
        var customConfiguration = headerConfiguration
        customConfiguration.maximumSTOWRequestBodyBytes = 1

        XCTAssertEqual(
            headerConfiguration.maximumSTOWRequestBodyBytes,
            DicomWebClientConfiguration.defaultMaximumSTOWRequestBodyBytes
        )
        XCTAssertEqual(
            bearerConfiguration.maximumSTOWRequestBodyBytes,
            DicomWebClientConfiguration.defaultMaximumSTOWRequestBodyBytes
        )
        XCTAssertEqual(customBearerConfiguration.maximumSTOWRequestBodyBytes, 42)
        XCTAssertNotEqual(customConfiguration, headerConfiguration)
    }

    func test_storeInstancesWithEmptyInput_rejectsWithoutCallingTransport() async throws {
        let transport = DicomWebScriptedTransport(responses: [])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ),
            transport: transport
        )

        do {
            _ = try await client.storeInstances([])
            XCTFail("Expected an empty STOW request to fail.")
        } catch {
            XCTAssertEqual(error as? DicomWebClientError, .emptyStoreRequest)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testStoreInstancesRejectsBodyAboveBudgetWithoutCallingTransport() async throws {
        let transport = DicomWebScriptedTransport(responses: [])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(
                baseURL: URL(string: "https://archive.example/dicom-web")!,
                maximumSTOWRequestBodyBytes: 1
            ),
            transport: transport
        )

        do {
            _ = try await client.storeInstances([
                DicomWebStoreInstance(data: Data(), transferSyntax: nil)
            ])
            XCTFail("Expected the STOW request budget to reject the body.")
        } catch DicomWebClientError.storeRequestBodyTooLarge(let byteCount, let limit) {
            XCTAssertGreaterThan(byteCount, limit)
            XCTAssertEqual(limit, 1)
        } catch {
            XCTFail("Expected a typed STOW request budget error, got \(error)")
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testStoreInstancesRejectsUnsafeContentTypeWithoutCallingTransport() async throws {
        let transport = DicomWebScriptedTransport(responses: [])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ),
            transport: transport
        )
        let instance = DicomWebStoreInstance(
            data: Data([0x01]),
            contentType: "application/dicom\r\nX-Injected: true"
        )

        do {
            _ = try await client.storeInstances([instance])
            XCTFail("Expected an unsafe STOW Content-Type to fail.")
        } catch {
            XCTAssertEqual(error as? DicomWebClientError, .invalidStoreContentType(instanceIndex: 0))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testStoreInstancesRejectsUnsafeTransferSyntaxWithoutCallingTransport() async throws {
        let transport = DicomWebScriptedTransport(responses: [])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ),
            transport: transport
        )
        let instance = DicomWebStoreInstance(
            data: Data([0x01]),
            transferSyntax: "1.2.840.10008.1.2.1\nX-Injected: true"
        )

        do {
            _ = try await client.storeInstances([instance])
            XCTFail("Expected an unsafe STOW transfer syntax to fail.")
        } catch {
            XCTAssertEqual(error as? DicomWebClientError, .invalidStoreTransferSyntaxUID(instanceIndex: 0))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testStoreInstancesRejectsPart10TransferSyntaxMismatchWithoutCallingTransport() async throws {
        let transport = DicomWebScriptedTransport(responses: [])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ),
            transport: transport
        )
        let payload = try Data(contentsOf: DicomTestFixtures.directory.appendingPathComponent(
            "DecoderParity/jpeg_lossless_sv1_parity.dcm"
        ))

        do {
            _ = try await client.storeInstances([DicomWebStoreInstance(data: payload)])
            XCTFail("Expected a mismatched Part 10 STOW transfer syntax to fail.")
        } catch {
            XCTAssertEqual(error as? DicomWebClientError, .storeTransferSyntaxMismatch(instanceIndex: 0))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testSearchStudiesBuildsQIDORequestAndParsesDICOMJSON() async throws {
        let transport = DicomWebScriptedTransport(responses: [
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "application/dicom+json"],
                                 body: Data("""
                                 [{
                                   "00100010": { "vr": "PN", "Value": [{ "Alphabetic": "DOE^JANE" }] },
                                   "00100020": { "vr": "LO", "Value": ["P-1"] },
                                   "00080020": { "vr": "DA", "Value": ["20260529"] },
                                   "00081030": { "vr": "LO", "Value": ["CT CHEST"] },
                                   "0020000D": { "vr": "UI", "Value": ["2.25.study"] }
                                 }]
                                 """.utf8))
        ])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(
                baseURL: URL(string: "https://archive.example/dicom-web")!,
                headers: ["Authorization": "Bearer token"]
            ),
            transport: transport
        )

        let studies = try await client.searchStudies(
            DicomWebQuery(patientName: "DOE",
                          patientID: "P-1",
                          accessionNumber: "ACC-1",
                          studyDate: "20260529",
                          studyDescription: "CT CHEST",
                          referringPhysicianName: "SMITH",
                          institutionName: "Hospital",
                          studyInstanceUID: "2.25.study",
                          modality: "CT",
                          limit: 25,
                          offset: 50)
        )

        XCTAssertEqual(studies.count, 1)
        XCTAssertEqual(studies.first?.patientName, "DOE^JANE")
        XCTAssertEqual(studies.first?.studyInstanceUID, "2.25.study")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.path, "/dicom-web/studies")
        let queryItems = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(query["PatientName"], "DOE")
        XCTAssertEqual(query["PatientID"], "P-1")
        XCTAssertEqual(query["AccessionNumber"], "ACC-1")
        XCTAssertEqual(query["StudyDate"], "20260529")
        XCTAssertEqual(query["StudyDescription"], "CT CHEST")
        XCTAssertEqual(query["ReferringPhysicianName"], "SMITH")
        XCTAssertEqual(query["InstitutionName"], "Hospital")
        XCTAssertEqual(query["StudyInstanceUID"], "2.25.study")
        XCTAssertEqual(query["ModalitiesInStudy"], "CT")
        XCTAssertEqual(query["limit"], "25")
        XCTAssertEqual(query["offset"], "50")
        XCTAssertEqual(query["includefield"], "all")
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
        XCTAssertEqual(request.headers["Accept"], "application/dicom+json")
    }

    func testRetrieveMetadataAndMultipartInstance() async throws {
        let transport = DicomWebScriptedTransport(responses: [
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "application/dicom+json"],
                                 body: Data("""
                                 [{
                                   "0020000D": { "vr": "UI", "Value": ["2.25.study"] },
                                   "0020000E": { "vr": "UI", "Value": ["2.25.series"] },
                                   "00080018": { "vr": "UI", "Value": ["2.25.instance"] },
                                   "00280010": { "vr": "US", "Value": [2] }
                                 }]
                                 """.utf8)),
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "multipart/related; type=\"application/dicom\"; boundary=abc"],
                                 body: Self.multipartBody(boundary: "abc",
                                                          contentType: "application/dicom",
                                                          payload: Data([0x44, 0x49, 0x43, 0x4D])))
        ])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: URL(string: "https://archive.example/dicom-web")!),
            transport: transport
        )

        let metadata = try await client.retrieveStudyMetadata(studyInstanceUID: "2.25.study")
        let object = try await client.retrieveInstance(studyInstanceUID: "2.25.study",
                                                       seriesInstanceUID: "2.25.series",
                                                       sopInstanceUID: "2.25.instance")

        XCTAssertEqual(metadata.first?.dataSet.string(for: .sopInstanceUID), "2.25.instance")
        XCTAssertEqual(metadata.first?.dataSet.int(for: .rows), 2)
        XCTAssertEqual(object.parts.count, 1)
        XCTAssertEqual(object.parts.first?.contentType, "application/dicom")
        XCTAssertEqual(object.firstPayload, Data([0x44, 0x49, 0x43, 0x4D]))
        XCTAssertEqual(transport.requests.map(\.url.path), [
            "/dicom-web/studies/2.25.study/metadata",
            "/dicom-web/studies/2.25.study/series/2.25.series/instances/2.25.instance"
        ])
    }

    func testRetrieveRenderedFrameAndWADOURI() async throws {
        let transport = DicomWebScriptedTransport(responses: [
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "image/png"],
                                 body: Data([0x89, 0x50, 0x4E, 0x47])),
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "application/dicom"],
                                 body: Data([0x44, 0x49, 0x43, 0x4D]))
        ])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: URL(string: "https://archive.example/dicom-web")!),
            transport: transport
        )

        let frame = try await client.retrieveRenderedFrame(studyInstanceUID: "2.25.study",
                                                           seriesInstanceUID: "2.25.series",
                                                           sopInstanceUID: "2.25.instance",
                                                           frameNumber: 1)
        let object = try await client.retrieveWADOURIObject(studyInstanceUID: "2.25.study",
                                                            seriesInstanceUID: "2.25.series",
                                                            sopInstanceUID: "2.25.instance")

        XCTAssertEqual(frame.firstPayload, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(object.firstPayload, Data([0x44, 0x49, 0x43, 0x4D]))
        XCTAssertEqual(transport.requests[0].url.path, "/dicom-web/studies/2.25.study/series/2.25.series/instances/2.25.instance/frames/1/rendered")
        XCTAssertEqual(transport.requests[1].url.path, "/dicom-web/wado")
        XCTAssertTrue(try XCTUnwrap(transport.requests[1].url.query).contains("requestType=WADO"))
    }

    func test_retrieveRenderedFrames_pluralDefault_requestsMultipartPNG() async throws {
        let transport = DicomWebScriptedTransport(responses: [
            DicomWebHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "multipart/related; type=\"image/png\"; boundary=frames"],
                body: Self.multipartBody(
                    boundary: "frames",
                    contentType: "image/png",
                    payload: Data([0x89, 0x50, 0x4E, 0x47])
                )
            )
        ])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ),
            transport: transport
        )

        _ = try await client.retrieveRenderedFrames(
            studyInstanceUID: "2.25.study",
            seriesInstanceUID: "2.25.series",
            sopInstanceUID: "2.25.instance",
            frames: DicomWebFrameList([1, 2])
        )

        XCTAssertEqual(transport.requests.first?.headers["Accept"], "multipart/related; type=\"image/png\"")
    }

    func testRetrieveFrameBulkDataURIAndLargeSTOWSerialization() async throws {
        let largePayload = Data(repeating: 0xA5, count: 1024 * 1024)
        let transport = DicomWebScriptedTransport(responses: [
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "multipart/related; type=\"application/octet-stream\"; boundary=frame"],
                                 body: Self.multipartBody(boundary: "frame",
                                                          contentType: "application/octet-stream",
                                                          payload: Data([0x01, 0x02, 0x03]))),
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "application/octet-stream"],
                                 body: Data([0x10, 0x11])),
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "application/json"],
                                 body: Data("[]".utf8))
        ])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: URL(string: "https://archive.example/dicom-web")!),
            transport: transport
        )

        let frame = try await client.retrieveFrame(studyInstanceUID: "2.25.study",
                                                   seriesInstanceUID: "2.25.series",
                                                   sopInstanceUID: "2.25.instance",
                                                   frameNumber: 2)
        let bulk = try await client.retrieveBulkData(uri: "studies/2.25.study/bulk/7FE00010")
        let store = try await client.storeInstances([DicomWebStoreInstance(data: largePayload)])

        XCTAssertEqual(frame.firstPayload, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(bulk.firstPayload, Data([0x10, 0x11]))
        XCTAssertEqual(store.acceptedInstanceCount, 0)
        XCTAssertEqual(transport.requests[0].url.path, "/dicom-web/studies/2.25.study/series/2.25.series/instances/2.25.instance/frames/2")
        XCTAssertEqual(transport.requests[0].headers["Accept"], "multipart/related; type=\"application/octet-stream\"; transfer-syntax=*")
        XCTAssertEqual(transport.requests[1].url.path, "/dicom-web/studies/2.25.study/bulk/7FE00010")
        XCTAssertEqual(transport.requests[1].headers["Accept"], "application/octet-stream, multipart/related; type=\"application/octet-stream\"")

        let storeRequest = try XCTUnwrap(transport.requests.last)
        let contentType = try XCTUnwrap(storeRequest.headers["Content-Type"])
        let boundary = try XCTUnwrap(DicomWebMultipartParser.boundary(from: contentType))
        let parts = try DicomWebMultipartParser.parts(from: try XCTUnwrap(storeRequest.body), boundary: boundary)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts.first?.body, largePayload)
    }

    func testRetrieveFrameListsSerializeExactlyAndRejectInvalidNumbers() async throws {
        let transport = DicomWebScriptedTransport(responses: [
            DicomWebHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "multipart/related; type=\"application/octet-stream\"; boundary=frames"],
                body: Self.multipartBody(
                    boundary: "frames",
                    contentType: "application/octet-stream",
                    payload: Data([0x01, 0x02])
                )
            )
        ])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(
                baseURL: URL(string: "https://archive.example/dicom-web")!
            ),
            transport: transport
        )

        _ = try await client.retrieveFrames(
            studyInstanceUID: "2.25.study",
            seriesInstanceUID: "2.25.series",
            sopInstanceUID: "2.25.instance",
            frames: DicomWebFrameList([1, 3])
        )

        XCTAssertEqual(
            transport.requests.first?.url.path,
            "/dicom-web/studies/2.25.study/series/2.25.series/instances/2.25.instance/frames/1,3"
        )
        do {
            _ = try await client.retrieveFrame(
                studyInstanceUID: "2.25.study",
                seriesInstanceUID: "2.25.series",
                sopInstanceUID: "2.25.instance",
                frameNumber: 0
            )
            XCTFail("Expected zero-based frame number validation to fail.")
        } catch {
            XCTAssertEqual(error as? DicomWebFrameList.ValidationError, .invalidNumber)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testMultipartBodyIgnoresBoundaryPrefixInsidePartPayload() throws {
        let boundary = "frames"
        let payload = Data("prefix\r\n--frames-not-a-delimiter\r\nsuffix".utf8)
        let body = Self.multipartBody(
            boundary: boundary,
            contentType: "application/octet-stream",
            payload: payload
        )

        let parts = try DicomWebMultipartParser.parts(from: body, boundary: boundary)

        XCTAssertEqual(parts.map(\.body), [payload])
    }

    func testBulkDataURIValuesArePreservedInDICOMJSON() async throws {
        let transport = DicomWebScriptedTransport(responses: [
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "application/dicom+json"],
                                 body: Data("""
                                 [{
                                   "0020000D": { "vr": "UI", "Value": ["2.25.study"] },
                                   "7FE00010": { "vr": "OB", "BulkDataURI": "/dicom-web/studies/2.25.study/bulk/7FE00010" }
                                 }]
                                 """.utf8))
        ])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: URL(string: "https://archive.example/dicom-web")!),
            transport: transport
        )

        let metadata = try await client.retrieveStudyMetadata(studyInstanceUID: "2.25.study")

        // The reference is explicit; the element stays empty until resolved through the client's origin policy.
        XCTAssertEqual(metadata.first?.dataSet.element(for: .pixelData)?.value, .empty)
        XCTAssertEqual(metadata.first?.bulkData, [.init(path: [.tag(0x7FE00010)], tag: 0x7FE00010, vr: .OB,
                                                        uri: "/dicom-web/studies/2.25.study/bulk/7FE00010")])
    }

    func testSTOWMultipartAndHTTPDiagnostics() async throws {
        let transport = DicomWebScriptedTransport(responses: [
            DicomWebHTTPResponse(statusCode: 200,
                                 headers: ["Content-Type": "application/dicom+json"],
                                 body: Data("[]".utf8)),
            DicomWebHTTPResponse(statusCode: 404,
                                 headers: ["Content-Type": "text/plain"],
                                 body: Data("missing study".utf8))
        ])
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: URL(string: "https://archive.example/dicom-web")!),
            transport: transport
        )

        let result = try await client.storeInstances([
            DicomWebStoreInstance(data: Data("DICM".utf8))
        ], studyInstanceUID: "2.25.study")

        XCTAssertEqual(result.acceptedInstanceCount, 0)
        let storeRequest = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(storeRequest.method, .post)
        XCTAssertEqual(storeRequest.url.path, "/dicom-web/studies/2.25.study")
        XCTAssertTrue(try XCTUnwrap(storeRequest.headers["Content-Type"]).contains("multipart/related"))
        let storeBody = try XCTUnwrap(storeRequest.body)
        XCTAssertEqual(storeRequest.headers["Content-Length"], String(storeBody.count))
        XCTAssertNil(storeRequest.headers["Transfer-Encoding"])
        let storeBodyText = try XCTUnwrap(String(data: storeBody, encoding: .utf8))
        XCTAssertTrue(storeBodyText.contains("Content-Type: application/dicom"))
        XCTAssertTrue(storeBodyText.contains("Content-Length: 4\r\n"))

        do {
            _ = try await client.retrieveStudyMetadata(studyInstanceUID: "2.25.missing")
            XCTFail("Expected HTTP diagnostic error.")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertEqual(error.bodyPreview, "missing study")
            XCTAssertFalse(try XCTUnwrap(error.errorDescription).contains("missing study"), "the description stays fixed")
            XCTAssertTrue(try XCTUnwrap(error.errorDescription).contains("HTTP 404"))
        }
    }

    func testURLSessionTransportSerializesHTTPRequests() async throws {
        let capture = DicomWebURLProtocolCapture()
        DicomWebCapturingURLProtocol.capture.replace(with: capture)
        defer { DicomWebCapturingURLProtocol.capture.replace(with: nil) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DicomWebCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = URLSessionDicomWebHTTPTransport(session: session)

        let response = try await transport.send(DicomWebHTTPRequest(
            method: .post,
            url: URL(string: "https://archive.example/dicom-web/studies")!,
            headers: ["Accept": "application/dicom+json", "Authorization": "Bearer token"],
            body: Data("payload".utf8),
            timeout: 5
        ))

        let request = try XCTUnwrap(capture.request)
        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(response.headers["X-Test"], "captured")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/dicom-web/studies")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/dicom+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Length") == "7" ||
                request.value(forHTTPHeaderField: "Transfer-Encoding") != nil
        )
        XCTAssertEqual(Self.bodyData(from: request), Data("payload".utf8))
    }

    func testURLSessionTransportCancellationStopsRequestAndIgnoresLateSuccess() async throws {
        let started = expectation(description: "URLProtocol started loading")
        let stopped = expectation(description: "URLProtocol stopped loading")
        let requestFinished = expectation(description: "transport request finished")
        let lateSuccessAttempted = expectation(description: "late URLProtocol success attempted")
        let controller = DicomWebStallingURLProtocolController(
            started: started,
            stopped: stopped,
            lateSuccessAttempted: lateSuccessAttempted
        )
        DicomWebStallingURLProtocol.controller.replace(with: controller)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DicomWebStallingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            DicomWebStallingURLProtocol.controller.replace(with: nil)
        }
        let transport = URLSessionDicomWebHTTPTransport(session: session)
        let outcome = DicomTestLockedValue<DicomWebTransportOutcome?>(nil)
        let requestTask = Task {
            do {
                _ = try await transport.send(DicomWebHTTPRequest(
                    method: .get,
                    url: URL(string: "https://archive.example/dicom-web/studies")!
                ))
                outcome.replace(with: .success)
            } catch {
                let nsError = error as NSError
                outcome.replace(with: .failure(domain: nsError.domain, code: nsError.code))
            }
            requestFinished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)

        requestTask.cancel()

        await fulfillment(of: [stopped], timeout: 2)
        controller.completeSuccessfullyAfterStop()
        await fulfillment(of: [lateSuccessAttempted, requestFinished], timeout: 2)
        XCTAssertEqual(
            outcome.value,
            .failure(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
    }

    private static func multipartBody(boundary: String, contentType: String, payload: Data) -> Data {
        var data = Data()
        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        data.append(payload)
        data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class DicomWebScriptedTransport: DicomWebHTTPTransport, @unchecked Sendable {
    private(set) var requests: [DicomWebHTTPRequest] = []
    private var responses: [DicomWebHTTPResponse]

    init(responses: [DicomWebHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return DicomWebHTTPResponse(statusCode: 500, body: Data("No scripted response".utf8))
        }
        return responses.removeFirst()
    }
}

/// A server that ignores `offset` and `limit`: every search gets the same full page.
private final class DicomWebFixedPageTransport: DicomWebHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let body: Data
    var requestCount: Int { lock.withLock { count } }

    init(body: Data) {
        self.body = body
    }

    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        lock.withLock { count += 1 }
        return DicomWebHTTPResponse(statusCode: 200, headers: ["Content-Type": "application/dicom+json"], body: body)
    }
}

private final class DicomWebURLProtocolCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock()
        let value = storedRequest
        lock.unlock()
        return value
    }

    func store(_ request: URLRequest) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }
}

private enum DicomWebTransportOutcome: Equatable, Sendable {
    case success
    case failure(domain: String, code: Int)
}

private final class DicomWebStallingURLProtocolController: @unchecked Sendable {
    private let started: XCTestExpectation
    private let stopped: XCTestExpectation
    private let lateSuccessAttempted: XCTestExpectation
    private let lock = NSLock()
    private var protocolInstance: DicomWebStallingURLProtocol?

    init(started: XCTestExpectation,
         stopped: XCTestExpectation,
         lateSuccessAttempted: XCTestExpectation) {
        self.started = started
        self.stopped = stopped
        self.lateSuccessAttempted = lateSuccessAttempted
    }

    func didStart(_ protocolInstance: DicomWebStallingURLProtocol) {
        lock.withLock {
            self.protocolInstance = protocolInstance
        }
        started.fulfill()
    }

    func didStop() {
        stopped.fulfill()
    }

    func completeSuccessfullyAfterStop() {
        defer { lateSuccessAttempted.fulfill() }
        guard let protocolInstance = lock.withLock({ self.protocolInstance }),
              let url = protocolInstance.request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/dicom+json"]
              ) else {
            return
        }
        protocolInstance.client?.urlProtocol(
            protocolInstance,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data("[]".utf8))
        protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }
}

private final class DicomWebStallingURLProtocol: URLProtocol {
    static let controller = DicomTestLockedValue<DicomWebStallingURLProtocolController?>(nil)

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.controller.value?.didStart(self)
    }

    override func stopLoading() {
        Self.controller.value?.didStop()
    }
}

private final class DicomWebCapturingURLProtocol: URLProtocol {
    static let capture = DicomTestLockedValue<DicomWebURLProtocolCapture?>(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capture.value?.store(request)
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: 202,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["X-Test": "captured"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("accepted".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension DicomWebClientTests {
    func test_streamingStudy_deliversFilesByContentLocationAndCancellationCleansPartialFile() async throws {
        let wire = Data(("--b\r\nContent-Type: application/dicom\r\nContent-Location: /instances/1\r\n\r\none\r\n" +
            "--b\r\nContent-Type: application/dicom\r\nContent-Location: /instances/2\r\n\r\ntwo\r\n--b--\r\n").utf8)
        let transport = A1StreamTransport(status: 206, headers: ["Content-Type": "multipart/related;boundary=b"],
                                          chunks: wire.map { Data([$0]) })
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = try DicomWebFileRetrieveSink(directory: directory)
        let status = try await client.retrieveStudy(studyInstanceUID: "1", sink: sink)
        XCTAssertEqual(status, 206)
        let files = await sink.result()
        XCTAssertEqual(files.map(\.contentLocation), ["/instances/1", "/instances/2"])
        XCTAssertEqual(try files.map { try Data(contentsOf: $0.url) }, [Data("one".utf8), Data("two".utf8)])
        let request = await transport.request()
        XCTAssertEqual(request?.url.path, "/studies/1")

        let cancelTransport = A1StreamTransport(status: 200, headers: ["Content-Type": "application/dicom"],
                                                chunks: [Data([1]), Data([2]), Data([3])], cancelAfter: 1)
        let cancelClient = DicomWebClient(configuration: client.configuration, transport: cancelTransport)
        let partialDirectory = directory.appendingPathComponent("cancelled")
        let partialSink = try DicomWebFileRetrieveSink(directory: partialDirectory)
        let task = Task {
            try await cancelClient.retrieveStudy(studyInstanceUID: "1", sink: partialSink)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: partialDirectory.path).isEmpty)
        let consumed = await cancelTransport.consumed()
        XCTAssertLessThan(consumed, 3)
    }

    func test_searchPager_honorsOffsetAndWarning299() async throws {
        let transport = DicomWebScriptedTransport(responses: [
            .init(statusCode: 200, headers: ["Content-Type": "application/dicom+json",
                "Warning": "299 archive: There are 1 additional results that can be requested"], body: Data("[{},{}]".utf8)),
            .init(statusCode: 200, headers: ["Content-Type": "application/dicom+json"], body: Data("[{}]".utf8))
        ])
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
        var pages: [DicomWebSearchPage] = []
        for try await page in client.searchPages(parameters: .init(level: .series, studyInstanceUID: "1", limit: 2, offset: 5)) {
            pages.append(page)
        }
        XCTAssertEqual(pages.map(\.offset), [5, 7])
        XCTAssertEqual(pages.map { $0.dataSets.count }, [2, 1])
        XCTAssertEqual(transport.requests.map(\.url.path), ["/studies/1/series", "/studies/1/series"])
        XCTAssertTrue(transport.requests[1].url.absoluteString.contains("offset=7"))
        XCTAssertFalse(DicomWebSearchPage(dataSets: [], statusCode: 200, contentType: "application/dicom+json",
            warning: "299 archive: fuzzymatching is not supported", offset: 0, limit: 2).hasMore)
    }

    func test_searchPager_serverIgnoringOffset_stopsAfterFirstRepeatedPage() async throws {
        let transport = DicomWebFixedPageTransport(body: Self.seriesPage(["1.1", "1.2"]))
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
        var pages: [DicomWebSearchPage] = []
        for try await page in client.searchPages(parameters: .init(level: .series, limit: 2), continuesOnFullPage: true) {
            pages.append(page)
        }
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(pages.map { $0.dataSets.count }, [2, 0])
        XCTAssertEqual(pages.map(\.stopReason), [nil, .repeatedPage])
    }

    func test_searchPager_resultRepeatedAcrossPages_isReturnedOnce() async throws {
        let transport = DicomWebScriptedTransport(responses: [
            .init(statusCode: 200, headers: ["Content-Type": "application/dicom+json"], body: Self.seriesPage(["1.1", "1.2"])),
            .init(statusCode: 200, headers: ["Content-Type": "application/dicom+json"], body: Self.seriesPage(["1.2", "1.3"])),
            .init(statusCode: 200, headers: ["Content-Type": "application/dicom+json"], body: Self.seriesPage(["1.4"]))
        ])
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
        var uids: [String] = []
        var reasons: [DicomWebSearchStopReason?] = []
        for try await page in client.searchPages(parameters: .init(level: .series, limit: 2), continuesOnFullPage: true) {
            uids += page.dataSets.compactMap { $0.string(for: .seriesInstanceUID) }
            reasons.append(page.stopReason)
        }
        XCTAssertEqual(uids, ["1.1", "1.2", "1.3", "1.4"])
        XCTAssertEqual(reasons, [nil, nil, nil])
        XCTAssertTrue(transport.requests[2].url.absoluteString.contains("offset=4"))
    }

    func test_searchPager_pageAndResultLimits_stopAndSaySo() async throws {
        let more = ["Content-Type": "application/dicom+json",
                    "Warning": "299 archive \"There are additional results that can be requested\""]
        func client(_ pages: [[String]]) -> (DicomWebClient, DicomWebScriptedTransport) {
            let transport = DicomWebScriptedTransport(responses: pages.map {
                .init(statusCode: 200, headers: more, body: Self.seriesPage($0))
            })
            return (DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport), transport)
        }
        let (pageClient, pageTransport) = client([["1"], ["2"], ["3"]])
        var counts: [Int] = []
        var reasons: [DicomWebSearchStopReason?] = []
        for try await page in pageClient.searchPages(parameters: .init(level: .series), limits: .init(maximumPages: 2)) {
            counts.append(page.dataSets.count)
            reasons.append(page.stopReason)
        }
        XCTAssertEqual(pageTransport.requests.count, 2)
        XCTAssertEqual(counts, [1, 1])
        XCTAssertEqual(reasons, [nil, .pageLimitReached])

        let (resultClient, resultTransport) = client([["1", "2"], ["3", "4"], ["5"]])
        counts = []
        reasons = []
        for try await page in resultClient.searchPages(parameters: .init(level: .series), limits: .init(maximumResults: 3)) {
            counts.append(page.dataSets.count)
            reasons.append(page.stopReason)
        }
        XCTAssertEqual(resultTransport.requests.count, 2)
        XCTAssertEqual(counts, [2, 1])
        XCTAssertEqual(reasons, [nil, .resultLimitReached])
    }

    func test_searchPage_warning299_isRecognizedByWarnCode() {
        func page(_ warning: String) -> DicomWebSearchPage {
            DicomWebSearchPage(dataSets: [], statusCode: 200, contentType: nil, warning: warning, offset: 0, limit: nil)
        }
        XCTAssertTrue(page("299 archive \"There are 3 additional results that can be requested\"").hasMore)
        XCTAssertTrue(page("199 archive \"x\", 299 archive \"The results were truncated\"").hasMore)
        XCTAssertFalse(page("199 archive \"There are additional results, 299 of them\"").hasMore)
        XCTAssertFalse(page("110 archive \"Response is stale; 299 additional results\"").hasMore)
        XCTAssertEqual(page("299 archive \"There are additional results\"").warning,
                       "299 archive \"There are additional results\"")
    }

    private static func seriesPage(_ uids: [String]) -> Data {
        let sets = uids.map { ["0020000E": ["vr": "UI", "Value": [$0]]] }
        return try! JSONSerialization.data(withJSONObject: sets)
    }

    func test_metadataWith1000BulkURIs_doesNotFetchReferences() async throws {
        let element: [String: Any] = ["7FE00010": ["vr": "OW", "BulkDataURI": "https://foreign.example/bulk"]]
        let wire = try JSONSerialization.data(withJSONObject: Array(repeating: element, count: 1000))
        let transport = DicomWebScriptedTransport(responses: [.init(statusCode: 200, body: wire)])
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
        let metadata = try await client.retrieveStudyMetadata(studyInstanceUID: "1")
        XCTAssertEqual(metadata.flatMap(\.bulkData).count, 1000)
        XCTAssertEqual(transport.requests.count, 1) // Only the explicit metadata transaction.
        XCTAssertEqual(try DicomJSONCodec.decode(wire).flatMap(\.bulkData).count, 1000)
        XCTAssertEqual(transport.requests.count, 1) // Pure decoding creates zero requests.
    }

    func test_streamedMetadata_enforcesBudgetBeforeWholeBodyArrives() async throws {
        let transport = A1StreamTransport(status: 200, headers: [:], chunks: [Data(repeating: 32, count: 8), Data(repeating: 32, count: 8), Data([1])])
        var configuration = DicomWebClientConfiguration(baseURL: URL(string: "https://archive.example")!)
        configuration.maximumMetadataBytes = 10
        let client = DicomWebClient(configuration: configuration, transport: transport)
        do { _ = try await client.search(parameters: .init()); XCTFail("Expected byte limit") }
        catch let error as DicomWebError { XCTAssertEqual(error.kind, .tooLarge) }
        let consumed = await transport.consumed()
        XCTAssertEqual(consumed, 2)
    }

    func test_searchStudies_localResponseLimitDoesNotBecomeHTTPStatus() async throws {
        let transport = A1StreamTransport(status: 200, headers: [:],
            chunks: [Data(repeating: 32, count: 8), Data(repeating: 32, count: 8), Data([1])])
        var configuration = DicomWebClientConfiguration(baseURL: URL(string: "https://archive.example")!)
        configuration.maximumMetadataBytes = 10
        let client = DicomWebClient(configuration: configuration, transport: transport)
        do {
            _ = try await client.searchStudies()
            XCTFail("Expected the local response limit")
        } catch {
            XCTAssertEqual((error as? DicomWebError)?.kind, .tooLarge)
        }
        let consumed = await transport.consumed()
        XCTAssertEqual(consumed, 2)
    }

    func test_stowOutcomes_preserve200202And409Responses() async throws {
        for status in [200, 202, 409] {
            let transport = DicomWebScriptedTransport(responses: [.init(statusCode: status,
                headers: ["Content-Type": "application/dicom+json"], body: DicomWebStoreResponseTests.json)])
            let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
            let result = try await client.storeInstances([.init(data: Data([1]), transferSyntax: nil)])
            XCTAssertEqual(result.statusCode, status)
            XCTAssertEqual(result.acceptedInstanceCount, 2)
            XCTAssertEqual(result.storeResponse?.instances.map(\.outcome), [.accepted, .warning, .failed])
        }
    }

    func test_fileStore_readErrorAndAggregateLimitRemoveStagedBody() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stow-input-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try DicomDataSetWriter.part10Data(from: .init(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.2910"]))
        ]))
        let file = directory.appendingPathComponent("original.dcm")
        try original.write(to: file)
        let transport = DicomWebScriptedTransport(responses: [])
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!,
            maximumSTOWRequestBodyBytes: original.count * 2), transport: transport)
        let stagedFiles = { () throws -> Set<String> in
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
                .filter { $0.hasPrefix("dicomweb-stow-") })
        }
        let before = try stagedFiles()
        do {
            _ = try await client.storeInstances(files: [file, directory.appendingPathComponent("missing.dcm")])
            XCTFail("Expected input read error")
        } catch { XCTAssertTrue(error is CocoaError) }
        XCTAssertEqual(try stagedFiles(), before)
        do {
            _ = try await client.storeInstances(files: [file, file])
            XCTFail("Expected aggregate multipart limit")
        } catch {
            XCTAssertEqual(error as? DicomWebMultipartStreamError,
                .limitExceeded("maximumTotalBytes", limit: original.count * 2))
        }
        XCTAssertEqual(try stagedFiles(), before)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func test_fileStore_transportCancellationRemovesStagedBody() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stow-input-\(UUID())")
        let original = try DicomDataSetWriter.part10Data(from: .init(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.2910"]))
        ]))
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = A1UploadTransport(cancels: true)
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
        do {
            _ = try await client.storeInstances(files: [file])
            XCTFail("Expected transport cancellation")
        } catch is CancellationError {}
        let request = await transport.request()
        let staged = try XCTUnwrap(request?.bodyFileURL)
        XCTAssertNil(request?.body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func test_defaultOriginPolicy_rejectsUnlistedHostBeforeSending() async throws {
        let transport = DicomWebScriptedTransport(responses: [])
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
        do { _ = try await client.retrieveBulkData(uri: "https://foreign.example/bulk"); XCTFail("Expected origin rejection") }
        catch {}
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func test_redirectDelegate_revalidatesEveryHopAndStripsConfiguredCredentials() async throws {
        let base = URL(string: "https://archive.example")!
        let foreign = URL(string: "https://cdn.example")!
        let policy = DicomWebOriginPolicy(configuredURL: base, allowedOrigins: [foreign])
        let delegate = DicomWebRedirectDelegate(policy: policy, credentialHeaderNames: ["x-archive-key"])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: base)
        for (destination, allowed) in [(foreign, true), (URL(string: "https://unlisted.example")!, false),
            (URL(string: "http://cdn.example")!, false), (URL(string: "https://u:p@cdn.example")!, false)] {
            var request = URLRequest(url: destination)
            for key in ["Authorization", "Cookie", "X-Archive-Key"] { request.setValue("synthetic", forHTTPHeaderField: key) }
            let result: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: task,
                    willPerformHTTPRedirection: HTTPURLResponse(url: base, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                    newRequest: request, completionHandler: { continuation.resume(returning: $0) })
            }
            XCTAssertEqual(result != nil, allowed)
            if let result {
                for key in ["Authorization", "Cookie", "X-Archive-Key"] { XCTAssertNil(result.value(forHTTPHeaderField: key)) }
            }
        }
        XCTAssertThrowsError(try policy.validate(URL(string: "http://archive.example")!, from: foreign))
    }
}

private actor A1StreamTransport: DicomWebHTTPTransport {
    let status: Int
    let headers: [String: String]
    let chunks: [Data]
    var index = 0
    var captured: DicomWebHTTPRequest?
    let cancelAfter: Int?
    init(status: Int, headers: [String: String], chunks: [Data], cancelAfter: Int? = nil) {
        self.status = status
        self.headers = headers
        self.chunks = chunks
        self.cancelAfter = cancelAfter
    }
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        XCTFail("Streaming client must not call send")
        throw DicomWebError(kind: .invalidResponse)
    }
    func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        captured = request
        return .init(statusCode: status, headers: headers, body: AsyncThrowingStream(unfolding: { try await self.nextChunk() }))
    }
    func nextChunk() throws -> Data? {
        if index == cancelAfter { withUnsafeCurrentTask { $0?.cancel() } }
        try Task.checkCancellation()
        guard index < chunks.count else { return nil }
        defer { index += 1 }
        return chunks[index]
    }
    func request() -> DicomWebHTTPRequest? { captured }
    func consumed() -> Int { index }
}


extension DicomWebClientTests {
    func test_fileAndDataSetSTOW_useFileBackedRequestAndRemoveStagingFile() async throws {
        var set = DicomDataSet()
        set.set(.init(tag: 0x00080016, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])))
        set.set(.init(tag: 0x00080018, vr: .UI, value: .strings(["1.2.3"])))
        let data = try DicomDataSetWriter.part10Data(from: set)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for fromFile in [true, false] {
            let transport = A1UploadTransport()
            let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
            if fromFile { _ = try await client.storeInstances(files: [file]) }
            else { _ = try await client.storeInstances(dataSets: [set]) }
            let request = await transport.request()
            let staged = try XCTUnwrap(request?.bodyFileURL)
            XCTAssertNil(request?.body)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
            let payloads = await transport.payloads()
            XCTAssertEqual(payloads, [data])
        }
    }

    func test_fileMetaPrefix_excessiveGroupLengthStopsAfterFixedHeader() throws {
        let original = try Self.storeFileFixture()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for groupLength in [UInt32(65_537), UInt32.max] {
            var data = Data(original.prefix(144))
            Self.setStoreGroupLength(groupLength, in: &data)
            try data.write(to: file)
            let writer = try FileHandle(forWritingTo: file)
            try writer.truncate(atOffset: 1 << 20) // Small sparse fixture; never materialize the advertised group.
            try writer.close()
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            XCTAssertThrowsError(try DicomWebClient.fileMetaPrefix(
                of: handle, length: 1 << 20, instanceIndex: 7
            )) { error in
                XCTAssertEqual(error as? DicomWebClientError, .invalidStorePart10FileMeta(instanceIndex: 7))
            }
            XCTAssertEqual(try handle.offset(), 144, "the rejected length must not control a second read")
        }
    }

    func test_fileMetaPrefix_validBelowAndAtLimitPreservesSemanticMeta() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for groupLength in [65_534, 65_536] {
            let data = try Self.storeFileFixture(groupLength: groupLength)
            try data.write(to: file)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let prefix = try DicomWebClient.fileMetaPrefix(of: handle, length: data.count, instanceIndex: 0)
            XCTAssertEqual(prefix.count, 144 + groupLength + 8)
            XCTAssertEqual(try handle.offset(), UInt64(prefix.count))
            XCTAssertEqual(try DicomPart10FileMetaParser.parse(prefix), try DicomPart10FileMetaParser.parse(data))
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func test_fileSTOW_invalidMetaSendsNoRequestAndCleansStaging() async throws {
        let original = try Self.storeFileFixture()
        let meta = try DicomPart10FileMetaParser.parse(original)
        var excessive = original
        Self.setStoreGroupLength(65_537, in: &excessive)
        var tooShort = original
        Self.setStoreGroupLength(UInt32(meta.dataSetOffset - 146), in: &tooShort)
        var tooLong = original
        Self.setStoreGroupLength(UInt32(meta.dataSetOffset - 142), in: &tooLong)
        let invalid = [
            excessive, Data(original.prefix(143)), Data(original.prefix(meta.dataSetOffset - 2)), tooShort, tooLong,
            try Self.replacingStoreMetaUID(in: original, element: 0x10, value: String(repeating: "1", count: 66)),
            try Self.replacingStoreMetaUID(in: original, element: 0x10, value: nil),
            try Self.replacingStoreMetaUID(in: original, element: 0x03, value: String(repeating: "1", count: 66))
        ]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let stagedBefore = try Self.stagedStoreFiles()
        for (index, data) in invalid.enumerated() {
            try data.write(to: file)
            let transport = A1UploadTransport()
            let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!),
                                        transport: transport)
            do {
                _ = try await client.storeInstances(files: [file])
                XCTFail("invalid fixture \(index) was sent")
            } catch {
                XCTAssertEqual(error as? DicomWebClientError, .invalidStorePart10FileMeta(instanceIndex: 0),
                               "fixture \(index)")
            }
            let requests = await transport.requests()
            XCTAssertTrue(requests.isEmpty)
            XCTAssertEqual(try Self.stagedStoreFiles(), stagedBefore)
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func test_storeFiles_invalidMetaDoesNotRemoveValidNeighborsFromBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = try Self.storeFileFixture(groupLength: 65_536)
        var excessive = valid
        Self.setStoreGroupLength(65_537, in: &excessive)
        let missingUID = try Self.replacingStoreMetaUID(in: valid, element: 0x03, value: nil)
        let data = [valid, excessive, valid, missingUID, valid]
        let files = try data.enumerated().map { index, bytes in
            let file = directory.appendingPathComponent("\(index).dcm")
            try bytes.write(to: file)
            return file
        }
        let transport = A1UploadTransport()
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!),
                                    transport: transport)
        let results = await client.storeFiles(files, options: .init(maximumFilesPerBatch: 2))
        XCTAssertEqual(results.map(\.url), files)
        XCTAssertEqual(results.map(\.state), [.unknown, .failed, .unknown, .failed, .unknown])
        for index in [1, 3] {
            XCTAssertEqual(results[index].reason, "The file has no valid File Meta Information.")
            XCTAssertNil(results[index].httpStatus)
            XCTAssertNil(results[index].sopInstanceUID)
        }
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        let payloads = await transport.payloads()
        XCTAssertEqual(payloads, [valid, valid, valid])
        XCTAssertTrue(requests.allSatisfy { $0.body == nil })
        XCTAssertTrue(requests.allSatisfy { !FileManager.default.fileExists(atPath: $0.bodyFileURL!.path) })
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, data)
    }

    func test_fileSTOW_preservesSyntaxAndBytesAndCleansAfterTransportFailure() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian, .explicitVRBigEndian] {
            let data = try Self.storeFileFixture(groupLength: 65_536, syntax: syntax)
            try data.write(to: file)
            for fail in [false, true] {
                let transport = A1UploadTransport(fail: fail)
                let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!),
                                            transport: transport)
                do {
                    _ = try await client.storeInstances(files: [file])
                    XCTAssertFalse(fail, "expected injected transport failure")
                } catch {
                    XCTAssertTrue(fail)
                    XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
                }
                let request = await transport.request()
                let staged = try XCTUnwrap(request?.bodyFileURL)
                XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
                let payloads = await transport.payloads()
                let types = await transport.contentTypes()
                XCTAssertEqual(payloads, [data])
                XCTAssertEqual(types, ["application/dicom; transfer-syntax=\(syntax.rawValue)"])
                XCTAssertEqual(try Data(contentsOf: file), data)
            }
        }
    }

    private static func storeFileFixture(groupLength: Int? = nil,
                                         syntax: DicomTransferSyntax = .explicitVRLittleEndian) throws -> Data {
        let set = DicomDataSet(elements: [
            .init(tag: 0x00080016, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.2908"])),
            .init(tag: 0x00100020, vr: .LO, value: .strings(["SYNTHETIC"]))
        ])
        var data = try DicomDataSetWriter.part10Data(from: set, options: .init(transferSyntax: syntax))
        if let groupLength {
            let offset = try DicomPart10FileMetaParser.parse(data).dataSetOffset
            let count = groupLength - (offset - 144) - 12
            var padding = Data([2, 0, 2, 1, 79, 66, 0, 0]) // (0002,0102) OB, Explicit VR Little Endian.
            padding.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: count >> (8 * $0)) })
            padding.append(Data(repeating: 0xA5, count: count))
            data.insert(contentsOf: padding, at: offset)
            setStoreGroupLength(UInt32(groupLength), in: &data)
        }
        return data
    }

    private static func replacingStoreMetaUID(in original: Data, element: UInt8, value: String?) throws -> Data {
        var data = original
        let offset = try DicomPart10FileMetaParser.parse(data).dataSetOffset
        let start = try XCTUnwrap(data[..<offset].range(of: Data([2, 0, element, 0, 85, 73]))).lowerBound
        let length = Int(data[start + 6]) | Int(data[start + 7]) << 8
        var replacement = Data()
        if let value {
            let bytes = Data(value.utf8)
            replacement.append(contentsOf: [2, 0, element, 0, 85, 73, UInt8(bytes.count), 0])
            replacement.append(bytes)
        }
        data.replaceSubrange(start..<(start + 8 + length), with: replacement)
        setStoreGroupLength(UInt32(offset - 144 + replacement.count - 8 - length), in: &data)
        return data
    }

    private static func setStoreGroupLength(_ length: UInt32, in data: inout Data) {
        data.replaceSubrange(140..<144, with: (0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) })
    }

    private static func stagedStoreFiles() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("dicomweb-stow-") })
    }

    func test_rootSelection_survivesBufferedClientConvenience() async throws {
        let body = Data(("--b\r\nContent-Type: application/octet-stream\r\nContent-ID: <other>\r\n\r\nother\r\n" +
            "--b\r\nContent-Type: application/octet-stream\r\nContent-ID: <root>\r\n\r\nroot\r\n--b--\r\n").utf8)
        let transport = DicomWebScriptedTransport(responses: [.init(statusCode: 200,
            headers: ["Content-Type": "multipart/related;boundary=b;start=\"<root>\""], body: body)])
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example")!), transport: transport)
        let object = try await client.retrieveBulkData(uri: "/bulk")
        XCTAssertEqual(object.firstPayload, Data("root".utf8))
    }
}

private actor A1UploadTransport: DicomWebHTTPTransport {
    var captured: DicomWebHTTPRequest?
    var received: [Data] = []
    var capturedRequests: [DicomWebHTTPRequest] = []
    var receivedTypes: [String?] = []
    let fail: Bool
    let cancels: Bool
    init(fail: Bool = false, cancels: Bool = false) { self.fail = fail; self.cancels = cancels }
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        XCTFail("Upload must use stream")
        throw DicomWebError(kind: .invalidResponse)
    }
    func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        captured = request
        capturedRequests.append(request)
        let file = try XCTUnwrap(request.bodyFileURL)
        let body = try Data(contentsOf: file)
        XCTAssertEqual(request.headers["Content-Length"], String(body.count))
        let parts = try DicomWebMultipartStreamParser.parts(from: body,
            contentType: XCTUnwrap(request.headers["Content-Type"]))
        received.append(contentsOf: parts.map(\.body))
        receivedTypes.append(contentsOf: parts.map(\.contentType))
        if fail { throw URLError(.networkConnectionLost) }
        if cancels { throw CancellationError() }
        return .init(statusCode: 200, body: AsyncThrowingStream { continuation in
            continuation.yield(Data("[]".utf8))
            continuation.finish()
        })
    }
    func request() -> DicomWebHTTPRequest? { captured }
    func payloads() -> [Data] { received }
    func requests() -> [DicomWebHTTPRequest] { capturedRequests }
    func contentTypes() -> [String?] { receivedTypes }
}
