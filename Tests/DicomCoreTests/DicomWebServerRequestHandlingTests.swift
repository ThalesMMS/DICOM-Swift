import Foundation
import XCTest
@testable import DicomCore

final class DicomWebServerRequestHandlingTests: XCTestCase {
    private static let base = "http://127.0.0.1:8080/dicom-web/"

    func test_wrongMethodOnServedRoute_returns405WithAllow() async throws {
        let server = DicomWebServer()
        for (method, path, allowed) in [
            (DicomWebHTTPMethod.put, "studies/2.25.1/series/2.25.2/instances/2.25.3", "GET"),
            (.delete, "studies/2.25.1/series/2.25.2", "GET"),
            (.delete, "studies/2.25.1", "GET, POST"),
            (.put, "studies", "GET, POST"),
            (.post, "series", "GET"),
            (.post, "studies/2.25.1/metadata", "GET"),
            (.post, "studies/2.25.1/series/2.25.2/instances/2.25.3/frames/1", "GET"),
            (.post, "studies/2.25.1/series/2.25.2/instances/2.25.3/frames/1/rendered", "GET"),
            (.delete, "studies/2.25.1/series/2.25.2/instances", "GET"),
            (.post, "", "GET")
        ] {
            let response = try await server.send(.init(method: method, url: URL(string: Self.base + path)!))
            XCTAssertEqual(response.statusCode, 405, path)
            XCTAssertEqual(response.headers["Allow"], allowed, path)
        }
        for path in ["studies/2.25.1/unknown", "studies/2.25.1/series/2.25.2/frames/1", "other"] {
            let response = try await server.send(.init(method: .delete, url: URL(string: Self.base + path)!))
            XCTAssertEqual(response.statusCode, 404, path)
            XCTAssertNil(response.headers["Allow"], path)
        }
    }

    func test_emptySearch_isNoContentInJSONAndXML() async throws {
        let storage = DicomWebInMemoryStorage()
        try storage.add(dataSet: Self.dataSet(bodyPart: "CHEST", sop: "2.25.3"))
        let server = DicomWebServer(storage: storage)
        for path in ["studies?PatientName=ABSENT", "series?Modality=MR", "studies/2.25.1/instances?SOPInstanceUID=2.25.9"] {
            for accept in ["application/dicom+json", "multipart/related; type=\"application/dicom+xml\""] {
                let response = try await server.send(.init(method: .get, url: URL(string: Self.base + path)!,
                                                            headers: ["Accept": accept]))
                XCTAssertEqual(response.statusCode, 204, "\(path) \(accept)")
                XCTAssertTrue(response.body.isEmpty, "\(path) \(accept)")
                XCTAssertNil(response.headers["Content-Type"], "\(path) \(accept)")
            }
        }
    }

    func test_dictionaryAttributeSearch_andUnknownParametersIgnoredWithWarning() async throws {
        let storage = DicomWebInMemoryStorage()
        try storage.add(dataSet: Self.dataSet(bodyPart: "CHEST", sop: "2.25.3", series: "2.25.2"))
        try storage.add(dataSet: Self.dataSet(bodyPart: "ABDOMEN", sop: "2.25.13", series: "2.25.12"))
        let server = DicomWebServer(storage: storage)
        let response = try await server.send(.init(method: .get, url: URL(string: Self.base
            + "series?BodyPartExamined=CHEST&_=123&includefield=ProtocolName,NoSuchKeyword")!))
        XCTAssertEqual(response.statusCode, 200)
        let sets = try DicomJSONCodec.decode(response.body).map(\.dataSet)
        XCTAssertEqual(sets.map { $0.string(for: .seriesInstanceUID) }, ["2.25.2"])
        XCTAssertEqual(sets.first?.string(for: 0x00180015), "CHEST")
        XCTAssertEqual(sets.first?.string(for: 0x00181030), "PROTOCOL CHEST")
        let warning = try XCTUnwrap(response.headers["Warning"])
        XCTAssertTrue(warning.hasPrefix("299 "), warning)
        XCTAssertTrue(warning.contains("ignored: _\""), warning)
        XCTAssertTrue(warning.contains("ignored: NoSuchKeyword\""), warning)
        // A sequence cannot be a matching key, and a numeric tag outside the dictionary names nothing.
        let unmatchable = try await server.send(.init(method: .get, url: URL(string: Self.base
            + "instances?ReferencedImageSequence=x&00091001=y&ProtocolName=PROTOCOL%20ABDOMEN")!))
        XCTAssertEqual(unmatchable.statusCode, 200)
        XCTAssertEqual(try DicomJSONCodec.decode(unmatchable.body).map { $0.dataSet.string(for: .sopInstanceUID) }, ["2.25.13"])
        XCTAssertEqual(unmatchable.headers["Warning"]?.components(separatedBy: "299 ").count, 3)
        let unsafe = try await server.send(.init(method: .get, url: URL(string: Self.base + "studies?%22%0D%0AX=1")!))
        XCTAssertEqual(unsafe.statusCode, 200)
        XCTAssertFalse(unsafe.headers["Warning"]?.contains("\r") ?? true)
    }

