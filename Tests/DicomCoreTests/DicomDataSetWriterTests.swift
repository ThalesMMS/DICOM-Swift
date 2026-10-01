import XCTest
@testable import DicomCore

final class DicomDataSetWriterTests: XCTestCase {
    func test_numericOWAndOV_encodeBinaryWordsInBothByteOrders() throws {
        let word = DicomDataElement(tag: 0x77771001, vr: .OW, value: .unsignedIntegers([0x1234, 0xABCD]))
        let long = DicomDataElement(tag: 0x77771002, vr: .OV, value: .unsignedIntegers([0x0102030405060708, UInt.max]))
        let source = DicomDataSet(elements: [word, long])
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian] {
            let wire = try DicomDataSetWriter.dataSetData(from: source, transferSyntax: syntax)
            let parsed = try DicomDataSetParser.dataSet(from: wire, transferSyntax: syntax)
            let little = syntax == .explicitVRLittleEndian
            XCTAssertEqual(parsed[word.tag]?.bytesValue, Data(little ? [0x34, 0x12, 0xCD, 0xAB] : [0x12, 0x34, 0xAB, 0xCD]))
            XCTAssertEqual(parsed[long.tag]?.bytesValue,
                           Data(little ? [8, 7, 6, 5, 4, 3, 2, 1] : [1, 2, 3, 4, 5, 6, 7, 8]) + Data(repeating: 255, count: 8))
            XCTAssertEqual(try DicomDataSetWriter.dataSetData(from: parsed, transferSyntax: syntax), wire)
        }
        XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: source, purpose: .instance))
    }

    private let sopClassUIDTag = 0x00080016
    private let procedureCodeSequenceTag = 0x00081032
    private let codeValueTag = 0x00080100
    private let codeMeaningTag = 0x00080104
    private let privateTag = 0x00111010

    func test_veryLongIntegers_roundTripBinaryValuesInBothByteOrders() throws {
        let signed = DicomDataElement(tag: 0x77771001, vr: .SV, value: .signedIntegers([Int.min, -1, Int.max]))
        let unsigned = DicomDataElement(tag: 0x77771002, vr: .UV, value: .unsignedIntegers([0, UInt.max]))
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian] {
            let data = try DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: [signed, unsigned]),
                                                         transferSyntax: syntax)
            XCTAssertEqual(data.count, 24 + 24 + 16)
            let parsed = try DicomDataSetParser.dataSet(from: data, transferSyntax: syntax)
            XCTAssertEqual(parsed.element(for: signed.tag), signed)
            XCTAssertEqual(parsed.element(for: unsigned.tag), unsigned)
        }
    }

    func test_veryLongIntegers_rejectIncompatibleValuesWithoutDroppingComponents() {
        let cases: [(DicomVR, DicomDataValue)] = [
            (.SV, .unsignedIntegers([0, UInt(Int.max) + 1, 1])),
            (.SV, .unsignedIntegers([UInt.max])),
            (.UV, .signedIntegers([0, -1, 1])),
            (.UV, .signedIntegers([Int.min])),
            (.SV, .strings(["1", String(UInt.max), "2"])),
            (.UV, .strings(["1", "-1", "2"])),
            (.SV, .strings(["1", "invalid", "2"])),
            (.UV, .strings(["1", "", "2"]))
        ]
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian] {
            for (vr, value) in cases {
                let element = DicomDataElement(tag: privateTag, vr: vr, value: value)
                XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(
                    from: DicomDataSet(elements: [element]), transferSyntax: syntax
                ), "\(vr.code): \(value)") { error in
                    guard case let .unsupportedValue(tag, rejectedVR, _) = error as? DicomDataSetWriterError else {
                        return XCTFail("Expected unsupportedValue, got \(error)")
                    }
                    XCTAssertEqual(tag, element.tag)
                    XCTAssertEqual(rejectedVR, vr)
                }
            }
        }
    }

    func test_veryLongIntegers_preserveCompatibleConversionsAndEmptyValues() throws {
        let cases: [(DicomVR, DicomDataValue, DicomDataValue)] = [
            (.SV, .unsignedIntegers([0, 1, UInt(Int.max)]), .signedIntegers([0, 1, Int.max])),
            (.UV, .signedIntegers([0, 1, Int.max]), .unsignedIntegers([0, 1, UInt(Int.max)])),
            (.SV, .strings([String(Int.min), " 0 ", String(Int.max)]), .signedIntegers([Int.min, 0, Int.max])),
            (.UV, .strings([" 0 ", String(UInt.max)]), .unsignedIntegers([0, UInt.max])),
            (.SV, .empty, .signedIntegers([])),
            (.UV, .empty, .unsignedIntegers([]))
        ]
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian] {
            for (vr, source, expected) in cases {
                let element = DicomDataElement(tag: privateTag, vr: vr, value: source)
                let data = try DicomDataSetWriter.dataSetData(
                    from: DicomDataSet(elements: [element]), transferSyntax: syntax
                )
                let parsed = try DicomDataSetParser.dataSet(from: data, transferSyntax: syntax)
                XCTAssertEqual(parsed.element(for: privateTag),
                               DicomDataElement(tag: privateTag, vr: vr, value: expected))
            }
        }
    }

    func test_decimalFloats_encodeFiniteComponentsWithinSixteenCharacters() throws {
        let values = [Double.pi, -123456789.123456, 1e-120, 1e120, Double.leastNonzeroMagnitude]
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.pixelSpacing.rawValue, vr: .DS, value: .floats(values))
        ])
        let parsed = try DicomDataSetParser.dataSet(from: DicomDataSetWriter.dataSetData(from: dataSet))
        let components = try XCTUnwrap(parsed.element(for: .pixelSpacing)).stringValues
        XCTAssertEqual(components.count, values.count)
        for (text, original) in zip(components, values) {
            XCTAssertLessThanOrEqual(text.utf8.count, 16, text)
            let number = try XCTUnwrap(Double(text))
            XCTAssertTrue(number.isFinite)
            XCTAssertEqual(number, original, accuracy: max(abs(original) * 1e-12, Double.leastNonzeroMagnitude))
        }
        for value in [Double.nan, .infinity, -.infinity] {
            let invalid = DicomDataSet(elements: [
                DicomDataElement(tag: DicomTag.pixelSpacing.rawValue, vr: .DS, value: .floats([value]))
            ])
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: invalid))
        }
    }

    func test_decimalStrings_preserveCallerFormatting() throws {
        let values = ["+01.2500", "1.5E-03"]
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.pixelSpacing.rawValue, vr: .DS, value: .strings(values))
        ])
        let parsed = try DicomDataSetParser.dataSet(from: DicomDataSetWriter.dataSetData(from: dataSet))
        XCTAssertEqual(parsed.element(for: .pixelSpacing)?.stringValues, values)
    }

    func test_decimalStrings_rejectOversizedAndNonfiniteComponents() {
        for value in ["12345678901234567", "NaN", "Infinity", "1e999", "invalid", "0x1p2", "1\t", "1\n", "1 2",
                      " 1234567890123456 "] {
            let element = DicomDataElement(tag: privateTag, vr: .DS, value: .strings(["1.25", value]))
            XCTAssertThrowsError(try DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: [element]))) {
                guard case .unsupportedValue(tag: self.privateTag, vr: .DS, reason: _) = $0 as? DicomDataSetWriterError else {
                    return XCTFail("Expected DS unsupportedValue, got \($0)")
                }
            }
        }
    }

    func test_decimalStrings_acceptNumericGrammarAndSpacePadding() throws {
        for value in [" +.5e+02 ", "-1.", ".5", "", "    ", "1234567890123456"] {
            let element = DicomDataElement(tag: privateTag, vr: .DS, value: .strings([value]))
            let data = try DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: [element]))
            var expected = Data(value.utf8)
            if expected.count % 2 != 0 { expected.append(0x20) }
            XCTAssertEqual(Data(data.dropFirst(8)), expected)
        }
    }

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

    func test_writerRoundTripsLongTextWithoutSplittingOrTrimming() throws {
        let fields: [(Int, DicomVR)] = [(0x0032_4000, .LT), (0x0008_2111, .ST), (0x0040_A160, .UT)]
        let comment = "  linha 1\nRenée\\B"
        let transferSyntaxes: [DicomTransferSyntax] = [
            .explicitVRLittleEndian, .explicitVRBigEndian,
            .implicitVRLittleEndian, .deflatedExplicitVRLittleEndian
        ]

        for transferSyntax in transferSyntaxes {
            var dataSet = makeBaseDataSet(pixelBytes: Data([0x31, 0x00]))
            dataSet.set(DicomDataElement(
                tag: DicomTag.specificCharacterSet.rawValue,
                vr: .CS,
                value: .strings(["ISO_IR 192"])
            ))
            for (tag, vr) in fields {
                dataSet.set(DicomDataElement(tag: tag, vr: vr, value: .strings([comment])))
            }
            let data = try DicomDataSetWriter.part10Data(
                from: dataSet,
                options: DicomPart10WriterOptions(transferSyntax: transferSyntax)
            )
            let decoder = try DCMDecoder(data: data)
            for (tag, vr) in fields {
                let element = try XCTUnwrap(decoder.dataSet.element(for: tag))
                XCTAssertEqual(element.vr, vr, transferSyntax.rawValue)
                XCTAssertEqual(element.stringValue, comment, transferSyntax.rawValue)
                XCTAssertEqual(element.stringValues, [comment], transferSyntax.rawValue)
            }
        }
    }

    /// Isis issue #2855: private sequences stored as OB or UN bytes (CP 246) before encapsulated Pixel Data, even with
    /// item delimiters and a Pixel Data tag inside, leave the fragments where they are.
    func testSequenceBytesInOBOrUNBeforeEncapsulatedPixelData_leaveTheFragmentsInPlace() throws {
        let frame = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        var dataSet = makeEncapsulatedDataSet(fragments: [frame])
        var sequenceBytes = Data()
        appendTag(0xFFFEE000, to: &sequenceBytes)
        appendUInt32(0xFFFF_FFFF, to: &sequenceBytes)
        appendTag(0x7FE00010, to: &sequenceBytes)
        sequenceBytes.append(contentsOf: Array("OB".utf8) + [0, 0])
        appendUInt32(0xFFFF_FFFF, to: &sequenceBytes)
        appendTag(0xFFFEE00D, to: &sequenceBytes)
        appendUInt32(0, to: &sequenceBytes)
        appendTag(0xFFFEE0DD, to: &sequenceBytes)
        appendUInt32(0, to: &sequenceBytes)
        dataSet.set(DicomDataElement(tag: 0x00291010, vr: .OB, value: .bytes(sequenceBytes)))
        dataSet.set(DicomDataElement(tag: 0x00191011, vr: .UN, value: .bytes(sequenceBytes)))
        let url = temporaryDICOMURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try DicomDataSetWriter.write(dataSet, to: url,
                                     options: DicomPart10WriterOptions(transferSyntax: .jpegBaseline))

        let decoder = try DCMDecoder(contentsOf: url)
        XCTAssertEqual(try XCTUnwrap(decoder.getEncapsulatedFrame(0)).data, frame)
        XCTAssertEqual(try decoder.makeEncapsulatedPixelFrameReader().frameData(at: 0), frame)
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
