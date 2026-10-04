import Foundation
import ImageIO
import XCTest
@testable import DicomCore

/// Rendered and thumbnail retrieval through `DicomWebClient` against the package server, at every level.
final class DicomWebRenderedRetrieveTests: XCTestCase {
    private static let serviceURL = URL(string: "https://server.example/dicom-web")!
    private static let study = "2.25.29490001"
    private static let series = "2.25.29490002"
    private static let instances = ["2.25.29490003", "2.25.29490004"]

    func test_options_encodeWindowViewportAndQualityAsPS318Parameters() async throws {
        let (client, transport) = try Self.client()
        let options = DicomWebRenderedOptions(window: .init(center: 40, width: 400), viewport: .init(width: 4, height: 3),
                                              quality: 80, accept: "multipart/related; type=\"image/jpeg\"")
        _ = try await client.retrieveRendered(studyInstanceUID: Self.study, seriesInstanceUID: Self.series, options: options)
        _ = try await client.retrieveThumbnail(studyInstanceUID: Self.study, options: .init(viewport: .init(width: 2, height: 2)))
        _ = try await client.retrieveRendered(studyInstanceUID: Self.study, seriesInstanceUID: Self.series,
                                              sopInstanceUID: Self.instances[0], frames: try DicomWebFrameList([1]),
                                              options: .init(window: .init(center: -0.5, width: 1.25), accept: "image/png"))
        _ = try await client.retrieveThumbnail(studyInstanceUID: Self.study, seriesInstanceUID: Self.series,
                                               sopInstanceUID: Self.instances[1], frames: try DicomWebFrameList([1]),
                                               options: .init(quality: 5, accept: "image/jpeg"))

        let base = Self.serviceURL.absoluteString
        XCTAssertEqual(transport.urls.map(\.absoluteString), [
            "\(base)/studies/\(Self.study)/series/\(Self.series)/rendered?window=40,400,linear&viewport=4,3&quality=80",
            "\(base)/studies/\(Self.study)/thumbnail?viewport=2,2",
            "\(base)/studies/\(Self.study)/series/\(Self.series)/instances/\(Self.instances[0])/frames/1/rendered"
                + "?window=-0.5,1.25,linear",
            "\(base)/studies/\(Self.study)/series/\(Self.series)/instances/\(Self.instances[1])/frames/1/thumbnail?quality=5"
        ])
    }

    func test_invalidOptions_failWithoutARequest() async throws {
        let (client, transport) = try Self.client()
        for options in [DicomWebRenderedOptions(window: .init(center: 40, width: 0)),
                        DicomWebRenderedOptions(viewport: .init(width: 0, height: 4)),
                        DicomWebRenderedOptions(quality: 101)] {
            do {
                _ = try await client.retrieveRendered(studyInstanceUID: Self.study, options: options)
                XCTFail("Expected a bad request for \(options)")
            } catch let error as DicomWebError {
                XCTAssertEqual(error.kind, .badRequest)
            }
        }
        XCTAssertTrue(transport.urls.isEmpty)
    }

    func test_seriesAndStudyRendered_returnOneMultipartPartPerInstance() async throws {
        let (client, _) = try Self.client()
        let options = DicomWebRenderedOptions(window: .init(center: 127.5, width: 255), viewport: .init(width: 4, height: 3),
                                              accept: "multipart/related; type=\"image/png\"")
        let series = try await client.retrieveRendered(studyInstanceUID: Self.study, seriesInstanceUID: Self.series,
                                                       options: options)
        let study = try await client.retrieveRendered(studyInstanceUID: Self.study, options: options)

        for object in [series, study] {
            XCTAssertEqual(object.statusCode, 200)
            XCTAssertTrue(object.contentType?.hasPrefix("multipart/related") == true)
            XCTAssertEqual(object.parts.count, 2)
            XCTAssertEqual(object.parts.map { $0.headers.dicomWebHeaderValue("Content-Type") }, ["image/png", "image/png"])
            XCTAssertEqual(object.parts.map { $0.headers.dicomWebHeaderValue("Content-Location") }, Self.instances.map {
                "\(Self.serviceURL.absoluteString)/studies/\(Self.study)/series/\(Self.series)/instances/\($0)/rendered"
                    + "?window=127.5,255,linear&viewport=4,3"
            })
            for part in object.parts { XCTAssertEqual(try Self.imageSize(part.body), [4, 3]) }
        }
    }

