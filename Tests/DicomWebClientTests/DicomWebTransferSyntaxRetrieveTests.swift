import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

/// Retrieves that ask for a transfer syntax, or for the objects as stored, and refuse parts in another one (#2891).
final class DicomWebTransferSyntaxRetrieveTests: XCTestCase {
    private static let implicitVRLittleEndian = "1.2.840.10008.1.2"
    private static let explicitVRLittleEndian = "1.2.840.10008.1.2.1"

    func test_instanceAccept_asStoredOrValidatedUID() throws {
        for asStored in [nil, "", " * "] {
            XCTAssertEqual(try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUID: asStored).parameters["transfer-syntax"], "*")
        }
        let implicit = try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUID: Self.implicitVRLittleEndian)
        XCTAssertEqual(implicit.type, "multipart/related")
        XCTAssertEqual(implicit.parameters["type"], "application/dicom")
        XCTAssertEqual(implicit.parameters["transfer-syntax"], Self.implicitVRLittleEndian)
        for invalid in ["1.2.840.10008.1.2.a", "1..2", "1.02", "1.2.", "1", "1.2.840; boundary=x"] {
            XCTAssertThrowsError(try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUID: invalid), invalid) {
                XCTAssertEqual(($0 as? DicomWebError)?.kind, .badRequest)
            }
        }
    }

    func test_checkingSink_passesTheRequestedSyntaxAndRefusesAnother() async throws {
        let file = try Self.part10(sopInstanceUID: "2.25.28910001", transferSyntax: .explicitVRLittleEndian)
        for chunk in [1, 7, 131, 4096] {
            let memory = DicomWebMemoryRetrieveSink()
            let sink = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: Self.explicitVRLittleEndian, wrapping: memory)
            try await Self.deliver(file, headers: ["Content-Type": "application/dicom"], to: sink, chunk: chunk)
            let parts = await memory.result()
            XCTAssertEqual(parts.first?.body, file, "chunk \(chunk)")

            let refusing = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: Self.implicitVRLittleEndian,
                                                              wrapping: DicomWebMemoryRetrieveSink())
            do {
                try await Self.deliver(file, headers: ["Content-Type": "application/dicom"], to: refusing, chunk: chunk)
                XCTFail("a part in Explicit VR Little Endian passed a check for Implicit VR Little Endian")
            } catch let error as DicomWebTransferSyntaxMismatch {
                XCTAssertEqual(error.receivedTransferSyntaxUID, Self.explicitVRLittleEndian)
                XCTAssertEqual(error.errorDescription, "The server sent a part in transfer syntax 1.2.840.10008.1.2.1 "
                    + "instead of the requested 1.2.840.10008.1.2.")
            }
        }
    }

    func test_checkingSink_readsTheContentTypeParameterAndRefusesPartsWithoutFileMeta() async throws {
        let declared = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: Self.implicitVRLittleEndian,
                                                          wrapping: DicomWebMemoryRetrieveSink())
        do {
            try await declared.receive(.partHeaders(
                ["content-type": "application/dicom; transfer-syntax=\(Self.explicitVRLittleEndian)"], isRoot: true))
            XCTFail("a declared syntax other than the requested one passed")
        } catch let error as DicomWebTransferSyntaxMismatch {
            XCTAssertEqual(error.receivedTransferSyntaxUID, Self.explicitVRLittleEndian)
        }

        let bare = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: Self.explicitVRLittleEndian,
                                                      wrapping: DicomWebMemoryRetrieveSink())
        do {
            try await Self.deliver(Data(repeating: 0x41, count: 300), headers: ["Content-Type": "application/dicom"],
                                   to: bare, chunk: 64)
            XCTFail("a part without File Meta Information passed")
        } catch let error as DicomWebTransferSyntaxMismatch {
            XCTAssertNil(error.receivedTransferSyntaxUID)
        }
    }

    func test_checkingSink_checksFileMetaEvenWithMatchingOrWildcardHeader() async throws {
        let file = try Self.part10(sopInstanceUID: "2.25.29120001", transferSyntax: .explicitVRLittleEndian)
        for header in ["application/dicom", "application/dicom; transfer-syntax=*",
                       "application/dicom; transfer-syntax=\(Self.implicitVRLittleEndian)"] {
            for chunk in [1, 7, 131, 4096] {
                let sink = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: Self.implicitVRLittleEndian,
                    wrapping: DicomWebMemoryRetrieveSink())
                do {
                    try await Self.deliver(file, headers: ["Content-Type": header], to: sink, chunk: chunk)
                    XCTFail("Contradictory File Meta passed with \(header), chunk \(chunk)")
                } catch let error as DicomWebTransferSyntaxMismatch {
                    XCTAssertEqual(error.receivedTransferSyntaxUID, Self.explicitVRLittleEndian)
                }
            }
        }
        for payload in [Data(), Data(repeating: 0x41, count: 300), Data(file.prefix(150))] {
            let sink = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: Self.explicitVRLittleEndian,
                wrapping: DicomWebMemoryRetrieveSink())
            do {
                try await Self.deliver(payload,
                    headers: ["Content-Type": "application/dicom; transfer-syntax=\(Self.explicitVRLittleEndian)"],
                    to: sink, chunk: 7)
                XCTFail("Matching header bypassed absent/truncated File Meta")
            } catch let error as DicomWebTransferSyntaxMismatch {
                XCTAssertNil(error.receivedTransferSyntaxUID)
            }
        }
    }

    func test_checkingSink_matchingFileMetaAllowsMissingWildcardAndConcreteHeader() async throws {
        let file = try Self.part10(sopInstanceUID: "2.25.29120003", transferSyntax: .explicitVRLittleEndian)
        for header in ["application/dicom", "application/dicom; transfer-syntax=*",
                       "application/dicom; transfer-syntax=\(Self.explicitVRLittleEndian)"] {
            let memory = DicomWebMemoryRetrieveSink()
            let sink = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: Self.explicitVRLittleEndian, wrapping: memory)
            try await Self.deliver(file, headers: ["Content-Type": header], to: sink, chunk: 1)
            let parts = await memory.result()
            XCTAssertEqual(parts.first?.body, file)
        }
        let invalid = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: "*", wrapping: DicomWebMemoryRetrieveSink())
        do {
            try await invalid.receive(.partHeaders(["Content-Type": "application/dicom; transfer-syntax=not-a-uid"], isRoot: true))
            XCTFail("Malformed declared UID passed")
        } catch let error as DicomWebTransferSyntaxMismatch {
            XCTAssertEqual(error.receivedTransferSyntaxUID, "not-a-uid")
        }
        let contradictory = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: "*", wrapping: DicomWebMemoryRetrieveSink())
        do {
            try await Self.deliver(file, headers: ["Content-Type": "application/dicom; transfer-syntax=\(Self.implicitVRLittleEndian)"],
                                   to: contradictory, chunk: 7)
            XCTFail("As-stored allowed a concrete response header to mislabel the bytes")
        } catch let error as DicomWebTransferSyntaxMismatch {
            XCTAssertEqual(error.expectedTransferSyntaxUID, Self.implicitVRLittleEndian)
            XCTAssertEqual(error.receivedTransferSyntaxUID, Self.explicitVRLittleEndian)
        }
    }

    func test_checkingSink_asStoredAcceptsAnyConcreteFileMetaSyntax() async throws {
        for syntax in [DicomTransferSyntax.implicitVRLittleEndian, .explicitVRLittleEndian] {
            let file = try Self.part10(sopInstanceUID: "2.25.29120002", transferSyntax: syntax)
            for header in ["application/dicom", "application/dicom; transfer-syntax=*",
                           "application/dicom; transfer-syntax=\(syntax.rawValue)"] {
                let memory = DicomWebMemoryRetrieveSink()
                let sink = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: "*", wrapping: memory)
                try await Self.deliver(file, headers: ["Content-Type": header], to: sink, chunk: 7)
                let parts = await memory.result()
                XCTAssertEqual(parts.first?.body, file)
            }
        }
    }

    func test_fileSink_remainsGenericForRenderedAndBulkData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = try DicomWebFileRetrieveSink(directory: directory)
        for contentType in ["image/jpeg", "application/octet-stream"] {
            try await Self.deliver(Data([1, 2, 3]), headers: ["Content-Type": contentType], to: sink, chunk: 1)
        }
        let parts = await sink.result()
        XCTAssertEqual(parts.count, 2)
        for part in parts { XCTAssertEqual(try Data(contentsOf: part.url), Data([1, 2, 3])) }
    }

    /// Against a local Orthanc (`DICOMWEB_ORTHANC_URL`, e.g. http://127.0.0.1:8042): a synthetic instance stored in
    /// Explicit VR Little Endian arrives as stored, and transcoded when Implicit VR Little Endian is asked for.
    func test_orthancRetrieve_asStoredAndImplicitVRLittleEndian() async throws {
        guard let orthanc = ProcessInfo.processInfo.environment["DICOMWEB_ORTHANC_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Set DICOMWEB_ORTHANC_URL to run against a local Orthanc")
        }
        let study = "2.25.2891\(UInt32.random(in: 1...UInt32.max))"
        let series = study + ".1", instance = study + ".1.1"
        let client = DicomWebClient(configuration: .init(baseURL: orthanc.appendingPathComponent("dicom-web")))
        _ = try await client.storeInstances(dataSets: [Self.dataSet(sopInstanceUID: instance, study: study, series: series)])
        defer { Self.deleteFromOrthanc(orthanc, study: study) }

        for (requested, expected) in [(nil as String?, Self.explicitVRLittleEndian),
                                      (Self.implicitVRLittleEndian, Self.implicitVRLittleEndian)] {
            let memory = DicomWebMemoryRetrieveSink()
            let sink = DicomWebTransferSyntaxCheckingSink(expectedTransferSyntaxUID: expected, wrapping: memory)
            let status = try await client.retrieveInstance(
                studyInstanceUID: study, seriesInstanceUID: series, sopInstanceUID: instance,
                accept: DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUID: requested), sink: sink)
            XCTAssertEqual(status, 200)
            let parts = await memory.result()
            XCTAssertEqual(parts.count, 1)
            XCTAssertEqual(try DicomPart10FileMetaParser.parse(try XCTUnwrap(parts.first?.body)).transferSyntaxUID, expected)
        }
    }

    private static func deliver(_ payload: Data, headers: [String: String], to sink: any DicomWebRetrieveSink,
                                chunk: Int) async throws {
        try await sink.receive(.partHeaders(headers, isRoot: true))
        for offset in stride(from: 0, to: payload.count, by: chunk) {
            try await sink.receive(.payload(payload.subdata(in: offset..<min(payload.count, offset + chunk))))
        }
        try await sink.receive(.partEnd)
    }

    private static func part10(sopInstanceUID: String, transferSyntax: DicomTransferSyntax) throws -> Data {
        try DicomDataSetWriter.part10Data(from: dataSet(sopInstanceUID: sopInstanceUID),
                                          options: .init(transferSyntax: transferSyntax))
    }

    private static func dataSet(sopInstanceUID: String, study: String = "2.25.28910002",
                                series: String = "2.25.28910003") -> DicomDataSet {
        DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([sopInstanceUID])),
            .init(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings([study])),
            .init(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings([series])),
            .init(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["ISIS2891"])),
            .init(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([4])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([4])),
            .init(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            .init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data((0..<16).map { UInt8($0 * 16) })))
        ])
    }

    /// Orthanc's REST API removes the synthetic study; DICOMweb has no delete.
    private static func deleteFromOrthanc(_ orthanc: URL, study: String) {
        let semaphore = DispatchSemaphore(value: 0)
        var find = URLRequest(url: orthanc.appendingPathComponent("tools/find"))
        find.httpMethod = "POST"
        find.httpBody = Data(#"{"Level":"Study","Query":{"StudyInstanceUID":"\#(study)"}}"#.utf8)
        URLSession.shared.dataTask(with: find) { data, _, _ in
            let ids = data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let group = DispatchGroup()
            for id in ids {
                var delete = URLRequest(url: orthanc.appendingPathComponent("studies/\(id)"))
                delete.httpMethod = "DELETE"
                group.enter()
                URLSession.shared.dataTask(with: delete) { _, _, _ in group.leave() }.resume()
            }
            group.notify(queue: .global()) { semaphore.signal() }
        }.resume()
        semaphore.wait()
    }
}
