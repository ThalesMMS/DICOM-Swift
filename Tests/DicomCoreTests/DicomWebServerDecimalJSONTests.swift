import DicomData
import DicomWebClient
import Foundation
import XCTest
@testable import DicomCore

/// PS3.18 F.2.3 writes DS and IS as JSON numbers. The server does so when a reader gets the same text back, keeps
/// the stored text when asked to, and the package's client reads either form into the same values.
final class DicomWebServerDecimalJSONTests: XCTestCase {
    private static let decimals: [(tag: Int, vr: DicomVR, values: [String])] = [
        (0x00280030, .DS, ["0.5", "0.25"]),
        (0x00180050, .DS, ["2.50"]),
        (0x00200032, .DS, ["-125", "1.0", "1e-3"]),
        (0x00281050, .DS, ["40"]),
        (0x00200013, .IS, ["7"]),
        (0x00201002, .IS, ["007"])
    ]

    func test_dsAndIS_areNumbersWhenExact_andTheClientReadsBothForms() async throws {
        let numbers = try await serve(.numbersWhenExact)
        XCTAssertEqual(numbers.wire["00280030"] as NSArray?, [0.5, 0.25])
        XCTAssertEqual(numbers.wire["00180050"] as NSArray?, ["2.50"])
        XCTAssertEqual(numbers.wire["00200032"] as NSArray?, [-125, "1.0", "1e-3"])
        XCTAssertEqual(numbers.wire["00281050"] as NSArray?, [40])
        XCTAssertEqual(numbers.wire["00200013"] as NSArray?, [7])
        XCTAssertEqual(numbers.wire["00201002"] as NSArray?, ["007"])
        let text = try await serve(.preserveText)
        for (tag, _, values) in Self.decimals {
            let key = String(format: "%08X", tag)
            XCTAssertEqual(text.wire[key] as? [String], values, key)
            for read in [numbers.search, numbers.metadata, text.search, text.metadata] {
                XCTAssertEqual(read[tag], values, key)
            }
        }
    }

    /// The raw JSON Value arrays of a QIDO response, and the values the client read from QIDO and from metadata.
    private func serve(_ policy: DicomDataSetRepresentation.DecimalPolicy) async throws
        -> (wire: [String: [Any]], search: [Int: [String]], metadata: [Int: [String]]) {
        let store = DicomWebInMemoryStore()
        try store.add(dataSet: DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.3"])),
            .init(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.1"])),
            .init(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.2"])),
            .init(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"]))
        ] + Self.decimals.map { .init(tag: $0.tag, vr: $0.vr, value: .strings($0.values)) }))
        var configuration = DicomWebServerConfiguration(cacheEnabled: false)
        configuration.jsonDecimals = policy
        let client = DicomWebClient(configuration: .init(baseURL: URL(string: "https://server.example/dicom-web")!),
                                    transport: DicomWebServer(configuration: configuration, store: store))
        let parameters = DicomWebSearchParameters(level: .instance, studyInstanceUID: "2.25.1",
                                                  includeFields: Self.decimals.map { String(format: "%08X", $0.tag) })
        let response = try await client.searchResponse(parameters: parameters)
        let object = try XCTUnwrap((try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]])?.first)
        let wire = object.compactMapValues { ($0 as? [String: Any])?["Value"] as? [Any] }
        let page = try await client.search(parameters: parameters)
        let metadata = try await client.retrieveStudyMetadata(studyInstanceUID: "2.25.1")
        func values(_ dataSet: DicomDataSet?) -> [Int: [String]] {
            Dictionary(uniqueKeysWithValues: Self.decimals.compactMap { entry in
                guard case .strings(let texts)? = dataSet?[entry.tag]?.value else { return nil }
                return (entry.tag, texts)
            })
        }
        return (wire, values(page.dataSets.first), values(metadata.first?.dataSet))
    }
}