    func test_seriesAndStudyThumbnail_andSingleInstanceSeriesRendered_returnOneImage() async throws {
        let (client, _) = try Self.client()
        let thumbnailOptions = DicomWebRenderedOptions(viewport: .init(width: 2, height: 2), quality: 50, accept: "image/jpeg")
        let objects = [
            try await client.retrieveThumbnail(studyInstanceUID: Self.study, seriesInstanceUID: Self.series,
                                               options: thumbnailOptions),
            try await client.retrieveThumbnail(studyInstanceUID: Self.study, options: thumbnailOptions)
        ]
        for object in objects {
            XCTAssertEqual(object.statusCode, 200)
            XCTAssertEqual(object.contentType, "image/jpeg")
            XCTAssertEqual(object.parts.count, 1)
            XCTAssertEqual(try Self.imageSize(XCTUnwrap(object.firstPayload)), [2, 2])
        }

        let (single, _) = try Self.client(instanceCount: 1)
        let rendered = try await single.retrieveRendered(studyInstanceUID: Self.study, seriesInstanceUID: Self.series,
                                                         options: .init(viewport: .init(width: 3, height: 3),
                                                                        accept: "image/png"))
        XCTAssertEqual(rendered.contentType, "image/png")
        XCTAssertEqual(rendered.parts.count, 1)
        XCTAssertEqual(try Self.imageSize(XCTUnwrap(rendered.firstPayload)), [3, 3])
    }

    // MARK: - Fixture

    private static func client(instanceCount: Int = 2) throws -> (DicomWebClient, RecordingServerTransport) {
        let store = DicomWebInMemoryStore()
        for uid in instances.prefix(instanceCount) {
            try store.add(dataSet: imageDataSet(sopInstanceUID: uid), transferSyntax: .explicitVRLittleEndian)
        }
        let transport = RecordingServerTransport(
            server: DicomWebServer(configuration: DicomWebServerConfiguration(cacheEnabled: false), store: store))
        return (DicomWebClient(configuration: .init(baseURL: serviceURL), transport: transport), transport)
    }

    private static func imageDataSet(sopInstanceUID: String) -> DicomDataSet {
        func string(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement {
            DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
        }
        func unsignedShort(_ tag: DicomTag, _ value: UInt) -> DicomDataElement {
            DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value]))
        }
        return DicomDataSet(elements: [
            string(.sopClassUID, .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, .UI, sopInstanceUID),
            string(.studyInstanceUID, .UI, study),
            string(.seriesInstanceUID, .UI, series),
            string(.patientName, .PN, "RENDERED^TEST"),
            string(.patientID, .LO, "RENDERED-2949"),
            string(.modality, .CS, "OT"),
            unsignedShort(.samplesPerPixel, 1),
            string(.photometricInterpretation, .CS, "MONOCHROME2"),
            unsignedShort(.rows, 2),
            unsignedShort(.columns, 2),
            unsignedShort(.bitsAllocated, 8),
            unsignedShort(.bitsStored, 8),
            unsignedShort(.highBit, 7),
            unsignedShort(.pixelRepresentation, 0),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data([0, 85, 170, 255])))
        ])
    }

    private static func imageSize(_ data: Data) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return [image.width, image.height]
    }
}

/// Forwards to the package server and keeps every requested URL.
private final class RecordingServerTransport: DicomWebHTTPTransport, @unchecked Sendable {
    private let server: DicomWebServer
    private let lock = NSLock()
    private var recorded: [URL] = []

    init(server: DicomWebServer) { self.server = server }

    var urls: [URL] { lock.withLock { recorded } }

    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        lock.withLock { recorded.append(request.url) }
        return try await server.send(request)
    }

    func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        lock.withLock { recorded.append(request.url) }
        return try await server.stream(request)
    }
}
