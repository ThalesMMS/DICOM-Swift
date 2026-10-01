import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

final class DicomWebStoreResponseTests: XCTestCase {
    static let json = Data("""
    [{"00081190":{"vr":"UR","Value":["https://archive.example/studies/1"]},
      "00081199":{"vr":"SQ","Value":[
        {"00081150":{"vr":"UI","Value":["1.2"]},"00081155":{"vr":"UI","Value":["1.3"]}},
        {"00081155":{"vr":"UI","Value":["1.4"]},"00081196":{"vr":"US","Value":[45056]},
         "00081190":{"vr":"UR","Value":["https://archive.example/instances/1.4"]}}]},
      "00081198":{"vr":"SQ","Value":[{"00081155":{"vr":"UI","Value":["1.5"]},"00081197":{"vr":"US","Value":[42752]}}]},
      "0008119A":{"vr":"SQ","Value":[{"00081197":{"vr":"US","Value":[49152]}}]}}]
    """.utf8)

    func test_annexIJSONAndXML_preserveOutcomesAndOtherFailures() throws {
        let json = try DicomWebStoreResponse.decode(Self.json, contentType: "application/dicom+json")
        let dataSet = try DicomJSONCodec.decode(Self.json)[0].dataSet
        let xmlData = try DicomNativeXMLCodec.encode(dataSet)
        let xml = try DicomWebStoreResponse.decode(xmlData, contentType: "application/dicom+xml")
        XCTAssertEqual(json, xml)
        XCTAssertEqual(json.instances.map(\.outcome), [.accepted, .warning, .failed])
        XCTAssertEqual(json.acceptedInstanceCount, 2)
        XCTAssertEqual(json.instances[1].warningReason, 45056)
        XCTAssertEqual(json.instances[2].failureReason, 42752)
        XCTAssertEqual(json.otherFailureReasons, [49152])
        XCTAssertEqual(json.retrieveURL, "https://archive.example/studies/1")
    }

    func test_noPerInstanceEvidence_neverCountsSubmissions() throws {
        XCTAssertEqual(try DicomWebStoreResponse.decode(Data("[]".utf8), contentType: nil).acceptedInstanceCount, 0)
        let missingUID = Data("[{\"00081199\":{\"vr\":\"SQ\",\"Value\":[{}]}}]".utf8)
        XCTAssertEqual(try DicomWebStoreResponse.decode(missingUID, contentType: nil).instances.first?.outcome, .unknown)
    }

    func test_legacyResponse_withJSONParametersRetainsUnknownOutcomes() throws {
        let body = Data(#"{"sopInstanceUIDs":["2.25.1"],"stored":1}"#.utf8)
        let response = try DicomWebStoreResponse.decode(body, contentType: "Application/JSON; charset=utf-8")
        XCTAssertEqual(response.instances.map(\.sopInstanceUID), ["2.25.1"])
        XCTAssertEqual(response.instances.map(\.outcome), [.unknown])
        XCTAssertEqual(response.acceptedInstanceCount, 0)
    }
}
