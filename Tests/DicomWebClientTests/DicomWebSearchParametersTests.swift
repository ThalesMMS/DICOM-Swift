import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

final class DicomWebSearchParametersTests: XCTestCase {
    func test_queryRoundTrip_preservesPNUIDListsAndReservedCharacters() throws {
        let parameters = DicomWebSearchParameters(level: .instance, studyInstanceUID: "1.2", seriesInstanceUID: "1.3",
            matches: [.init("PatientName", vr: .PN, values: ["José^A=B&C,#[]+"]),
                      .init("SOPInstanceUID", vr: .UI, values: ["1.4", "1.5"])],
            fuzzyMatching: true, includeFields: ["PatientID", "0020000D"], limit: 20, offset: 40)
        let url = try parameters.url(relativeTo: URL(string: "https://archive.example/dicom-web")!)
        XCTAssertEqual(url.path, "/dicom-web/studies/1.2/series/1.3/instances")
        XCTAssertTrue(url.absoluteString.contains("%2C"))
        XCTAssertTrue(url.absoluteString.contains("%26"))
        let parsed = try DicomWebSearchParameters.parse(queryItems: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!,
            level: .instance, studyInstanceUID: "1.2", seriesInstanceUID: "1.3",
            vrForAttribute: { $0 == "PatientName" ? .PN : .UI })
        XCTAssertEqual(parsed, parameters)
    }
    /// Issue #2888: non-ASCII values are percent-encoded as UTF-8 bytes; "*" stays a literal wildcard, a "," inside
    /// a value is encoded and UID lists keep working.
    func test_nonASCIIValues_encodeAsUTF8PercentBytes() throws {
        let parameters = DicomWebSearchParameters(level: .study,
            matches: [.init("PatientName", vr: .PN, values: ["José*"]),
                      .init("StudyDescription", vr: .LO, values: ["Crânio, ção"]),
                      .init("StudyInstanceUID", vr: .UI, values: ["1.2", "1.3"])])
        let url = try parameters.url(relativeTo: URL(string: "http://127.0.0.1:8042/dicom-web")!)
        let query = try XCTUnwrap(url.query(percentEncoded: true))
        XCTAssertTrue(query.contains("PatientName=Jos%C3%A9*"), query)
        XCTAssertTrue(query.contains("StudyDescription=Cr%C3%A2nio%2C%20%C3%A7%C3%A3o"), query)
        XCTAssertTrue(query.contains("StudyInstanceUID=1.2,1.3"), query)
        XCTAssertTrue(query.unicodeScalars.allSatisfy(\.isASCII), query)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "PatientName" }?.value, "José*")
    }

    func test_invalidParameters_rejectDuplicateMatchNegativePagingAndAllMix() throws {
        for items in [
            [URLQueryItem(name: "limit", value: "-1")],
            [.init(name: "PatientID", value: "a"), .init(name: "PatientID", value: "b")],
            [.init(name: "includefield", value: "all"), .init(name: "includefield", value: "PatientID")],
            [.init(name: "fuzzymatching", value: "yes")]
        ] {
            XCTAssertThrowsError(try DicomWebSearchParameters.parse(queryItems: items, vrForAttribute: { _ in .LO }))
        }
        XCTAssertThrowsError(try DicomWebSearchParameters(matches: [.init("ModalitiesInStudy", vr: .CS, values: ["CT", ""])]).queryItems())
    }

    /// The "," between the values of one key is the QIDO-RS separator and stays literal for every VR; dcm4chee reads
    /// "%2C" as part of a single value. A "," inside a value is data and stays encoded.
    func test_multipleValues_keepLiteralCommaSeparatorAndEncodeCommaInsideValue() throws {
        let parameters = DicomWebSearchParameters(level: .study,
            matches: [.init("ModalitiesInStudy", vr: .CS, values: ["CT", "MR"]),
                      .init("StudyInstanceUID", vr: .UI, values: ["1.2.3", "1.2.4"]),
                      .init("StudyDescription", vr: .LO, values: ["Head, neck"]),
                      .init("ReferringPhysicianName", vr: .PN, values: ["A,B", "C"])],
            includeFields: ["PatientAge", "00081030"])
        let url = try parameters.url(relativeTo: URL(string: "http://127.0.0.1:8080/dcm4chee-arc/aets/DCM4CHEE/rs")!)
        let query = try XCTUnwrap(url.query(percentEncoded: true))
        XCTAssertEqual(query, "ModalitiesInStudy=CT,MR&StudyInstanceUID=1.2.3,1.2.4&StudyDescription=Head%2C%20neck"
                       + "&ReferringPhysicianName=A%2CB,C&includefield=PatientAge,00081030")
        XCTAssertEqual(try parameters.queryItems().first?.value, "CT,MR")
    }
}
