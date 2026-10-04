import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import DicomCore

final class DicomWebServerTests: XCTestCase {
    func test_capabilities_decodesAnnexHResourcesAndMediaTypes() async throws {
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://archive.example/dicom-web")!),
                                    transport: DicomWebServer(store: DicomWebInMemoryStore()))
        let capabilities = try await client.retrieveCapabilities()
        XCTAssertTrue(capabilities.offers(path: "studies/{study}"))
        XCTAssertTrue(capabilities.offers(path: "studies/{study}/series/{series}"))
        XCTAssertTrue(capabilities.mediaTypes.contains("application/dicom"))
        XCTAssertFalse(capabilities.offers(path: "missing"))
    }

    func test_addPart10_rejectsMalformedDataWithoutStoringAnInstance() throws {
        let store = DicomWebInMemoryStorage()
        XCTAssertThrowsError(try store.add(part10Data: Data("not a DICOM file".utf8)))
        XCTAssertEqual(store.count, 0)
    }

    func test_addPart10_derivesTransferSyntaxAndRejectsMismatchedOverride() throws {
        let source = DicomWebInMemoryStorage()
        let fixture = try source.add(dataSet: Self.imageDataSet(patientName: "SYNTHETIC^PART10",
            studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3"),
            transferSyntax: .implicitVRLittleEndian)
        let store = DicomWebInMemoryStorage()
        XCTAssertThrowsError(try store.add(part10Data: fixture.part10Data, transferSyntax: .explicitVRLittleEndian))
        XCTAssertEqual(store.count, 0)
        let stored = try store.add(part10Data: fixture.part10Data)
        XCTAssertEqual(stored.transferSyntax, .implicitVRLittleEndian)
        XCTAssertEqual(stored.part10Data, fixture.part10Data)
        XCTAssertEqual(stored.sopInstanceUID, "2.25.3")
    }

    func test_retrieve_representationChangeAfterNegotiationThrowsWithoutTranscoder() async throws {
        let original = DicomWebInMemoryStorage()
        let dataSet = Self.imageDataSet(patientName: "SYNTHETIC^CHANGE", studyInstanceUID: "2.25.1",
                                       seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3")
        try original.add(dataSet: dataSet)
        let store = DicomWebReplacingTestStorage(original)
        let response = try await DicomWebServer(storage: store).stream(.init(method: .get,
            url: Self.serviceURL.appendingPathComponent("studies/2.25.1/series/2.25.2/instances/2.25.3")))
        XCTAssertEqual(response.statusCode, 200)
        let replacement = DicomWebInMemoryStorage()
        try replacement.add(dataSet: dataSet, transferSyntax: .implicitVRLittleEndian)
        await store.replace(with: replacement)
        do {
            for try await _ in response.body {}
            XCTFail("A changed representation cannot use an absent transcoder")
        } catch let error as DicomWebServerFailure {
            XCTAssertEqual(error.status, 500)
        }
    }

    func test_metadata_smallBinaryInlineAndLargeBinaryResolvesBulkRoute() async throws {
        let store = DicomWebInMemoryStore()
        let small = Data([1, 2, 3, 4, 5, 6])
        let large = Data(repeating: 0xAB, count: 1024 * 1024)
        let fixture = Self.imageDataSet(patientName: "TEST^BINARY", studyInstanceUID: "2.25.1",
                                       seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3")
        try store.add(dataSet: DicomDataSet(elements: fixture.elements + [
            .init(tag: 0x00111010, vr: .OB, value: .bytes(small)),
            .init(tag: 0x00111011, vr: .OB, value: .bytes(large)),
            .init(tag: 0x00111012, vr: .OB, value: .bytes(Data(repeating: 1, count: 64 * 1024))),
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
                .init(tag: 0x00111011, vr: .OB, value: .bytes(large)),
                .init(tag: 0x54001010, vr: .OW, value: .bytes(Data([1, 0, 2, 0, 3, 0])))
            ]))]))
        ]))
        let client = DicomWebClient(configuration: .init(baseURL: Self.serviceURL),
                                    transport: DicomWebServer(store: store))
        let metadata = try await client.retrieveStudyMetadata(studyInstanceUID: "2.25.1")
        let decoded = try XCTUnwrap(metadata.first)
        XCTAssertEqual(decoded.dataSet[0x00111010]?.value, .bytes(small))
        XCTAssertFalse(decoded.bulkData.contains { $0.tag == 0x00111010 })
        let reference = try XCTUnwrap(decoded.bulkData.first { $0.tag == 0x00111011 })
        let retrieved = try await client.retrieveBulkData(uri: reference.uri)
        XCTAssertEqual(retrieved.firstPayload, large)
        XCTAssertFalse(decoded.bulkData.contains { $0.tag == 0x00111012 })
        let nested = try XCTUnwrap(decoded.bulkData.first { $0.tag == 0x00111011 && $0.path.count > 1 })
        let nestedBytes = try await client.retrieveBulkData(uri: nested.uri)
        XCTAssertEqual(nestedBytes.firstPayload, large)
        let waveform = try XCTUnwrap(decoded.bulkData.first { $0.tag == 0x54001010 })
        let waveformBytes = try await client.retrieveBulkData(uri: waveform.uri)
        XCTAssertEqual(waveformBytes.firstPayload, Data([1, 0, 2, 0, 3, 0]))
    }

    func testConformanceMatrixListsProductionScopeAndResponsibilities() throws {
        let matrix = DicomWebConformanceMatrix.packageDefault

        XCTAssertNotNil(matrix.row(feature: "QIDO-RS"))
        XCTAssertNotNil(matrix.row(feature: "WADO-RS metadata"))
        XCTAssertNotNil(matrix.row(feature: "WADO-URI"))
        XCTAssertNotNil(matrix.row(feature: "STOW-RS"))
        XCTAssertEqual(matrix.row(feature: "UPS-RS")?.server, "A1 engine-backed worklist and notifications")
        XCTAssertEqual(matrix.row(feature: "BulkDataURI")?.client, "transport-injected")
        XCTAssertEqual(matrix.row(feature: "JPIP")?.responsibility, "DicomJPIPClient/DicomJPIPTransport/DicomJPIPServer")
        XCTAssertEqual(matrix.row(feature: "WADO-RS frame")?.server, "supported")
        XCTAssertEqual(matrix.row(feature: "WADO-RS rendered frame")?.server, "supported")
        XCTAssertEqual(matrix.row(feature: "Pagination")?.server, "limit/offset applied")
        XCTAssertTrue(try XCTUnwrap(matrix.row(feature: "Large payload streaming")?.notes).contains("one instance payload at a time"))
    }

    func testDICOMwebDocumentationExposesScopedConformanceMatrix() throws {
        let conformance = try Self.packageText("Sources/DicomCore/DicomCore.docc/Articles/ConformanceStatement.md")
        let readme = try Self.packageText("README.md")
        let gaps = try Self.packageText("IMPLEMENTATION_GAPS.md")

        for row in DicomWebConformanceMatrix.packageDefault.rows {
            XCTAssertTrue(conformance.contains(row.feature), "Missing \(row.feature) from conformance DocC.")
        }
        XCTAssertTrue(conformance.contains("not a complete production PACS"))
        XCTAssertFalse(conformance.contains("| **No DICOM Network** |"))
        XCTAssertTrue(readme.contains("DicomWebConformanceMatrix.packageDefault"))
        XCTAssertTrue(gaps.contains("Status: scoped and guarded"))
    }

    func testQIDOWADOAndSTOWRoutesThroughClientSmoke() async throws {
        let store = DicomWebInMemoryStore()
        let fixture = try store.add(dataSet: Self.imageDataSet(patientName: "DOE^JANE",
                                                               studyInstanceUID: "2.25.1",
                                                               seriesInstanceUID: "2.25.2",
                                                               sopInstanceUID: "2.25.3"))
        let server = DicomWebServer(store: store)
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: URL(string: "https://server.example/dicom-web")!),
            transport: server
        )

        let studies = try await client.searchStudies(DicomWebQuery(patientName: "DOE*"))
        let metadata = try await client.retrieveStudyMetadata(studyInstanceUID: "2.25.1")
        let object = try await client.retrieveInstance(studyInstanceUID: "2.25.1",
                                                       seriesInstanceUID: "2.25.2",
                                                       sopInstanceUID: "2.25.3")
        let storeResult = try await client.store(
            dataSet: Self.imageDataSet(patientName: "DOE^JOHN",
                                       studyInstanceUID: "2.25.4",
                                       seriesInstanceUID: "2.25.5",
                                       sopInstanceUID: "2.25.6")
        )
        let storedStudies = try await client.searchStudies(DicomWebQuery(studyInstanceUID: "2.25.4"))

        XCTAssertEqual(studies.count, 1)
        XCTAssertEqual(studies.first?.studyInstanceUID, "2.25.1")
        XCTAssertEqual(metadata.first?.dataSet.string(for: .sopInstanceUID), "2.25.3")
        XCTAssertFalse(metadata.first?.bulkData.isEmpty ?? true)
        XCTAssertEqual(object.parts.count, 1)
        XCTAssertEqual(object.firstPayload, fixture.part10Data)
        XCTAssertEqual(storeResult.statusCode, 200)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(storedStudies.first?.studyInstanceUID, "2.25.4")
    }

    func testQIDOPaginationIsAppliedOnServer() async throws {
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.imageDataSet(patientName: "DOE^A",
                                                 studyInstanceUID: "2.25.1",
                                                 seriesInstanceUID: "2.25.2",
                                                 sopInstanceUID: "2.25.3"))
        try store.add(dataSet: Self.imageDataSet(patientName: "DOE^B",
                                                 studyInstanceUID: "2.25.4",
                                                 seriesInstanceUID: "2.25.5",
                                                 sopInstanceUID: "2.25.6"))
        try store.add(dataSet: Self.imageDataSet(patientName: "DOE^C",
                                                 studyInstanceUID: "2.25.7",
                                                 seriesInstanceUID: "2.25.8",
                                                 sopInstanceUID: "2.25.9"))
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: URL(string: "https://server.example/dicom-web")!),
            transport: DicomWebServer(store: store)
        )

        let studies = try await client.searchStudies(DicomWebQuery(limit: 1, offset: 1))

        XCTAssertEqual(studies.map(\.studyInstanceUID), ["2.25.4"])
    }

    func testXMLMetadataRoute() async throws {
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.imageDataSet(patientName: "DOE^JANE",
                                                 studyInstanceUID: "2.25.1",
                                                 seriesInstanceUID: "2.25.2",
                                                 sopInstanceUID: "2.25.3"))
        let server = DicomWebServer(store: store)

        let response = try await server.send(DicomWebHTTPRequest(
            method: .get,
            url: URL(string: "https://server.example/dicom-web/studies/2.25.1/metadata")!,
            headers: ["Accept": "multipart/related; type=\"application/dicom+xml\""]
        ))

        let xml = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertEqual(response.statusCode, 200)
        let contentType = try XCTUnwrap(response.headers["Content-Type"])
        XCTAssertTrue(contentType.hasPrefix("multipart/related; type=\"application/dicom+xml\"; boundary="))
        XCTAssertTrue(xml.contains("Content-Type: application/dicom+xml"))
        let parts = try Self.multipartParts(from: response)
        XCTAssertEqual(parts.count, 1)
        try assertNativeModel(XCTUnwrap(parts.first).body)
        XCTAssertTrue(xml.contains("<NativeDicomModel xmlns=\"http://dicom.nema.org/PS3.19/models/NativeDICOM\" xml:space=\"preserve\">"))
        XCTAssertTrue(xml.contains("0020000D"))
        XCTAssertTrue(xml.contains("2.25.1"))
        XCTAssertFalse(xml.contains("DicomWebMetadata"))
    }

    func test_multipleXMLResults_useOneNativeModelPerMultipartPart() async throws {
        let store = DicomWebInMemoryStore()
        for index in 1...2 {
            try store.add(dataSet: Self.imageDataSet(patientName: "DOE^JANE",
                studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3.\(index)"))
        }
        let response = try await DicomWebServer(store: store).send(DicomWebHTTPRequest(
            method: .get, url: URL(string: "https://server.example/dicom-web/studies/2.25.1/metadata")!,
            headers: ["Accept": "multipart/related; type=\"application/dicom+xml\""]
        ))
        let parts = try Self.multipartParts(from: response)
        XCTAssertEqual(parts.count, 2)
        for part in parts {
            XCTAssertEqual(part.headers["Content-Type"], "application/dicom+xml")
            try assertNativeModel(part.body)
        }
    }

    func test_singleXMLResult_honorsMultipartAccept() async throws {
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.imageDataSet(patientName: "DOE^JANE",
            studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3"))
        let response = try await DicomWebServer(store: store).send(DicomWebHTTPRequest(
            method: .get, url: URL(string: "https://server.example/dicom-web/studies/2.25.1/metadata")!,
            headers: ["Accept": "multipart/related; type=\"application/dicom+xml\""]
        ))
        let parts = try Self.multipartParts(from: response)
        XCTAssertEqual(parts.count, 1)
        let part = try XCTUnwrap(parts.first)
        XCTAssertEqual(part.contentType, "application/dicom+xml")
        try assertNativeModel(part.body)
    }

    func test_personNameJSON_omitsEmptyRepresentations() async throws {
        for (name, expected) in [("DOE^JANE==", ["Alphabetic": "DOE^JANE"]),
                                 ("DOE^JANE=IDEOGRAPHIC=PHONETIC",
                                  ["Alphabetic": "DOE^JANE", "Ideographic": "IDEOGRAPHIC", "Phonetic": "PHONETIC"])] {
            let store = DicomWebInMemoryStore()
            try store.add(dataSet: Self.imageDataSet(patientName: name,
                studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3"))
            let response = try await DicomWebServer(store: store).send(DicomWebHTTPRequest(
                method: .get, url: URL(string: "https://server.example/dicom-web/studies/2.25.1/metadata")!
            ))
            let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
            let attribute = try XCTUnwrap(objects.first?["00100010"] as? [String: Any])
            XCTAssertEqual(attribute["Value"] as? [[String: String]], [expected])
        }
    }

    func test_emptyXMLQuery_returnsNoContent() async throws {
        let response = try await DicomWebServer().send(DicomWebHTTPRequest(
            method: .get, url: URL(string: "https://server.example/dicom-web/studies")!,
            headers: ["Accept": "multipart/related; type=\"application/dicom+xml\""]
        ))
        XCTAssertEqual(response.statusCode, 204)
        XCTAssertTrue(response.body.isEmpty)
    }

    func test_unsignedVeryLongJSON_preservesFullRange() async throws {
        let store = DicomWebInMemoryStore()
        var dataSet = Self.imageDataSet(patientName: "DOE^JANE", studyInstanceUID: "2.25.1",
                                        seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3")
        dataSet.set(DicomDataElement(tag: 0x77771001, vr: .UV, value: .unsignedIntegers([UInt.max])))
        try store.add(dataSet: dataSet)
        let response = try await DicomWebServer(store: store).send(DicomWebHTTPRequest(
            method: .get, url: URL(string: "https://server.example/dicom-web/studies/2.25.1/metadata")!
        ))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
        let attribute = try XCTUnwrap(objects.first?["77771001"] as? [String: Any])
        XCTAssertEqual(attribute["Value"] as? [String], [String(UInt.max)])
        let decoded = try XCTUnwrap(DicomJSONCodec.decode(response.body).first)
        XCTAssertEqual(decoded.dataSet[0x77771001]?.value, .unsignedIntegers([UInt.max]))
    }

    private final class XMLRoot: NSObject, XMLParserDelegate {
        var root: (name: String, attributes: [String: String])?

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if root == nil { root = (elementName, attributes) }
        }
    }

    private func assertNativeModel(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let delegate = XMLRoot()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "Invalid XML", file: file, line: line)
        let root = try XCTUnwrap(delegate.root, file: file, line: line)
        XCTAssertEqual(root.name, "NativeDicomModel", file: file, line: line)
        XCTAssertEqual(root.attributes["xml:space"], "preserve", file: file, line: line)
    }

    func testUPSIsNotARouteAndWorkitemsExist() async throws {
        let server = DicomWebServer(unifiedProcedureSteps: .init(store: DicomInMemoryUnifiedProcedureStepStore()))
        let ups = try await server.send(DicomWebHTTPRequest(
            method: .get,
            url: URL(string: "https://server.example/dicom-web/ups")!
        ))

        let workitems = try await server.send(.init(method: .get, url: URL(string: "https://server.example/dicom-web/workitems")!))
        XCTAssertEqual(workitems.statusCode, 200)
        XCTAssertEqual(server.conformanceStatement.upsSupport, .worklist)
        XCTAssertEqual(ups.statusCode, 404)
        XCTAssertEqual(ups.headers["X-DICOMweb-Error-Code"], DicomWebServerErrorCode.routeNotFound.rawValue)
    }

    func testRetrieveSingleNativeFrameReturnsExactMultipartRepresentation() async throws {
        let server = try Self.nativeMultiframeServer()
        let response = try await Self.retrieveFrames("2", from: server)
        let parts = try Self.multipartParts(from: response)

        XCTAssertEqual(response.statusCode, 200)
        Self.assertMultipartContentType(response, rootType: "application/octet-stream",
                                        transferSyntax: .explicitVRLittleEndian)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].contentType,
                       "application/octet-stream; transfer-syntax=\(DicomTransferSyntax.explicitVRLittleEndian.rawValue)")
        XCTAssertEqual(parts[0].body, Data([0x44, 0x55, 0x66, 0x77]))
        XCTAssertEqual(Self.header("Content-Location", in: parts[0].headers),
                       Self.frameURL(frameList: "2").absoluteString)
        XCTAssertEqual(Self.header("Content-Length", in: parts[0].headers), "4")
    }

    func testRetrieveMultipleNativeFramesConcatenatesBytesWithoutInterframePadding() async throws {
        let server = try Self.nativeMultiframeServer()
        let response = try await Self.retrieveFrames("1,2", from: server)
        let parts = try Self.multipartParts(from: response)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].body, Data([
            0x00, 0x11, 0x22, 0x33,
            0x44, 0x55, 0x66, 0x77
        ]))
        XCTAssertEqual(Self.header("Content-Location", in: parts[0].headers),
                       Self.frameURL(frameList: "1,2").absoluteString)
        XCTAssertEqual(Self.header("Content-Length", in: parts[0].headers), "8")
    }

    func testFrameMultipartRoundTripsThroughDicomWebClientParser() async throws {
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: Self.serviceURL),
            transport: try Self.nativeMultiframeServer()
        )

        let retrieved = try await client.retrieveFrame(
            studyInstanceUID: Self.studyUID,
            seriesInstanceUID: Self.seriesUID,
            sopInstanceUID: Self.instanceUID,
            frameNumber: 2
        )

        XCTAssertEqual(retrieved.statusCode, 200)
        XCTAssertEqual(retrieved.parts.count, 1)
        XCTAssertEqual(retrieved.firstPayload, Data([0x44, 0x55, 0x66, 0x77]))
        XCTAssertEqual(retrieved.parts[0].contentType,
                       "application/octet-stream; transfer-syntax=\(DicomTransferSyntax.explicitVRLittleEndian.rawValue)")
        XCTAssertEqual(Self.header("Content-Location", in: retrieved.parts[0].headers),
                       Self.frameURL(frameList: "2").absoluteString)
    }

    func testRetrieveSingleAndMultipleEncapsulatedFramesPreservesRLEBytesAndPartOrder() async throws {
        let expected = [
            Self.rleFrame(samples: [10, 20, 30, 40]),
            Self.rleFrame(samples: [50, 60, 70, 80])
        ]
        let server = try Self.encapsulatedMultiframeServer(fragments: expected)
        let accept = "multipart/related; type=\"image/dicom-rle\"; "
            + "transfer-syntax=\(DicomTransferSyntax.rleLossless.rawValue)"

        let singleResponse = try await Self.retrieveFrames("2", from: server, accept: accept)
        let singleParts = try Self.multipartParts(from: singleResponse)
        XCTAssertEqual(singleParts.count, 1)
        XCTAssertEqual(singleParts[0].body, expected[1])
        XCTAssertEqual(Self.header("Content-Location", in: singleParts[0].headers),
                       Self.frameURL(frameList: "2").absoluteString)

        let multipleResponse = try await Self.retrieveFrames("1,2", from: server, accept: accept)
        let multipleParts = try Self.multipartParts(from: multipleResponse)
        Self.assertMultipartContentType(multipleResponse, rootType: "image/dicom-rle", transferSyntax: .rleLossless)
        XCTAssertEqual(multipleParts.count, 2)
        XCTAssertEqual(multipleParts.map(\.body), expected)
        XCTAssertEqual(multipleParts.map { Self.header("Content-Location", in: $0.headers) }, [
            Self.frameURL(frameList: "1").absoluteString,
            Self.frameURL(frameList: "2").absoluteString
        ])
        XCTAssertEqual(multipleParts.map { Self.header("Content-Length", in: $0.headers) },
                       expected.map { String($0.count) })
        XCTAssertTrue(multipleParts.allSatisfy {
            $0.contentType == "image/dicom-rle; transfer-syntax=\(DicomTransferSyntax.rleLossless.rawValue)"
        })
    }

    func testRenderedGrayscaleFrameReturnsPNGWithExactDisplayPixels() async throws {
        let dataSet = Self.nativeImageDataSet(
            frames: [[0, 85, 170, 255]],
            rows: 2,
            columns: 2,
            windowCenter: "127.5",
            windowWidth: "255"
        )
        let server = try Self.server(dataSet: dataSet)
        let response = try await Self.retrieveRenderedFrame("1", from: server, accept: "image/png")
        let image = try Self.decodedRGBImage(from: response.body)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(Self.header("Content-Type", in: response.headers), "image/png")
        XCTAssertEqual(response.body.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.rgb, [
            0, 0, 0,
            85, 85, 85,
            170, 170, 170,
            255, 255, 255
        ])
    }

    func testRenderedRGBFrameReturnsPNGWithExactColorPixels() async throws {
        let expected: [UInt8] = [
            255, 0, 0,
            0, 255, 0,
            0, 0, 255,
            255, 255, 0
        ]
        let dataSet = Self.nativeImageDataSet(
            frames: [expected],
            rows: 2,
            columns: 2,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB"
        )
        let server = try Self.server(dataSet: dataSet)
        let response = try await Self.retrieveRenderedFrame("1", from: server, accept: "image/png")
        let image = try Self.decodedRGBImage(from: response.body)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(Self.header("Content-Type", in: response.headers), "image/png")
        XCTAssertEqual(response.body.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.rgb, expected)
    }

    func testRenderedMultipleFramesRequiresAndReturnsMultipartRelated() async throws {
        let server = try Self.nativeMultiframeServer()
        let directOnly = try await Self.retrieveRenderedFrame("1,2", from: server, accept: "image/png")
        let multipart = try await Self.retrieveRenderedFrame(
            "1,2",
            from: server,
            accept: "multipart/related; type=\"image/png\""
        )
        let parts = try Self.multipartParts(from: multipart)

        XCTAssertEqual(directOnly.statusCode, 406)
        XCTAssertEqual(Self.header("X-DICOMweb-Error-Code", in: directOnly.headers),
                       DicomWebServerErrorCode.mediaTypeNotAcceptable.rawValue)
        XCTAssertEqual(multipart.statusCode, 200)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts.map(\.contentType), ["image/png", "image/png"])
        XCTAssertEqual(parts.compactMap { Self.header("Content-Location", in: $0.headers) }, [
            Self.frameURL(frameList: "1", rendered: true).absoluteString,
            Self.frameURL(frameList: "2", rendered: true).absoluteString
        ])
    }

    func testFrameListRejectsMalformedDuplicateDescendingAndZeroValues() async throws {
        let server = try Self.nativeMultiframeServer()
        for frameList in ["abc", "0", "1,,2", "1,1", "2,1"] {
            let response = try await Self.retrieveFrames(frameList, from: server)

            XCTAssertEqual(response.statusCode, 400, frameList)
            XCTAssertEqual(
                Self.header("X-DICOMweb-Error-Code", in: response.headers),
                DicomWebServerErrorCode.invalidFrameList.rawValue,
                frameList
            )
        }
    }

    func testFrameListRejectsOutOfRangeFrameWithTypedError() async throws {
        let response = try await Self.retrieveFrames("3", from: try Self.nativeMultiframeServer())

        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(Self.header("X-DICOMweb-Error-Code", in: response.headers),
                       DicomWebServerErrorCode.frameNotFound.rawValue)
    }

    func testFrameRoutesRejectUnsupportedMediaTypesWithTyped406() async throws {
        let server = try Self.nativeMultiframeServer()
        let raw = try await Self.retrieveFrames("1", from: server, accept: "application/pdf")
        let rendered = try await Self.retrieveRenderedFrame("1", from: server, accept: "image/tiff")

        for response in [raw, rendered] {
            XCTAssertEqual(response.statusCode, 406)
            XCTAssertEqual(Self.header("X-DICOMweb-Error-Code", in: response.headers),
                           DicomWebServerErrorCode.mediaTypeNotAcceptable.rawValue)
        }
    }

    func testFrameResponseLimitReturnsTyped413WithoutPartialMultipart() async throws {
        var configuration = DicomWebServerConfiguration(cacheEnabled: false)
        configuration.maximumFrameResponseBytes = 3
        let server = try Self.nativeMultiframeServer(configuration: configuration)

        let response = try await Self.retrieveFrames("1", from: server)

        XCTAssertEqual(response.statusCode, 413)
        XCTAssertEqual(Self.header("X-DICOMweb-Error-Code", in: response.headers),
                       DicomWebServerErrorCode.frameResponseTooLarge.rawValue)
        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("--dicomweb-"))
    }

    func testFrameListConfiguredLimitsFailBeforeBuildingAResponse() async throws {
        var lengthConfiguration = DicomWebServerConfiguration(cacheEnabled: false)
        lengthConfiguration.maximumFrameListLength = 2
        let tooLong = try await Self.retrieveFrames(
            "1,2",
            from: try Self.nativeMultiframeServer(configuration: lengthConfiguration)
        )

        var countConfiguration = DicomWebServerConfiguration(cacheEnabled: false)
        countConfiguration.maximumFramesPerRequest = 1
        let tooMany = try await Self.retrieveFrames(
            "1,2",
            from: try Self.nativeMultiframeServer(configuration: countConfiguration)
        )

        for response in [tooLong, tooMany] {
            XCTAssertEqual(response.statusCode, 400)
            XCTAssertEqual(Self.header("X-DICOMweb-Error-Code", in: response.headers),
                           DicomWebServerErrorCode.invalidFrameList.rawValue)
        }
    }

    func testFrameRetrievalLeavesMetadataAndInstanceRepresentationsUnchanged() async throws {
        let store = DicomWebInMemoryStore()
        let fixture = try store.add(dataSet: Self.nativeMultiframeDataSet())
        let server = DicomWebServer(
            configuration: DicomWebServerConfiguration(cacheEnabled: false),
            store: store
        )
        let metadataURL = Self.serviceURL.appendingPathComponent("studies/\(Self.studyUID)/metadata")
        let instanceURL = Self.serviceURL.appendingPathComponent(
            "studies/\(Self.studyUID)/series/\(Self.seriesUID)/instances/\(Self.instanceUID)"
        )
        let metadataRequest = DicomWebHTTPRequest(
            method: .get,
            url: metadataURL,
            headers: ["Accept": "application/dicom+json"]
        )
        let instanceRequest = DicomWebHTTPRequest(method: .get, url: instanceURL)

        let metadataBefore = try await server.send(metadataRequest)
        let instanceBefore = try await server.send(instanceRequest)
        _ = try await Self.retrieveFrames("1,2", from: server)
        let metadataAfter = try await server.send(metadataRequest)
        let instanceAfter = try await server.send(instanceRequest)

        XCTAssertEqual(metadataAfter.statusCode, metadataBefore.statusCode)
        XCTAssertEqual(metadataAfter.headers, metadataBefore.headers)
        XCTAssertEqual(metadataAfter.body, metadataBefore.body)
        XCTAssertEqual(instanceAfter.statusCode, instanceBefore.statusCode)
        let instanceContentTypes = [instanceBefore, instanceAfter].compactMap {
            Self.header("Content-Type", in: $0.headers)
        }
        XCTAssertEqual(instanceContentTypes.count, 2)
        XCTAssertTrue(instanceContentTypes.allSatisfy {
            $0.lowercased().hasPrefix("multipart/related;") && $0.contains("type=\"application/dicom\"")
        })
        let instancePartsBefore = try Self.multipartParts(from: instanceBefore)
        let instancePartsAfter = try Self.multipartParts(from: instanceAfter)
        XCTAssertEqual(Self.header("Content-Length", in: instanceBefore.headers), String(instanceBefore.body.count))
        XCTAssertEqual(Self.header("Content-Length", in: instanceAfter.headers), String(instanceAfter.body.count))
        XCTAssertEqual(Self.header("Content-Location", in: instancePartsBefore[0].headers), instanceURL.absoluteString)
        XCTAssertEqual(Self.header("Content-Length", in: instancePartsBefore[0].headers), String(fixture.part10Data.count))
        XCTAssertEqual(instancePartsAfter.map(\.body), instancePartsBefore.map(\.body))
        XCTAssertEqual(instancePartsAfter.first?.body, fixture.part10Data)
    }

    func testWADOInstanceLabelsCompressedPartWithStoredTransferSyntax() async throws {
        let server = try Self.encapsulatedMultiframeServer(fragments: [Self.rleFrame(samples: [10, 20, 30, 40])])
        let instanceURL = Self.serviceURL.appendingPathComponent(
            "studies/\(Self.studyUID)/series/\(Self.seriesUID)/instances/\(Self.instanceUID)"
        )

        let response = try await server.send(DicomWebHTTPRequest(method: .get, url: instanceURL,
            headers: ["Accept": "multipart/related; type=\"application/dicom\"; transfer-syntax=*"]))
        let part = try XCTUnwrap(Self.multipartParts(from: response).first)

        XCTAssertEqual(
            part.contentType,
            "application/dicom; transfer-syntax=\(DicomTransferSyntax.rleLossless.rawValue)"
        )
        XCTAssertEqual(Self.header("Content-Location", in: part.headers), instanceURL.absoluteString)
    }

    func testWADOInstanceAcceptsTheTransferSyntaxQuotedOrUnquoted() async throws {
        let server = try Self.encapsulatedMultiframeServer(fragments: [Self.rleFrame(samples: [10, 20, 30, 40])])
        let instanceURL = Self.serviceURL.appendingPathComponent(
            "studies/\(Self.studyUID)/series/\(Self.seriesUID)/instances/\(Self.instanceUID)"
        )
        let rle = DicomTransferSyntax.rleLossless.rawValue
        for accept in ["multipart/related; type=\"application/dicom\"; transfer-syntax=\(rle)",
                       "multipart/related; type=\"application/dicom\"; transfer-syntax=\"\(rle)\"",
                       "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1, "
                           + "multipart/related; type=\"application/dicom\"; transfer-syntax=\(rle); q=0.9"] {
            let response = try await server.send(DicomWebHTTPRequest(method: .get, url: instanceURL,
                                                                     headers: ["Accept": accept]))
            XCTAssertEqual(response.statusCode, 200, accept)
            XCTAssertEqual(try Self.multipartParts(from: response).first?.contentType,
                           "application/dicom; transfer-syntax=\(rle)", accept)
        }
    }

    func testSTOWThenWADOPreservesCompressedPart10TransferSyntaxLabel() async throws {
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .rleLossless,
            fragments: [Self.rleFrame(samples: [10, 20, 30, 40])],
            declaredFrames: 1
        )
        dataSet.set(Self.string(DicomTag.studyInstanceUID.rawValue, .UI, Self.studyUID))
        dataSet.set(Self.string(DicomTag.seriesInstanceUID.rawValue, .UI, Self.seriesUID))
        dataSet.set(Self.string(DicomTag.sopInstanceUID.rawValue, .UI, Self.instanceUID))
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .rleLossless,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: Self.instanceUID
            )
        )
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: Self.serviceURL),
            transport: DicomWebServer(store: DicomWebInMemoryStore())
        )

        _ = try await client.storeInstances([DicomWebStoreInstance(data: part10Data, transferSyntax: nil)])
        let retrieved = try await client.retrieveInstance(
            studyInstanceUID: Self.studyUID,
            seriesInstanceUID: Self.seriesUID,
            sopInstanceUID: Self.instanceUID
        )
        let part = try XCTUnwrap(retrieved.parts.first)

        XCTAssertEqual(part.body, part10Data)
        XCTAssertEqual(
            part.contentType,
            "application/dicom; transfer-syntax=\(DicomTransferSyntax.rleLossless.rawValue)"
        )
    }

    func testSTOWRejectsPart10PayloadWithUnsupportedTransferSyntax() async throws {
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .rleLossless,
            fragments: [Self.rleFrame(samples: [10, 20, 30, 40])],
            declaredFrames: 1
        )
        dataSet.set(Self.string(DicomTag.studyInstanceUID.rawValue, .UI, Self.studyUID))
        dataSet.set(Self.string(DicomTag.seriesInstanceUID.rawValue, .UI, Self.seriesUID))
        dataSet.set(Self.string(DicomTag.sopInstanceUID.rawValue, .UI, Self.instanceUID))
        var part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .rleLossless,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: Self.instanceUID
            )
        )
        let knownUID = Data(DicomTransferSyntax.rleLossless.rawValue.utf8)
        let unknownUID = Data("1.2.840.10008.1.2.9".utf8)
        let uidRange = try XCTUnwrap(part10Data.range(of: knownUID))
        XCTAssertEqual(knownUID.count, unknownUID.count)
        part10Data.replaceSubrange(uidRange, with: unknownUID)
        let store = DicomWebInMemoryStore()
        let server = DicomWebServer(store: store)

        let response = try await server.send(DicomWebHTTPRequest(
            method: .post,
            url: Self.serviceURL.appendingPathComponent("studies"),
            headers: ["Content-Type": "application/dicom"],
            body: part10Data
        ))

        XCTAssertEqual(response.statusCode, 415)
        XCTAssertEqual(store.count, 0)
    }

    func testLargeSTOWPayloadIsPreservedByInMemoryServer() async throws {
        let store = DicomWebInMemoryStore()
        let server = DicomWebServer(store: store)
        let client = DicomWebClient(
            configuration: DicomWebClientConfiguration(baseURL: URL(string: "https://server.example/dicom-web")!),
            transport: server
        )
        var large = Self.imageDataSet(patientName: "LARGE", studyInstanceUID: "2.25.91",
                                      seriesInstanceUID: "2.25.92", sopInstanceUID: "2.25.93")
        large.set(.init(tag: 0x00111010, vr: .OB, value: .bytes(Data(repeating: 0x5A, count: 1024 * 1024))))
        let payload = try DicomDataSetWriter.part10Data(from: large)

        let result = try await client.storeInstances([DicomWebStoreInstance(data: payload)])

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.allInstances().first?.part10Data, payload)
    }

    func testOAuth2CacheConformanceAndUPSP2() async throws {
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.imageDataSet(patientName: "DOE^JANE",
                                                 studyInstanceUID: "2.25.1",
                                                 seriesInstanceUID: "2.25.2",
                                                 sopInstanceUID: "2.25.3"))
        let server = DicomWebServer(
            configuration: DicomWebServerConfiguration(requiredBearerToken: "secret",
                                                       cacheEnabled: true),
            store: store
        )
        let studiesURL = URL(string: "https://server.example/dicom-web/studies")!

        let unauthorized = try await server.send(DicomWebHTTPRequest(method: .get, url: studiesURL))
        let first = try await server.send(DicomWebHTTPRequest(method: .get,
                                                              url: studiesURL,
                                                              headers: ["Authorization": "Bearer secret"]))
        let second = try await server.send(DicomWebHTTPRequest(method: .get,
                                                               url: studiesURL,
                                                               headers: ["Authorization": "Bearer secret"]))
        let conformance = try await server.send(DicomWebHTTPRequest(
            method: .get,
            url: URL(string: "https://server.example/dicom-web/conformance")!,
            headers: ["Authorization": "Bearer secret", "Accept": "text/markdown"]
        ))
        let ups = try await server.send(DicomWebHTTPRequest(
            method: .get,
            url: URL(string: "https://server.example/dicom-web/ups")!,
            headers: ["Authorization": "Bearer secret"]
        ))

        XCTAssertEqual(unauthorized.statusCode, 401)
        XCTAssertEqual(unauthorized.headers["WWW-Authenticate"], "Bearer realm=\"DICOMweb\"")
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertNil(first.headers["X-DICOMweb-Cache"])
        XCTAssertEqual(second.headers["X-DICOMweb-Cache"], "HIT")
        XCTAssertEqual(conformance.statusCode, 200)
        XCTAssertTrue(try XCTUnwrap(String(data: conformance.body, encoding: .utf8)).contains("UPS: not configured"))
        XCTAssertTrue(try XCTUnwrap(String(data: conformance.body, encoding: .utf8)).contains("BulkDataURI"))
        let conformanceText = try XCTUnwrap(String(data: conformance.body, encoding: .utf8))
        XCTAssertTrue(conformanceText.contains("WADO-RS rendered frame"))
        XCTAssertFalse(conformanceText.contains("DICOMWEB_RENDERED_FRAME_UNSUPPORTED"))
        XCTAssertEqual(ups.statusCode, 404)
        XCTAssertEqual(ups.headers["X-DICOMweb-Error-Code"], DicomWebServerErrorCode.routeNotFound.rawValue)
        XCTAssertTrue(try XCTUnwrap(String(data: ups.body, encoding: .utf8)).contains("route not found"))
    }

    private static func imageDataSet(patientName: String,
                                     studyInstanceUID: String,
                                     seriesInstanceUID: String,
                                     sopInstanceUID: String) -> DicomDataSet {
        DicomDataSet(elements: [
            string(DicomTag.sopClassUID.rawValue,
                   .UI,
                   DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(DicomTag.sopInstanceUID.rawValue, .UI, sopInstanceUID),
            string(DicomTag.patientName.rawValue, .PN, patientName),
            string(DicomTag.patientID.rawValue, .LO, "P-1"),
            string(DicomTag.studyDate.rawValue, .DA, "20260529"),
            string(DicomTag.studyDescription.rawValue, .LO, "CT CHEST"),
            string(DicomTag.studyInstanceUID.rawValue, .UI, studyInstanceUID),
            string(DicomTag.seriesInstanceUID.rawValue, .UI, seriesInstanceUID),
            string(DicomTag.modality.rawValue, .CS, "CT"),
            string(DicomTag.conversionType.rawValue, .CS, "WSD"),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            string(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data([0x7F])))
        ])
    }

    private static let serviceURL = URL(string: "https://server.example/dicom-web")!
    private static let studyUID = "2.25.21210001"
    private static let seriesUID = "2.25.21210002"
    private static let instanceUID = "2.25.21210003"

    private static func nativeMultiframeServer(
        configuration: DicomWebServerConfiguration = DicomWebServerConfiguration(cacheEnabled: false)
    ) throws -> DicomWebServer {
        try server(dataSet: nativeMultiframeDataSet(), configuration: configuration)
    }

    private static func nativeMultiframeDataSet() -> DicomDataSet {
        nativeImageDataSet(frames: [
            [0x00, 0x11, 0x22, 0x33],
            [0x44, 0x55, 0x66, 0x77]
        ], rows: 2, columns: 2)
    }

    private static func server(
        dataSet: DicomDataSet,
        configuration: DicomWebServerConfiguration = DicomWebServerConfiguration(cacheEnabled: false)
    ) throws -> DicomWebServer {
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: dataSet, transferSyntax: .explicitVRLittleEndian)
        return DicomWebServer(configuration: configuration, store: store)
    }

    private static func encapsulatedMultiframeServer(fragments: [Data]) throws -> DicomWebServer {
        var dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .rleLossless,
            fragments: fragments,
            declaredFrames: fragments.count
        )
        dataSet.set(string(DicomTag.studyInstanceUID.rawValue, .UI, studyUID))
        dataSet.set(string(DicomTag.seriesInstanceUID.rawValue, .UI, seriesUID))
        dataSet.set(string(DicomTag.sopInstanceUID.rawValue, .UI, instanceUID))
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .rleLossless,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: instanceUID
            )
        )
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: dataSet, part10Data: part10Data, transferSyntax: .rleLossless)
        return DicomWebServer(configuration: DicomWebServerConfiguration(cacheEnabled: false), store: store)
    }

    private static func rleFrame(samples: [UInt8]) -> Data {
        precondition(!samples.isEmpty && samples.count <= 128)
        var data = Data()
        var header = [UInt32](repeating: 0, count: 16)
        header[0] = 1
        header[1] = 64
        for value in header {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(UInt8(samples.count - 1))
        data.append(contentsOf: samples)
        if data.count % 2 != 0 {
            data.append(0x00)
        }
        return data
    }

    private static func nativeImageDataSet(
        frames: [[UInt8]],
        rows: Int,
        columns: Int,
        samplesPerPixel: Int = 1,
        photometricInterpretation: String = "MONOCHROME2",
        windowCenter: String? = nil,
        windowWidth: String? = nil
    ) -> DicomDataSet {
        precondition(!frames.isEmpty)
        precondition(frames.allSatisfy { $0.count == rows * columns * samplesPerPixel })

        var pixelData = Data(frames.flatMap { $0 })
        if pixelData.count % 2 != 0 {
            pixelData.append(0x00)
        }
        var elements: [DicomDataElement] = [
            string(DicomTag.sopClassUID.rawValue,
                   .UI,
                   DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(DicomTag.sopInstanceUID.rawValue, .UI, instanceUID),
            string(DicomTag.studyInstanceUID.rawValue, .UI, studyUID),
            string(DicomTag.seriesInstanceUID.rawValue, .UI, seriesUID),
            string(DicomTag.patientName.rawValue, .PN, "FRAME^TEST"),
            string(DicomTag.patientID.rawValue, .LO, "FRAME-2121"),
            string(DicomTag.modality.rawValue, .CS, "OT"),
            string(DicomTag.conversionType.rawValue, .CS, "WSD"),
            unsignedShort(.samplesPerPixel, samplesPerPixel),
            string(DicomTag.photometricInterpretation.rawValue, .CS, photometricInterpretation),
            unsignedShort(.rows, rows),
            unsignedShort(.columns, columns),
            unsignedShort(.bitsAllocated, 8),
            unsignedShort(.bitsStored, 8),
            unsignedShort(.highBit, 7),
            unsignedShort(.pixelRepresentation, 0),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(pixelData))
        ]
        if frames.count > 1 {
            elements.insert(string(DicomTag.numberOfFrames.rawValue, .IS, String(frames.count)),
                            at: elements.count - 1)
        }
        if samplesPerPixel > 1 {
            elements.insert(unsignedShort(.planarConfiguration, 0), at: elements.count - 1)
        }
        if let windowCenter {
            elements.insert(string(DicomTag.windowCenter.rawValue, .DS, windowCenter), at: elements.count - 1)
        }
        if let windowWidth {
            elements.insert(string(DicomTag.windowWidth.rawValue, .DS, windowWidth), at: elements.count - 1)
        }
        return DicomDataSet(elements: elements)
    }

    private static func unsignedShort(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)]))
    }

    private static func frameURL(frameList: String, rendered: Bool = false) -> URL {
        var url = serviceURL
            .appendingPathComponent("studies")
            .appendingPathComponent(studyUID)
            .appendingPathComponent("series")
            .appendingPathComponent(seriesUID)
            .appendingPathComponent("instances")
            .appendingPathComponent(instanceUID)
            .appendingPathComponent("frames")
            .appendingPathComponent(frameList)
        if rendered {
            url.appendPathComponent("rendered")
        }
        return url
    }

    private static func retrieveFrames(
        _ frameList: String,
        from server: DicomWebServer,
        accept: String = "multipart/related; type=\"application/octet-stream\"; "
            + "transfer-syntax=\(DicomTransferSyntax.explicitVRLittleEndian.rawValue)"
    ) async throws -> DicomWebHTTPResponse {
        try await server.send(DicomWebHTTPRequest(
            method: .get,
            url: frameURL(frameList: frameList),
            headers: ["Accept": accept]
        ))
    }

    private static func retrieveRenderedFrame(
        _ frameList: String,
        from server: DicomWebServer,
        accept: String
    ) async throws -> DicomWebHTTPResponse {
        try await server.send(DicomWebHTTPRequest(
            method: .get,
            url: frameURL(frameList: frameList, rendered: true),
            headers: ["Accept": accept]
        ))
    }

    private static func multipartParts(from response: DicomWebHTTPResponse) throws -> [DicomWebMultipartPart] {
        let contentType = try XCTUnwrap(header("Content-Type", in: response.headers))
        let boundary = try XCTUnwrap(DicomWebMultipartParser.boundary(from: contentType))
        return try DicomWebMultipartParser.parts(from: response.body, boundary: boundary)
    }

    private static func assertMultipartContentType(
        _ response: DicomWebHTTPResponse,
        rootType: String,
        transferSyntax: DicomTransferSyntax,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let contentType = header("Content-Type", in: response.headers) else {
            return XCTFail("Missing multipart Content-Type", file: file, line: line)
        }
        XCTAssertTrue(contentType.lowercased().hasPrefix("multipart/related;"), file: file, line: line)
        XCTAssertTrue(contentType.contains("type=\"\(rootType)\""), file: file, line: line)
        XCTAssertTrue(contentType.contains("transfer-syntax=\(transferSyntax.rawValue)"), file: file, line: line)
        XCTAssertNotNil(DicomWebMultipartParser.boundary(from: contentType), file: file, line: line)
    }

    private static func header(_ field: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value
    }

    private static func decodedRGBImage(from data: Data) throws -> (width: Int, height: Int, rgb: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else {
            throw NSError(domain: "DicomWebServerTests",
                          code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not render response image into RGBA pixels."])
        }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(image.width * image.height * 3)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(contentsOf: rgba[offset..<(offset + 3)])
        }
        return (image.width, image.height, rgb)
    }

    private static func string(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    private static func packageText(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func packageRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: candidate.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "DicomWebServerTests",
                      code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not locate DICOM-Swift package root."])
    }
}