    func test_publicBaseURL_locatesBulkDataStoreAndFrameResponses() async throws {
        var configuration = DicomWebServerConfiguration()
        configuration.publicBaseURL = URL(string: "https://pacs.example/archive/dicom-web")!
        let server = DicomWebServer(configuration: configuration)
        let stored = try await Self.store(on: server)
        XCTAssertEqual(stored, ["https://pacs.example/archive/dicom-web/studies/2.25.1/series/2.25.2/instances/2.25.3"])
        let metadata = try await server.send(.init(method: .get, url: URL(string: Self.base + "studies/2.25.1/metadata")!))
        let pixels = try XCTUnwrap(try JSONSerialization.jsonObject(with: metadata.body) as? [[String: [String: Any]]]).first?["7FE00010"]
        let bulk = try XCTUnwrap(pixels?["BulkDataURI"] as? String)
        XCTAssertTrue(bulk.hasPrefix("https://pacs.example/archive/dicom-web/bulkdata/"), bulk)
        let frame = try await server.send(.init(method: .get, url: URL(string: Self.base
            + "studies/2.25.1/series/2.25.2/instances/2.25.3/frames/1")!,
            headers: ["Accept": "multipart/related; type=\"application/octet-stream\"; transfer-syntax=*"]))
        XCTAssertEqual(frame.statusCode, 200)
        XCTAssertTrue(String(decoding: frame.body, as: UTF8.self).contains(
            "Content-Location: https://pacs.example/archive/dicom-web/studies/2.25.1/series/2.25.2/instances/2.25.3/frames/1"))
    }

    func test_forwardedHeaders_applyOnlyWhenTrusted() async throws {
        let headers = ["X-Forwarded-Proto": "https", "X-Forwarded-Host": "proxy.example:8443, inner.example"]
        var trusted = DicomWebServerConfiguration()
        trusted.trustsForwardedHeaders = true
        let forwarded = try await Self.store(on: DicomWebServer(configuration: trusted), headers: headers)
        XCTAssertEqual(forwarded, ["https://proxy.example:8443/dicom-web/studies/2.25.1/series/2.25.2/instances/2.25.3"])
        let direct = try await Self.store(on: DicomWebServer(), headers: headers)
        XCTAssertEqual(direct, ["http://127.0.0.1:8080/dicom-web/studies/2.25.1/series/2.25.2/instances/2.25.3"])
    }

    /// Stores one instance through STOW-RS and returns the instance RetrieveURL values of the response.
    private static func store(on server: DicomWebServer,
                              headers: [String: String] = [:]) async throws -> [String] {
        let part10 = try DicomWebInMemoryStorage().add(dataSet: dataSet(bodyPart: "CHEST", sop: "2.25.3")).part10Data
        let boundary = "request-handling"
        let body = Data("--\(boundary)\r\nContent-Type: application/dicom\r\n\r\n".utf8) + part10
            + Data("\r\n--\(boundary)--\r\n".utf8)
        let response = try await server.send(.init(method: .post, url: URL(string: base + "studies")!,
            headers: headers.merging(["Content-Type": "multipart/related; type=\"application/dicom\"; boundary=\(boundary)"]) { $1 },
            body: body))
        XCTAssertEqual(response.statusCode, 200)
        let report = try XCTUnwrap(try DicomJSONCodec.decode(response.body).first?.dataSet)
        let urls = report.sequenceItems(for: 0x00081199).compactMap { $0.dataSet.string(for: 0x00081190) }
        return urls
    }

    private static func dataSet(bodyPart: String, sop: String, series: String = "2.25.2") -> DicomDataSet {
        func text(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
            DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
        }
        func short(_ tag: Int, _ value: UInt) -> DicomDataElement {
            DicomDataElement(tag: tag, vr: .US, value: .unsignedIntegers([value]))
        }
        return DicomDataSet(elements: [
            text(DicomTag.sopClassUID.rawValue, .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            text(DicomTag.sopInstanceUID.rawValue, .UI, sop),
            text(DicomTag.patientName.rawValue, .PN, "SYNTHETIC^REQUEST"),
            text(DicomTag.patientID.rawValue, .LO, "SYNTHETIC-1"),
            text(DicomTag.studyInstanceUID.rawValue, .UI, "2.25.1"),
            text(DicomTag.seriesInstanceUID.rawValue, .UI, series),
            text(DicomTag.modality.rawValue, .CS, "OT"),
            text(0x00180015, .CS, bodyPart),
            text(0x00181030, .LO, "PROTOCOL \(bodyPart)"),
            short(DicomTag.samplesPerPixel.rawValue, 1),
            text(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
            short(DicomTag.rows.rawValue, 1), short(DicomTag.columns.rawValue, 1),
            short(DicomTag.bitsAllocated.rawValue, 8), short(DicomTag.bitsStored.rawValue, 8),
            short(DicomTag.highBit.rawValue, 7), short(DicomTag.pixelRepresentation.rawValue, 0),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data([0x7F])))
        ])
    }
}
