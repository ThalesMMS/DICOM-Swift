import XCTest
@testable import DicomCore

final class DicomDeflatedDataSetCodecTests: XCTestCase {
    func test_groupLength_stopsBeforeDeflateBytesThatResembleFileMeta() throws {
        let dataSet = makeBaseDataSet(pixelBytes: Data([0x34, 0x12]))
        let encoded = try DicomDataSetWriter.dataSetData(from: dataSet)
        let deflated = try DicomDeflatedDataSetCodec.deflate(encoded)
        let part10 = try DicomDataSetWriter.part10Data(
            from: dataSet, options: .init(transferSyntax: .deflatedExplicitVRLittleEndian)
        )
        let meta = part10.prefix(part10.count - deflated.count)
        // Empty fixed and stored non-final blocks; the prefix also looks like group 0002.
        let payload = Data([0x02, 0x00, 0x00, 0x00, 0xFF, 0xFF]) + deflated
        XCTAssertEqual(try DicomDeflatedDataSetCodec.inflate(payload), encoded)
        XCTAssertEqual(try DicomDeflatedDataSetCodec.inflatedPart10DataIfNeeded(meta + payload), meta + encoded)
    }

    func test_groupLength_rejectsTruncatedOrOutOfBoundsFileMeta() throws {
        let original = try DicomDataSetWriter.part10Data(
            from: makeBaseDataSet(pixelBytes: Data([0x34, 0x12])),
            options: .init(transferSyntax: .deflatedExplicitVRLittleEndian)
        )
        for length: UInt32 in [1, .max] {
            var data = original
            var encodedLength = length.littleEndian
            data.replaceSubrange(140..<144, with: withUnsafeBytes(of: &encodedLength) { Data($0) })
            XCTAssertThrowsError(try DicomDeflatedDataSetCodec.inflatedPart10DataIfNeeded(data)) {
                XCTAssertEqual($0 as? DicomDeflatedDataSetError, .malformedFileMetaInformation)
            }
        }
    }

    private let sopClassUIDTag = 0x00080016
    private let procedureCodeSequenceTag = 0x00081032
    private let codeValueTag = 0x00080100
    private let codeMeaningTag = 0x00080104

    func testDeflatedExplicitVRRoundTripsMetadataSequencesAndNativePixels() throws {
        let dataSet = makeBaseDataSet(pixelBytes: Data([0x34, 0x12])).setting(
            DicomDataElement(
                tag: procedureCodeSequenceTag,
                vr: .SQ,
                value: .sequence([
                    DicomSequenceItem(dataSet: DicomDataSet(elements: [
                        DicomDataElement(tag: codeValueTag, vr: .SH, value: .strings(["CHEST"])),
                        DicomDataElement(tag: codeMeaningTag, vr: .LO, value: .strings(["Chest study"]))
                    ]))
                ])
            )
        )
        let encoded = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(transferSyntax: .deflatedExplicitVRLittleEndian)
        )

        XCTAssertNotNil(encoded.range(of: Data(DicomTransferSyntax.deflatedExplicitVRLittleEndian.rawValue.utf8)))
        XCTAssertNil(encoded.range(of: Data("MONOCHROME2".utf8)))

        let decoder = try open(encoded)

        XCTAssertTrue(DicomTransferSyntax.deflatedExplicitVRLittleEndian.matches(decoder.info(for: .transferSyntaxUID)))
        XCTAssertFalse(decoder.compressedImage)
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.familyName, "Doe")
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.givenName, "Jane")
        XCTAssertEqual(decoder.dataSet.string(for: .modality), "CT")
        XCTAssertEqual(decoder.dataSet.element(for: procedureCodeSequenceTag)?.vr, .SQ)
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), [0x1234])
    }

    func testInflateRejectsCorruptPayloadWithSpecificError() {
        XCTAssertThrowsError(try DicomDeflatedDataSetCodec.inflate(Data([0xFF, 0xFF, 0xFF]))) { error in
            guard case DicomDeflatedDataSetError.inflateFailed = error else {
                return XCTFail("Expected inflateFailed, got \(error)")
            }
        }
    }

    func testPart10LoaderSurfacesCorruptDeflatedPayloadError() throws {
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)
        appendExplicitVRTag(
            to: &data,
            group: 0x0002,
            element: 0x0010,
            vr: "UI",
            value: Data(DicomTransferSyntax.deflatedExplicitVRLittleEndian.rawValue.utf8),
            paddingByte: 0x00
        )
        data.append(contentsOf: [0xFF, 0xFF, 0xFF])

        let url = temporaryDICOMURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        XCTAssertThrowsError(try DCMDecoder(contentsOf: url)) { error in
            guard case DicomDeflatedDataSetError.inflateFailed = error else {
                return XCTFail("Expected inflateFailed, got \(error)")
            }
        }
    }

    private func open(_ data: Data) throws -> DCMDecoder {
        let url = temporaryDICOMURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return try DCMDecoder(contentsOf: url)
    }

    private func makeBaseDataSet(pixelBytes: Data) -> DicomDataSet {
        DicomDataSet(elements: [
            DicomDataElement(tag: sopClassUIDTag,
                             vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["2.25.123456789"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["2.25.123456790"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue,
                             vr: .UI,
                             value: .strings(["2.25.123456791"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue,
                             vr: .PN,
                             value: .strings(["Doe^Jane"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue,
                             vr: .LO,
                             value: .strings(["P-1"])),
            DicomDataElement(tag: DicomTag.modality.rawValue,
                             vr: .CS,
                             value: .strings(["CT"])),
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
                             value: .bytes(pixelBytes))
        ])
    }

    private func temporaryDICOMURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dcm")
    }

    private func appendExplicitVRTag(
        to data: inout Data,
        group: UInt16,
        element: UInt16,
        vr: String,
        value: Data,
        paddingByte: UInt8 = 0x20
    ) {
        appendUInt16(group, to: &data)
        appendUInt16(element, to: &data)
        data.append(contentsOf: vr.utf8)

        let paddedLength = value.count + (value.count % 2)
        let longVRs = ["OB", "OW", "SQ", "UN", "UR", "UT"]
        if longVRs.contains(vr) {
            data.append(contentsOf: [0x00, 0x00])
            appendUInt32(UInt32(paddedLength), to: &data)
        } else {
            appendUInt16(UInt16(paddedLength), to: &data)
        }

        data.append(value)
        if value.count % 2 != 0 {
            data.append(paddingByte)
        }
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}