extension DicomWebServerTests {
    func test_allSearchAndMetadataRoutes_matchingProjectionAndLimits() async throws {
        let storage = DicomWebInMemoryStorage()
        for n in 1...2 {
            try storage.add(dataSet: Self.imageDataSet(patientName: "TEST^\(n)", studyInstanceUID: "2.25.1",
                seriesInstanceUID: "2.25.\(n + 10)", sopInstanceUID: "2.25.\(n + 20)"))
        }
        var configuration = DicomWebServerConfiguration()
        configuration.maximumSearchResults = 1
        let server = DicomWebServer(configuration: configuration, storage: storage)
        for path in ["studies", "series", "instances", "studies/2.25.1/series", "studies/2.25.1/instances",
                     "studies/2.25.1/series/2.25.11/instances"] {
            let response = try await server.send(.init(method: .get, url: Self.serviceURL.appendingPathComponent(path)))
            XCTAssertEqual(response.statusCode, 200, path)
            XCTAssertEqual(try DicomJSONCodec.decode(response.body).count, 1, path)
        }
        let limited = try await server.send(.init(method: .get, url: Self.serviceURL.appendingPathComponent("instances")))
        XCTAssertTrue(limited.headers["Warning"]?.contains("299") == true)
        for query in ["PatientName=TEST*", "StudyDate=20200101-20300101", "0020000D=2.25.1", "fuzzymatching=true", "includefield=StudyDescription"] {
            let response = try await server.send(.init(method: .get, url: URL(string: Self.serviceURL.absoluteString + "/studies?" + query)!))
            XCTAssertEqual(response.statusCode, 200, query)
        }
        for query in ["limit=-1", "offset=x", "PatientName=A&PatientName=B", "includefield=Unknown", "fuzzymatching=invalid"] {
            let response = try await server.send(.init(method: .get, url: URL(string: Self.serviceURL.absoluteString + "/studies?" + query)!))
            XCTAssertEqual(response.statusCode, 400, query)
        }
        for path in ["studies/2.25.1", "studies/2.25.1/series/2.25.11", "studies/2.25.1/series/2.25.11/instances/2.25.21"] {
            let aggregate = try await server.send(.init(method: .get, url: Self.serviceURL.appendingPathComponent(path),
                headers: ["Accept": DicomWebMediaTypeNegotiator.acceptHeader(for: .instance)]))
            XCTAssertEqual(aggregate.statusCode, 200)
            let metadata = try await server.send(.init(method: .get, url: Self.serviceURL.appendingPathComponent(path + "/metadata")))
            XCTAssertEqual(metadata.statusCode, 200)
            let thumbnail = try await server.send(.init(method: .get, url: Self.serviceURL.appendingPathComponent(path + "/thumbnail"), headers: ["Accept": "image/jpeg"]))
            XCTAssertEqual(thumbnail.statusCode, 200)
        }
        let absent = try await server.send(.init(method: .get, url: URL(string: Self.serviceURL.absoluteString + "/studies?PatientName=absent")!))
        XCTAssertEqual(absent.statusCode, 200)
        XCTAssertEqual(String(decoding: absent.body, as: UTF8.self), "[]")
    }

