import Foundation
import XCTest
@testable import DicomCore

final class DicomWebModalitiesInStudySearchTests: XCTestCase {
    private static let serviceURL = "https://server.example/dicom-web"

    /// Three studies of one patient, one CT, one MR and one US. A list of modalities matches the studies that have
    /// any of them, whether it comes comma-separated or as the key repeated.
    func test_modalitiesInStudyList_matchesStudiesWithAnyListedModality() async throws {
        let server = try Self.server()
        let cases: [(query: String, studies: Set<String>)] = [
            ("PatientID=P", ["2.25.29781", "2.25.29782", "2.25.29783"]),
            ("PatientID=P&ModalitiesInStudy=CT", ["2.25.29781"]),
            ("PatientID=P&ModalitiesInStudy=CT,MR", ["2.25.29781", "2.25.29782"]),
            ("PatientID=P&ModalitiesInStudy=CT&ModalitiesInStudy=MR", ["2.25.29781", "2.25.29782"]),
            ("PatientID=P&ModalitiesInStudy=MR,US&Modality=US", ["2.25.29783"])
        ]
        for (query, expected) in cases {
            let response = try await server.send(.init(method: .get, url: URL(string: "\(Self.serviceURL)/studies?\(query)")!))
            XCTAssertEqual(response.statusCode, 200, query)
            let studies = try DicomJSONCodec.decode(response.body).compactMap { $0.dataSet.string(for: .studyInstanceUID) }
            XCTAssertEqual(Set(studies), expected, query)
        }
        let none = try await server.send(.init(method: .get,
            url: URL(string: "\(Self.serviceURL)/studies?ModalitiesInStudy=NM,PT")!))
        XCTAssertEqual(none.statusCode, 204)
    }

    func test_repeatedKeyWithoutListMatching_isRefusedWithAMessage() async throws {
        let server = try Self.server()
        let response = try await server.send(.init(method: .get,
            url: URL(string: "\(Self.serviceURL)/studies?PatientID=P&PatientID=Q")!))
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("repeated"))
    }

    private static func server() throws -> DicomWebServer {
        let storage = DicomWebInMemoryStorage()
        for (index, modality) in ["CT", "MR", "US"].enumerated() {
            let study = "2.25.2978\(index + 1)"
            try storage.add(dataSet: DicomDataSet(elements: [
                string(.sopClassUID, .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
                string(.sopInstanceUID, .UI, study + ".3"), string(.studyInstanceUID, .UI, study),
                string(.seriesInstanceUID, .UI, study + ".2"), string(.patientID, .LO, "P"),
                string(.modality, .CS, modality)
            ]))
        }
        return DicomWebServer(configuration: DicomWebServerConfiguration(cacheEnabled: false), storage: storage)
    }

    private static func string(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        .init(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }
}
