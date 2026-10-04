import Foundation
import XCTest
@testable import DicomCore

final class DicomWebLargeRetrieveTests: XCTestCase {
    /// A study retrieve larger than 1 GiB streams every part and the closing boundary. The body is counted chunk by
    /// chunk and never kept, and the storage builds each instance only when the response asks for it.
    func test_studyRetrieveAboveOneGibibyte_streamsEveryPartAndTheClosingBoundary() async throws {
        let storage = DicomWebGeneratedStudyStorage(instanceCount: 65)
        let server = DicomWebServer(configuration: DicomWebServerConfiguration(cacheEnabled: false), storage: storage)
        let url = URL(string: "https://server.example/dicom-web/studies/\(DicomWebGeneratedStudyStorage.study)")!
        let response = try await server.stream(.init(method: .get, url: url,
            headers: ["Accept": "multipart/related; type=\"application/dicom\"; transfer-syntax=*"]))
        XCTAssertEqual(response.statusCode, 200)
        let contentType = try XCTUnwrap(response.headers["Content-Type"])
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
        let partStart = Data("--\(boundary)\r\n".utf8)
        let closing = Data("\r\n--\(boundary)--\r\n".utf8)

        var bytes = 0
        var parts = 0
        var tail = Data()
        for try await chunk in response.body {
            bytes += chunk.count
            if chunk.starts(with: partStart) { parts += 1 }
            tail = Data((tail + chunk).suffix(closing.count))
        }

        XCTAssertEqual(parts, 65)
        XCTAssertGreaterThan(bytes, 1 << 30)
        XCTAssertEqual(tail, closing)
    }
}

/// One study whose instances each carry 16 MiB of Pixel Data, made on request so the test holds one at a time.
private struct DicomWebGeneratedStudyStorage: DicomWebStorageProviding {
    static let study = "2.25.29790001"
    static let series = "2.25.29790002"
    private static let rows = 2048, columns = 4096
    private static let pixels = Data(count: rows * columns * 2)
    let instanceCount: Int

    func searchStudies(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] { [] }
    func searchSeries(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] { [] }
    func searchInstances(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] { [] }
    func metadata(study: String, series: String?, instance: String?) async throws -> [DicomDataSet] {
        guard study == Self.study else { return [] }
        return (1...instanceCount).map { Self.dataSet(sop: Self.sop($0), pixels: nil) }
            .filter { instance == nil || $0.string(for: .sopInstanceUID) == instance }
    }
    func instance(study: String, series: String, instance: String) async throws -> DicomWebStoredInstance {
        let dataSet = Self.dataSet(sop: instance, pixels: Self.pixels)
        let part10 = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
            mediaStorageSOPInstanceUID: instance))
        return .init(dataSet: dataSet, part10Data: part10, studyInstanceUID: study, seriesInstanceUID: series,
                     sopInstanceUID: instance, sopClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID)
    }
    func bulkData(uri: String) async throws -> Data { throw DicomWebServerFailure(404, "Bulk data not found.") }
    func store(instances: [DicomWebStoredInstance]) async throws -> [DicomWebStorageResult] { [] }

    private static func sop(_ number: Int) -> String { "2.25.2979\(number + 1000)" }

    private static func dataSet(sop: String, pixels: Data?) -> DicomDataSet {
        func string(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement {
            .init(tag: tag.rawValue, vr: vr, value: .strings([value]))
        }
        func short(_ tag: DicomTag, _ value: UInt) -> DicomDataElement {
            .init(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value]))
        }
        var elements = [
            string(.sopClassUID, .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, .UI, sop), string(.studyInstanceUID, .UI, study),
            string(.seriesInstanceUID, .UI, series), string(.modality, .CS, "OT"),
            short(.samplesPerPixel, 1), string(.photometricInterpretation, .CS, "MONOCHROME2"),
            short(.rows, UInt(rows)), short(.columns, UInt(columns)), short(.bitsAllocated, 16),
            short(.bitsStored, 16), short(.highBit, 15), short(.pixelRepresentation, 0)
        ]
        if let pixels { elements.append(.init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixels))) }
        return DicomDataSet(elements: elements)
    }
}