    func test_streamingSTOW_arbitrarySplitsMixedFailuresAndUnsupportedMedia() async throws {
        let fixture = try DicomWebInMemoryStorage().add(dataSet: Self.imageDataSet(patientName: "STREAM", studyInstanceUID: "2.25.1",
            seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3"))
        let boundary = "split-stow"
        let bytes = Data("--\(boundary)\r\nContent-Type: application/dicom\r\n\r\n".utf8) + fixture.part10Data + Data("\r\n--\(boundary)--\r\n".utf8)
        let type = "multipart/related; type=\"application/dicom\"; boundary=\(boundary)"
        for size in [1, 2, 7, 31, 1024] {
            let server = DicomWebServer()
            let body = AsyncThrowingStream<Data, Error> { continuation in
                for start in stride(from: 0, to: bytes.count, by: size) { continuation.yield(Data(bytes.dropFirst(start).prefix(size))) }
                continuation.finish()
            }
            let response = await server.handleStreaming(.init(method: .post, url: Self.serviceURL.appendingPathComponent("studies"), headers: ["Content-Type": type]), body: body)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(server.store.allInstances().first?.part10Data, fixture.part10Data)
        }
        let server = DicomWebServer()
        let mismatch = try await server.send(.init(method: .post, url: Self.serviceURL.appendingPathComponent("studies/2.25.99"), headers: ["Content-Type": type], body: bytes))
        XCTAssertEqual(mismatch.statusCode, 409)
        let failures = try DicomWebStoreResponse.decode(mismatch.body, contentType: mismatch.headers["Content-Type"])
        XCTAssertEqual(failures.instances.first?.failureReason, 0xA900)
        XCTAssertEqual(server.store.count, 0)
        let different = try DicomWebInMemoryStorage().add(dataSet: Self.imageDataSet(patientName: "OTHER", studyInstanceUID: "2.25.99",
            seriesInstanceUID: "2.25.98", sopInstanceUID: "2.25.97"))
        let mixedBytes = Data(bytes.dropLast(Data("--\(boundary)--\r\n".utf8).count))
            + Data("--\(boundary)\r\nContent-Type: application/dicom\r\n\r\n".utf8) + different.part10Data
            + Data("\r\n--\(boundary)--\r\n".utf8)
        let mixed = try await server.send(.init(method: .post, url: Self.serviceURL.appendingPathComponent("studies/2.25.1"), headers: ["Content-Type": type], body: mixedBytes))
        XCTAssertEqual(mixed.statusCode, 202)
        let mixedReport = try DicomWebStoreResponse.decode(mixed.body, contentType: mixed.headers["Content-Type"])
        XCTAssertEqual(mixedReport.acceptedInstanceCount, 1)
        XCTAssertEqual(mixedReport.instances.filter { $0.outcome == .failed }.count, 1)
        let syntaxBytes = Data("--\(boundary)\r\nContent-Type: application/dicom; transfer-syntax=1.2.840.10008.1.2.5\r\n\r\n".utf8)
            + fixture.part10Data + Data("\r\n--\(boundary)--\r\n".utf8)
        let syntaxMismatch = try await server.send(.init(method: .post, url: Self.serviceURL.appendingPathComponent("studies"),
            headers: ["Content-Type": type, "Accept": "multipart/related; type=\"application/dicom+xml\""], body: syntaxBytes))
        XCTAssertEqual(syntaxMismatch.statusCode, 409)
        let xmlPart = try Self.multipartParts(from: syntaxMismatch)[0]
        XCTAssertEqual(try DicomWebStoreResponse.decode(xmlPart.body, contentType: "application/dicom+xml").instances.first?.failureReason, 0xC122)
        let unsupported = try await server.send(.init(method: .post, url: Self.serviceURL.appendingPathComponent("studies"), headers: ["Content-Type": "text/plain"], body: bytes))
        XCTAssertEqual(unsupported.statusCode, 415)
        let malformed = try await server.send(.init(method: .post, url: Self.serviceURL.appendingPathComponent("studies"), headers: ["Content-Type": type], body: Data(bytes.dropLast(10))))
        XCTAssertEqual(malformed.statusCode, 400)
        var config = DicomWebServerConfiguration(); config.maximumRequestBodyBytes = 10
        let tooLarge = try await DicomWebServer(configuration: config).send(.init(method: .post, url: Self.serviceURL.appendingPathComponent("studies"), headers: ["Content-Type": type], body: bytes))
        XCTAssertEqual(tooLarge.statusCode, 413)
    }

    func test_aggregateNegotiationAndWADOURI_neverMislabelBytes() async throws {
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: Self.imageDataSet(patientName: "NEGOTIATE", studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3"))
        try store.add(dataSet: Self.imageDataSet(patientName: "NEGOTIATE", studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.4"), transferSyntax: .implicitVRLittleEndian)
        let server = DicomWebServer(store: store)
        let aggregate = try await server.send(.init(method: .get, url: Self.serviceURL.appendingPathComponent("studies/2.25.1"), headers: ["Accept": "multipart/related; type=\"application/dicom\"; transfer-syntax=*"]))
        XCTAssertEqual(aggregate.statusCode, 406) // 2026c: no application-level 206.
        for type in ["application/dicom", "image/jpeg", "image/png"] {
            let url = URL(string: Self.serviceURL.absoluteString + "/wado?requestType=WADO&studyUID=2.25.1&seriesUID=2.25.2&objectUID=2.25.3&contentType=" + type)!
            let response = try await server.send(.init(method: .get, url: url))
            XCTAssertEqual(response.statusCode, type == "image/png" ? 406 : 200)
            if type == "image/jpeg" { XCTAssertEqual(response.body.prefix(2), Data([0xFF, 0xD8])) }
        }
        let bad = try await server.send(.init(method: .get, url: Self.serviceURL.appendingPathComponent("bulkdata/Li4vZXRjL3Bhc3N3ZA")))
        XCTAssertEqual(bad.statusCode, 404)
        let capabilities = try await server.send(.init(method: .get, url: Self.serviceURL, headers: ["Accept": "application/json"]))
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: capabilities.body) as? [String: Any])?["application"])
        let wadl = try await server.send(.init(method: .get, url: Self.serviceURL, headers: ["Accept": "application/vnd.sun.wadl+xml"]))
        XCTAssertTrue(String(decoding: wadl.body, as: UTF8.self).contains("<application"))
    }

    func test_injectedAuthentication_basicAndJWTDenial() async throws {
        let basic = DicomWebServer(authentication: DicomWebBasicAuthentication(username: "test", password: "secret"))
        let denied = try await basic.send(.init(method: .get, url: Self.serviceURL))
        XCTAssertEqual(denied.statusCode, 401)
        XCTAssertTrue(denied.headers["WWW-Authenticate"]?.contains("Basic") == true)
        let allowed = try await basic.send(.init(method: .get, url: Self.serviceURL, headers: ["Authorization": "Basic " + Data("test:secret".utf8).base64EncodedString()]))
        XCTAssertEqual(allowed.statusCode, 200)
        let jwt = DicomWebServer(authentication: DicomWebJWTAuthentication { _ in .deny(statusCode: 403, challenge: nil) })
        let forbidden = try await jwt.send(.init(method: .get, url: Self.serviceURL, headers: ["Authorization": "Bearer signed" ]))
        XCTAssertEqual(forbidden.statusCode, 403)
    }
}

extension DicomWebServerTests {
    func test_injectedTranscoder_qualifiesAndExecutesRequestedRepresentation() async throws {
        let storage = DicomWebInMemoryStorage()
        let original = try storage.add(dataSet: Self.imageDataSet(patientName: "TRANSCODE", studyInstanceUID: "2.25.1",
            seriesInstanceUID: "2.25.2", sopInstanceUID: "2.25.3"), transferSyntax: .implicitVRLittleEndian)
        let server = DicomWebServer(storage: storage, transcoding: DicomWebTestTranscoder())
        let response = try await server.send(.init(method: .get, url: Self.serviceURL.appendingPathComponent("studies/2.25.1"),
            headers: ["Accept": "multipart/related; type=\"application/dicom\""]))
        XCTAssertEqual(response.statusCode, 200)
        let part = try Self.multipartParts(from: response)[0]
        XCTAssertEqual(try DicomPart10FileMetaParser.parse(part.body).transferSyntaxUID, DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertNotEqual(part.body, original.part10Data)
        XCTAssertEqual(try DicomPart10FileMetaParser.parse(part.body).mediaStorageSOPInstanceUID, original.sopInstanceUID)
    }
}

private struct DicomWebTestTranscoder: DicomWebServerTranscoding {
    var transferSyntaxUIDs: [String] { [DicomTransferSyntax.explicitVRLittleEndian.rawValue] }
    func canTranscode(from storedSyntaxUID: String, to requestedSyntaxUID: String) -> Bool {
        storedSyntaxUID == DicomTransferSyntax.implicitVRLittleEndian.rawValue && transferSyntaxUIDs.contains(requestedSyntaxUID)
    }
    func transcode(_ instance: DicomWebStoredInstance, to transferSyntaxUID: String) async throws -> Data {
        try DicomDataSetWriter.part10Data(from: instance.dataSet, options: .init(transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: instance.sopClassUID, mediaStorageSOPInstanceUID: instance.sopInstanceUID))
    }
}

private actor DicomWebReplacingTestStorage: DicomWebStorageProviding {
    private var storage: DicomWebInMemoryStorage
    init(_ storage: DicomWebInMemoryStorage) { self.storage = storage }
    func replace(with storage: DicomWebInMemoryStorage) { self.storage = storage }
    func searchStudies(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] {
        try await storage.searchStudies(parameters: parameters)
    }
    func searchSeries(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] {
        try await storage.searchSeries(parameters: parameters)
    }
    func searchInstances(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] {
        try await storage.searchInstances(parameters: parameters)
    }
    func metadata(study: String, series: String?, instance: String?) async throws -> [DicomDataSet] {
        try await storage.metadata(study: study, series: series, instance: instance)
    }
    func instance(study: String, series: String, instance: String) async throws -> DicomWebStoredInstance {
        try await storage.instance(study: study, series: series, instance: instance)
    }
    func bulkData(uri: String) async throws -> Data { try await storage.bulkData(uri: uri) }
    func store(instances: [DicomWebStoredInstance]) async throws -> [DicomWebStorageResult] {
        try await storage.store(instances: instances)
    }
}
