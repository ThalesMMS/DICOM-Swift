//
//  DicomPrivateDataTests.swift
//  DicomCoreTests
//
//  Checks discovery of Siemens CSA private elements after a DICOM round trip.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DicomPrivateDataTests: XCTestCase {
    private let sopClassUIDTag = 0x00080016
    private let unknownCreatorTag = 0x00190010
    private let unknownPrivateTag = 0x00191001
    private let csaCreatorTag = 0x00290010
    private let csaImageHeaderTag = 0x00291010

    func testPrivateCreatorNamespacesUnknownPrivateElements() {
        let dataSet = makeBaseDataSet(extraElements: [
            DicomDataElement(tag: unknownCreatorTag, vr: .LO, value: .strings(["ACME_PRIVATE"])),
            DicomDataElement(tag: unknownPrivateTag, vr: .LO, value: .strings(["private-value"]))
        ])

        XCTAssertEqual(dataSet.privateCreators, [
            DicomPrivateCreator(group: 0x0019, element: 0x0010, identifier: "ACME_PRIVATE")
        ])

        let privateElements = dataSet.privateElements(forCreator: "ACME_PRIVATE", group: 0x0019)
        XCTAssertEqual(privateElements.count, 1)
        XCTAssertEqual(privateElements.first?.privateElement, 0x01)
        XCTAssertEqual(privateElements.first?.element.stringValue, "private-value")
        XCTAssertEqual(
            dataSet.privateElement(group: 0x0019, creator: "ACME_PRIVATE", privateElement: 0x01)?.stringValue,
            "private-value"
        )
    }

    func testPrivateCreatorElementsSurvivePart10RoundTrip() throws {
        let dataSet = makeBaseDataSet(extraElements: [
            DicomDataElement(tag: unknownCreatorTag, vr: .LO, value: .strings(["ACME_PRIVATE"])),
            DicomDataElement(tag: unknownPrivateTag, vr: .LO, value: .strings(["round-trip"]))
        ])

        let decoded = try writeAndOpen(dataSet).dataSet

        XCTAssertEqual(decoded.privateCreators.first?.identifier, "ACME_PRIVATE")
        XCTAssertEqual(
            decoded.privateElement(group: 0x0019, creator: "ACME_PRIVATE", privateElement: 0x01)?.stringValue,
            "round-trip"
        )
    }

    func testSiemensCSAParserReadsClinicalValues() throws {
        let data = makeCSAData(tags: [
            CSATestTag(name: "B_value", vr: "IS", values: ["800"]),
            CSATestTag(name: "DiffusionGradientDirection", vr: "DS", values: ["0.1\\0.2\\0.3"]),
            CSATestTag(name: "ImageOrientationPatient", vr: "DS", values: ["1\\0\\0\\0\\1\\0"])
        ])

        let header = try XCTUnwrap(SiemensCSAParser.parse(data))

        XCTAssertEqual(header["B_value"]?.values, ["800"])
        XCTAssertEqual(header.bValue, 800)
        assertEqual(header.diffusionGradientDirection ?? [], [0.1, 0.2, 0.3], accuracy: 0.0001)
        assertEqual(header.imageOrientationPatient ?? [], [1, 0, 0, 0, 1, 0], accuracy: 0.0001)
    }

    func testSiemensCSAElementIsDiscoverableAfterRoundTrip() throws {
        let csaData = makeCSAData(tags: [
            CSATestTag(name: "B_value", vr: "IS", values: ["1200"]),
            CSATestTag(name: "DiffusionGradientDirection", vr: "DS", values: ["0\\1\\0"])
        ])
        let dataSet = makeBaseDataSet(extraElements: [
            DicomDataElement(tag: csaCreatorTag, vr: .LO, value: .strings(["SIEMENS CSA HEADER"])),
            DicomDataElement(tag: csaImageHeaderTag, vr: .OB, value: .bytes(csaData))
        ])

        let decoded = try writeAndOpen(dataSet).dataSet
        let element = try XCTUnwrap(decoded.element(for: csaImageHeaderTag))
        let entry = try XCTUnwrap(decoded.privateDictionaryEntry(for: element))
        let header = try XCTUnwrap(decoded.siemensCSAHeader(for: csaImageHeaderTag))

        XCTAssertEqual(entry.name, "CSA Image Header Info")
        XCTAssertEqual(entry.parser, .siemensCSA)
        XCTAssertEqual(header.bValue, 1200)
        assertEqual(header.diffusionGradientDirection ?? [], [0, 1, 0], accuracy: 0.0001)
        XCTAssertEqual(decoded.siemensCSAHeaders[csaImageHeaderTag]?.bValue, 1200)
    }

    private func assertEqual(_ actual: [Double],
                             _ expected: [Double],
                             accuracy: Double,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(actualValue, expectedValue, accuracy: accuracy, file: file, line: line)
        }
    }

    private func writeAndOpen(_ dataSet: DicomDataSet) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func makeBaseDataSet(extraElements: [DicomDataElement]) -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(tag: sopClassUIDTag,
                             vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["2.25.2181"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["2.25.2182"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["2.25.2183"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue,
                             vr: .PN,
                             value: .strings(["Private^Fixture"])),
            DicomDataElement(tag: DicomTag.modality.rawValue,
                             vr: .CS,
                             value: .strings(["MR"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue,
                             vr: .CS,
                             value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.rows.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.columns.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.highBit.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([15])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue,
                             vr: .US,
                             value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue,
                             vr: .OW,
                             value: .bytes(Data([0x01, 0x00])))
        ] + extraElements)
    }

    private struct CSATestTag {
        let name: String
        let vr: String
        let values: [String]
    }

    private func makeCSAData(tags: [CSATestTag]) -> Data {
        var data = Data("SV10".utf8)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        appendUInt32(UInt32(tags.count), to: &data)
        appendUInt32(77, to: &data)

        for tag in tags {
            appendPaddedString(tag.name, length: 64, to: &data)
            appendUInt32(UInt32(tag.values.count), to: &data)
            appendPaddedString(tag.vr, length: 4, to: &data)
            appendUInt32(0, to: &data)
            appendUInt32(UInt32(tag.values.count), to: &data)
            appendUInt32(77, to: &data)

            for value in tag.values {
                var valueData = Data(value.utf8)
                valueData.append(0x00)
                appendUInt32(UInt32(valueData.count), to: &data)
                appendUInt32(0, to: &data)
                appendUInt32(0, to: &data)
                appendUInt32(0, to: &data)
                data.append(valueData)
                while data.count % 4 != 0 {
                    data.append(0x00)
                }
            }
        }
        return data
    }

    private func appendPaddedString(_ value: String, length: Int, to data: inout Data) {
        var bytes = Array(value.utf8.prefix(length))
        if bytes.count < length {
            bytes.append(contentsOf: Array(repeating: 0x00, count: length - bytes.count))
        }
        data.append(contentsOf: bytes)
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0x000000FF))
        data.append(UInt8((value >> 8) & 0x000000FF))
        data.append(UInt8((value >> 16) & 0x000000FF))
        data.append(UInt8(value >> 24))
    }
}
