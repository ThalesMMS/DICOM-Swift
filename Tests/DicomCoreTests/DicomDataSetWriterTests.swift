import XCTest
@testable import DicomCore

final class DicomDataSetWriterTests: XCTestCase {
    private let sopClassUIDTag = 0x00080016
    private let procedureCodeSequenceTag = 0x00081032
    private let codeValueTag = 0x00080100
    private let codeMeaningTag = 0x00080104
    private let privateTag = 0x00111010

    func testWriterAppliesDatasetEditsAndReopensPart10File() throws {
        var dataSet = makeBaseDataSet(pixelBytes: Data([0x2A, 0x00]))
        dataSet.set(DicomDataElement(tag: DicomTag.patientName.rawValue,
                                     vr: .PN,
                                     value: .strings(["Roe^Richard"])))
        dataSet.set(DicomDataElement(tag: privateTag, vr: .LO, value: .strings(["remove-me"])))
        dataSet.remove(privateTag)

        let url = temporaryDICOMURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try DicomDataSetWriter.write(dataSet, to: url)

        let decoder = try DCMDecoder(contentsOf: url)
        let decodedDataSet = decoder.dataSet

        XCTAssertTrue(DicomTransferSyntax.explicitVRLittleEndian.matches(decoder.info(for: .transferSyntaxUID)))
        XCTAssertTrue(decoder.isExplicitVRTransferSyntax)
        XCTAssertEqual(decodedDataSet.personName(for: .patientName)?.familyName, "Roe")
        XCTAssertEqual(decodedDataSet.personName(for: .patientName)?.givenName, "Richard")
        XCTAssertEqual(decodedDataSet.string(for: .modality), "CT")
        XCTAssertEqual(decodedDataSet.string(for: .sopInstanceUID), "2.25.123456789")
        XCTAssertEqual(decodedDataSet.string(for: .studyInstanceUID), "2.25.123456790")
        XCTAssertEqual(decodedDataSet.string(for: .seriesInstanceUID), "2.25.123456791")
        XCTAssertEqual(decodedDataSet.int(for: .rows), 1)
        XCTAssertEqual(decodedDataSet.int(for: .columns), 1)
        XCTAssertEqual(decodedDataSet.decimalStrings(for: .pixelSpacing), [0.5, 0.75])
        XCTAssertNil(decodedDataSet.element(for: privateTag))
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), [42])
    }

    func testWriterRoundTripsImplicitVRLittleEndian() throws {
        let dataSet = makeBaseDataSet(pixelBytes: Data([0x2B, 0x00]))
        let url = temporaryDICOMURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try DicomDataSetWriter.write(
            dataSet,
            to: url,
            options: DicomPart10WriterOptions(transferSyntax: .implicitVRLittleEndian)
        )

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertTrue(DicomTransferSyntax.implicitVRLittleEndian.matches(decoder.info(for: .transferSyntaxUID)))
        XCTAssertFalse(decoder.isExplicitVRTransferSyntax)
        XCTAssertEqual(decoder.dataSet.personName(for: .patientName)?.familyName, "Doe")
        XCTAssertEqual(decoder.dataSet.string(for: .modality), "CT")
        XCTAssertEqual(decoder.width, 1)
        XCTAssertEqual(decoder.height, 1)
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), [43])
    }

    func test_part10Wrapping_preservesEncodedDataSet() throws {
        let dataSet = makeBaseDataSet(pixelBytes: Data([0x2B, 0x00]))
        let encodedDataSet = try DicomDataSetWriter.dataSetData(
            from: dataSet,
            transferSyntax: .implicitVRLittleEndian
        )

        let part10Data = try DicomDataSetWriter.part10Data(
            fromEncodedDataSet: encodedDataSet,
            transferSyntax: .implicitVRLittleEndian,
            mediaStorageSOPClassUID: try XCTUnwrap(dataSet.string(for: sopClassUIDTag)),
            mediaStorageSOPInstanceUID: try XCTUnwrap(dataSet.string(for: .sopInstanceUID))
        )
        let decoder = try DCMDecoder(data: part10Data)

        XCTAssertEqual(Data(part10Data[128..<132]), Data("DICM".utf8))
        XCTAssertEqual(Data(part10Data.suffix(encodedDataSet.count)), encodedDataSet)
        XCTAssertTrue(DicomTransferSyntax.implicitVRLittleEndian.matches(decoder.info(for: .transferSyntaxUID)))
        XCTAssertEqual(decoder.dataSet.string(for: .sopInstanceUID), "2.25.123456789")
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), [43])
    }

    func test_part10Wrapping_rejectsDeflatedTransferSyntaxForRawBytes() throws {
        XCTAssertThrowsError(try DicomDataSetWriter.part10Data(
            fromEncodedDataSet: Data([0x01, 0x02]),
            transferSyntax: .deflatedExplicitVRLittleEndian,
            mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.7",
            mediaStorageSOPInstanceUID: "2.25.1"
        )) { error in
            guard case .transferSyntaxWriteUnsupported = error as? DicomDataSetWriterError else {
                return XCTFail("Expected unsupported transfer syntax, got \(error)")
            }
        }
    }

    func testWriterRoundTripsLegacyExplicitVRBigEndian() throws {
        let dataSet = makeBaseDataSet(pixelBytes: Data([0x00, 0x2C]))
        let url = temporaryDICOMURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try DicomDataSetWriter.write(
            dataSet,
            to: url,
            options: DicomPart10WriterOptions(transferSyntax: .explicitVRBigEndian)
        )

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertTrue(DicomTransferSyntax.explicitVRBigEndian.matches(decoder.info(for: .transferSyntaxUID)))
        XCTAssertTrue(decoder.isExplicitVRTransferSyntax)
        XCTAssertFalse(decoder.currentLittleEndian())
        XCTAssertEqual(decoder.dataSet.string(for: .modality), "CT")
        XCTAssertEqual(decoder.width, 1)
        XCTAssertEqual(decoder.height, 1)
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), [44])
    }

    func testWriterEncodesDefinedLengthSequences() throws {
        let item = DicomSequenceItem(dataSet: DicomDataSet(elements: [
            DicomDataElement(tag: codeValueTag, vr: .SH, value: .strings(["CHEST"])),
            DicomDataElement(tag: codeMeaningTag, vr: .LO, value: .strings(["Chest study"]))
        ]))
        let dataSet = makeBaseDataSet(pixelBytes: Data([0x2D, 0x00])).setting(
            DicomDataElement(tag: procedureCodeSequenceTag,
                             vr: .SQ,
                             value: .sequence([item]))
        )

        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        let sequenceHeader = Data([0x08, 0x00, 0x32, 0x10, 0x53, 0x51, 0x00, 0x00])
        let sequenceRange = try XCTUnwrap(data.range(of: sequenceHeader))
        let sequenceLength = Int(readUInt32LittleEndian(data, at: sequenceRange.upperBound))
        let itemOffset = sequenceRange.upperBound + 4

        XCTAssertGreaterThan(sequenceLength, 0)
        XCTAssertEqual(Array(data[itemOffset..<(itemOffset + 4)]), [0xFE, 0xFF, 0x00, 0xE0])
        XCTAssertEqual(Int(readUInt32LittleEndian(data, at: itemOffset + 4)) + 8, sequenceLength)
        XCTAssertNotNil(data.range(of: Data([0x08, 0x00, 0x00, 0x01, 0x53, 0x48])))
        XCTAssertNotNil(data.range(of: Data([0x08, 0x00, 0x04, 0x01, 0x4C, 0x4F])))

        let url = temporaryDICOMURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let decoder = try DCMDecoder(contentsOf: url)
        XCTAssertEqual(decoder.dataSet.element(for: procedureCodeSequenceTag)?.vr, .SQ)
    }

    func testWriterRejectsCompressedTransferSyntax() throws {
        XCTAssertThrowsError(
            try DicomDataSetWriter.part10Data(
                from: makeBaseDataSet(pixelBytes: Data([0x2E, 0x00])),
                options: DicomPart10WriterOptions(transferSyntax: .jpegBaseline)
            )
        ) { error in
            guard case let .pixelRecompressionUnsupported(source, destination, reason) =
                    error as? DicomDataSetWriterError else {
                return XCTFail("Expected pixel recompression error, got \(error)")
            }
            XCTAssertEqual(source, "native Pixel Data")
            XCTAssertEqual(destination, DicomTransferSyntax.jpegBaseline.rawValue)
            XCTAssertTrue(reason.contains("does not encode compressed frames"))
        }
    }

    func testWriterSupportsDeflatedExplicitVRLittleEndian() throws {
        let data = try DicomDataSetWriter.part10Data(
            from: makeBaseDataSet(pixelBytes: Data([0x2F, 0x00])),
            options: DicomPart10WriterOptions(transferSyntax: .deflatedExplicitVRLittleEndian)
        )

        XCTAssertNotNil(data.range(of: Data(DicomTransferSyntax.deflatedExplicitVRLittleEndian.rawValue.utf8)))

        let url = temporaryDICOMURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let decoder = try DCMDecoder(contentsOf: url)
        XCTAssertTrue(DicomTransferSyntax.deflatedExplicitVRLittleEndian.matches(decoder.info(for: .transferSyntaxUID)))
        XCTAssertFalse(decoder.compressedImage)
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), [47])
    }

    func testWriterPreservesEncapsulatedPixelDataForCompressedPassThrough() throws {
        let firstFrame = Data([0x91, 0x92])
        let secondFrame = Data([0xA1, 0xA2])
        let dataSet = makeEncapsulatedDataSet(fragments: [firstFrame, secondFrame])
        let url = temporaryDICOMURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try DicomDataSetWriter.write(
            dataSet,
            to: url,
            options: DicomPart10WriterOptions(transferSyntax: .jpegBaseline)
        )

        let decoder = try DCMDecoder(contentsOf: url)
        let descriptor = try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor)
        let frame = try XCTUnwrap(decoder.getEncapsulatedFrame(1))

        XCTAssertTrue(DicomTransferSyntax.jpegBaseline.matches(decoder.info(for: .transferSyntaxUID)))
        XCTAssertTrue(decoder.compressedImage)
        XCTAssertEqual(decoder.dataSet.string(for: .sopInstanceUID), "2.25.123456789")
        XCTAssertEqual(descriptor.frameFragmentIndexes, [[0], [1]])
        XCTAssertEqual(frame.data, secondFrame)
    }

    func testWriterRejectsEncapsulatedPixelDataWhenWritingNativeSyntax() throws {
        XCTAssertThrowsError(
            try DicomDataSetWriter.part10Data(from: makeEncapsulatedDataSet(fragments: [Data([0x01])]))
        ) { error in
            guard case let .pixelRecompressionUnsupported(source, destination, reason) =
                    error as? DicomDataSetWriterError else {
                return XCTFail("Expected pixel recompression error, got \(error)")
            }
            XCTAssertEqual(source, "encapsulated Pixel Data")
            XCTAssertEqual(destination, DicomTransferSyntax.explicitVRLittleEndian.rawValue)
            XCTAssertTrue(reason.contains("decode the compressed frames"))
        }
    }

    func testWriterRejectsReferencedSyntaxWithLocalPixelData() throws {
        XCTAssertThrowsError(
            try DicomDataSetWriter.part10Data(
                from: makeBaseDataSet(pixelBytes: Data([0x30, 0x00])),
                options: DicomPart10WriterOptions(transferSyntax: .jpipReferenced)
            )
        ) { error in
            guard case let .transferSyntaxWriteUnsupported(uid, reason) = error as? DicomDataSetWriterError else {
                return XCTFail("Expected transfer syntax write error, got \(error)")
            }
            XCTAssertEqual(uid, DicomTransferSyntax.jpipReferenced.rawValue)
            XCTAssertTrue(reason.contains("local Pixel Data is not rewritten"))
        }
    }

    func testWriterPreservesReferencedPixelDataProviderURL() throws {
        let providerURL = "https://example.test/jpip/volume"
        let data = try DicomDataSetWriter.part10Data(
            from: makeReferencedDataSet(providerURL: providerURL),
            options: DicomPart10WriterOptions(transferSyntax: .jpipReferenced)
        )

        XCTAssertNotNil(data.range(of: Data(DicomTransferSyntax.jpipReferenced.rawValue.utf8)))
        XCTAssertNotNil(data.range(of: Data(providerURL.utf8)))
    }

    func testGeneratedUIDUsesDicomUIDSyntaxEnvelope() {
        let uid = DicomDataSetWriter.makeUID()

        XCTAssertTrue(uid.hasPrefix("2.25."))
        XCTAssertLessThanOrEqual(uid.count, 64)
        XCTAssertTrue(uid.allSatisfy { $0.isNumber || $0 == "." })
        XCTAssertNotNil(DicomUID(uid))
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
            DicomDataElement(tag: DicomTag.pixelSpacing.rawValue,
                             vr: .DS,
                             value: .strings(["0.5", "0.75"])),
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

    private func makeEncapsulatedDataSet(fragments: [Data]) -> DicomDataSet {
        var dataSet = makeBaseDataSet(pixelBytes: Data())
        dataSet.set(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue,
                                     vr: .IS,
                                     value: .strings(["\(fragments.count)"])))
        dataSet.set(DicomDataElement(tag: DicomTag.bitsAllocated.rawValue,
                                     vr: .US,
                                     value: .unsignedIntegers([8])))
        dataSet.set(DicomDataElement(tag: DicomTag.bitsStored.rawValue,
                                     vr: .US,
                                     value: .unsignedIntegers([8])))
        dataSet.set(DicomDataElement(tag: DicomTag.highBit.rawValue,
                                     vr: .US,
                                     value: .unsignedIntegers([7])))
        dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue,
                                     vr: .OB,
                                     value: .bytes(makeEncapsulatedPixelData(fragments: fragments))))
        return dataSet
    }

    private func makeReferencedDataSet(providerURL: String) -> DicomDataSet {
        var dataSet = makeBaseDataSet(pixelBytes: Data())
        dataSet.remove(.pixelData)
        dataSet.set(DicomDataElement(tag: DicomTag.pixelDataProviderURL.rawValue,
                                     vr: .UR,
                                     value: .strings([providerURL])))
        return dataSet
    }

    private func makeEncapsulatedPixelData(fragments: [Data]) -> Data {
        var data = Data()
        appendItem(uint32Data(basicOffsetTableOffsets(for: fragments)), to: &data)
        for fragment in fragments {
            appendItem(fragment, to: &data)
        }
        appendTag(0xFFFEE0DD, to: &data)
        appendUInt32(0, to: &data)
        return data
    }

    private func basicOffsetTableOffsets(for fragments: [Data]) -> [UInt32] {
        var offset = 0
        return fragments.map { fragment in
            defer { offset += 8 + fragment.count }
            return UInt32(offset)
        }
    }

    private func temporaryDICOMURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dcm")
    }

    private func appendItem(_ value: Data, to data: inout Data) {
        appendTag(0xFFFEE000, to: &data)
        appendUInt32(UInt32(value.count), to: &data)
        data.append(value)
    }

    private func appendTag(_ tag: Int, to data: inout Data) {
        appendUInt16(UInt16((tag >> 16) & 0xFFFF), to: &data)
        appendUInt16(UInt16(tag & 0xFFFF), to: &data)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private func uint32Data(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in
            appendUInt32(value, to: &data)
        }
    }

    private func readUInt32LittleEndian(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }
}
