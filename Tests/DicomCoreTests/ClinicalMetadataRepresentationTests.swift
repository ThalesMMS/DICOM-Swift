import Foundation
import XCTest
@testable import DicomCore

final class ClinicalMetadataRepresentationTests: XCTestCase {
    func test_jsonPreservesEveryPersonNameGroupSequenceItemAndBinaryByte() async throws {
        let server = try server()
        let response = try await server.send(request(accept: "application/dicom+json"))
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])
        let object = try XCTUnwrap(objects.first)
        let person = try XCTUnwrap(object["00100010"] as? [String: Any])
        let names = try XCTUnwrap(person["Value"] as? [[String: String]])
        XCTAssertEqual(names, [["Alphabetic": "SYNTHETIC^CORPUS", "Ideographic": "字^形", "Phonetic": "TEST^VOICE"]])
        let client = DicomWebClient(configuration: .init(baseURL: Self.baseURL), transport: server)
        let dataSets = try await client.retrieveStudyMetadata(studyInstanceUID: "2.25.2366000")
        let decoded = try XCTUnwrap(dataSets.first?.dataSet)
        XCTAssertEqual(decoded.string(for: .patientName), Self.personName)
        let items = decoded.sequenceItems(for: 0x0040A730)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { $0.dataSet.string(for: 0x00080104) }, ["first <&> item", "second Δ item"])
        XCTAssertEqual(decoded.element(for: 0x00111010)?.value, .bytes(Self.binary))
    }

    #if os(macOS)
    func test_xmlPreservesEveryPersonNameGroupSequenceItemAndBinaryByte() async throws {
        let response = try await server().send(request(accept: "application/dicom+xml"))
        let contentType = try XCTUnwrap(response.headers["Content-Type"])
        XCTAssertTrue(contentType.hasPrefix("multipart/related; type=\"application/dicom+xml\""))
        let parts = try DicomWebMultipartParser.parts(from: response.body, boundary: try XCTUnwrap(DicomWebMultipartParser.boundary(from: contentType)))
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].contentType, "application/dicom+xml")
        let document = try XMLDocument(data: parts[0].body)
        XCTAssertEqual(document.rootElement()?.name, "NativeDicomModel")
        XCTAssertEqual(document.rootElement()?.namespaces?.first?.stringValue, "http://dicom.nema.org/PS3.19/models/NativeDICOM")
        // The standard document decodes back to the served data set through the shared codec.
        let roundTrip = try DicomNativeXMLCodec.decode(parts[0].body).dataSet
        XCTAssertEqual(roundTrip.string(for: .patientName), Self.personName)
        XCTAssertEqual(roundTrip.element(for: 0x00111010)?.value, .bytes(Self.binary))
        let sequencePath = "//*[local-name()='DicomAttribute'][@tag='0040A730']/*[local-name()='Item']"
        let items = try document.nodes(forXPath: sequencePath)
        XCTAssertEqual(items.count, 2)
        for (index, expected) in ["first <&> item", "second Δ item"].enumerated() {
            let path = sequencePath + "[@number='\(index + 1)']/*[local-name()='DicomAttribute'][@tag='00080104']/*[local-name()='Value']"
            XCTAssertEqual(try document.nodes(forXPath: path).map(\.stringValue), [expected])
        }
        let binary = try document.nodes(forXPath: "//*[local-name()='DicomAttribute'][@tag='00111010']/*[local-name()='InlineBinary']")
        XCTAssertEqual(binary.first?.stringValue.flatMap { Data(base64Encoded: $0) }, Self.binary)
        for (group, family, given) in [("Alphabetic", "SYNTHETIC", "CORPUS"), ("Ideographic", "字", "形"),
                                       ("Phonetic", "TEST", "VOICE")] {
            let base = "//*[local-name()='DicomAttribute'][@tag='00100010']/*[local-name()='PersonName'][@number='1']/*[local-name()='\(group)']"
            XCTAssertEqual(try document.nodes(forXPath: base + "/*[local-name()='FamilyName']").first?.stringValue, family)
            XCTAssertEqual(try document.nodes(forXPath: base + "/*[local-name()='GivenName']").first?.stringValue, given)
        }
    }
    #endif

    private func server() throws -> DicomWebServer {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IndependentDifferential/gray8.dcm")
        let decoder = try DCMDecoder(contentsOf: url)
        var dataSet = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
        dataSet.set(DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings([Self.personName])))
        dataSet.set(DicomDataElement(tag: 0x00110010, vr: .LO, value: .strings(["ISIS QA"])))
        dataSet.set(DicomDataElement(tag: 0x00111010, vr: .OB, value: .bytes(Self.binary)))
        let items = ["first <&> item", "second Δ item"].map { value in
            DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(tag: 0x00080104, vr: .LO, value: .strings([value]))
            ]))
        }
        dataSet.set(DicomDataElement(tag: 0x0040A730, vr: .SQ, value: .sequence(items)))
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: dataSet)
        return DicomWebServer(store: store)
    }

    private func request(accept: String) -> DicomWebHTTPRequest {
        .init(method: .get, url: Self.baseURL.appendingPathComponent("studies/2.25.2366000/metadata"),
              headers: ["Accept": accept])
    }

    private static let baseURL = URL(string: "https://synthetic.invalid/dicom-web")!
    private static let personName = "SYNTHETIC^CORPUS=字^形=TEST^VOICE"
    private static let binary = Data([0, 1, 127, 128, 254, 255])
}
