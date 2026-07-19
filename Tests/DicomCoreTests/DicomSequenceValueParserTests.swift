import XCTest
@testable import DicomCore

final class DicomSequenceValueParserTests: XCTestCase {
    private let procedureCodeSequenceTag = 0x00081032
    private let modifierSequenceTag = 0x00080110
    private let codeValueTag = 0x00080100
    private let codeMeaningTag = 0x00080104
    private let privateUndefinedLengthUNTag = 0x77771001

    func testDataSetParserDecodesCyrillicSpecificCharacterSet() throws {
        let source = DicomDataSet(elements: [
            DicomDataElement(
                tag: DicomTag.specificCharacterSet.rawValue,
                vr: .CS,
                value: .strings(["ISO_IR 144"])
            ),
            DicomDataElement(
                tag: DicomTag.patientName.rawValue,
                vr: .PN,
                value: .strings(["Иванов^Иван"])
            )
        ])

        let parsed = try DicomDataSetParser.dataSet(
            from: DicomDataSetWriter.dataSetData(from: source)
        )

        XCTAssertEqual(parsed.string(for: .patientName), "Иванов^Иван")
    }

    func testDataSetParserDecodesISO2022SpecificCharacterSet() throws {
        let source = DicomDataSet(elements: [
            DicomDataElement(
                tag: DicomTag.specificCharacterSet.rawValue,
                vr: .CS,
                value: .strings(["ISO 2022 IR 87"])
            ),
            DicomDataElement(
                tag: DicomTag.studyDescription.rawValue,
                vr: .LO,
                value: .strings(["検査"])
            )
        ])

        let encoded = try DicomDataSetWriter.dataSetData(from: source)
        XCTAssertTrue(encoded.contains(0x1B))

        let parsed = try DicomDataSetParser.dataSet(from: encoded)

        XCTAssertEqual(parsed.string(for: .studyDescription), "検査")
    }

    func testNestedSequenceInheritsSpecificCharacterSet() throws {
        let source = DicomDataSet(elements: [
            DicomDataElement(
                tag: DicomTag.specificCharacterSet.rawValue,
                vr: .CS,
                value: .strings(["ISO_IR 144"])
            ),
            DicomDataElement(
                tag: procedureCodeSequenceTag,
                vr: .SQ,
                value: .sequence([
                    DicomSequenceItem(dataSet: DicomDataSet(elements: [
                        DicomDataElement(
                            tag: codeMeaningTag,
                            vr: .LO,
                            value: .strings(["Голова"])
                        )
                    ]))
                ])
            )
        ])

        let parsed = try DicomDataSetParser.dataSet(
            from: DicomDataSetWriter.dataSetData(from: source)
        )
        let item = try XCTUnwrap(parsed.sequenceItems(for: procedureCodeSequenceTag).first)

        XCTAssertEqual(item.dataSet.string(for: codeMeaningTag), "Голова")
    }

    func testMetadataParserSkipsPixelDataAndContinuesWithTrailingElements() throws {
        let data = element(DicomTag.patientName.rawValue, vr: "PN", value: "DOE^JANE")
            + pixelData(UInt16(7))
            + element(DicomTag.studyDescription.rawValue, vr: "LO", value: "After pixels")

        let parsed = try DicomDataSetParser.dataSet(from: data)

        XCTAssertNil(parsed.element(for: .pixelData))
        XCTAssertEqual(parsed.string(for: .studyDescription), "After pixels")
    }

    func testMetadataParserSkipsEncapsulatedPixelDataAndContinuesWithTrailingElements() throws {
        let pixelHeader = elementHeader(
            DicomTag.pixelData.rawValue,
            vr: "OB",
            length: .max,
            uses32BitLength: true
        )
        let fragment = itemHeader(length: 2) + Data([0x01, 0x02])
        let data = pixelHeader
            + itemHeader(length: 0)
            + fragment
            + delimiter(0xFFFE_E0DD)
            + element(DicomTag.studyDescription.rawValue, vr: "LO", value: "After pixels")

        let parsed = try DicomDataSetParser.dataSet(from: data)

        XCTAssertNil(parsed.element(for: .pixelData))
        XCTAssertEqual(parsed.string(for: .studyDescription), "After pixels")
    }

    func testExplicitLengthSequenceParsingContinuesToReturnItems() throws {
        let item = item(explicitValue: element(codeValueTag, vr: "SH", value: "CHEST"))
        let data = sequence(procedureCodeSequenceTag, explicitValue: item)

        let dataSet = try DicomDataSetParser.dataSet(from: data)

        let parsedItem = try XCTUnwrap(dataSet.sequenceItems(for: procedureCodeSequenceTag).first)
        XCTAssertEqual(parsedItem.dataSet.string(for: codeValueTag), "CHEST")
    }

    func testUndefinedLengthSequenceAndItemParseUntilDelimiters() throws {
        let data = sequence(
            procedureCodeSequenceTag,
            undefinedValue: item(
                undefinedValue: element(codeValueTag, vr: "SH", value: "CHEST")
            )
        )

        let dataSet = try DicomDataSetParser.dataSet(from: data)

        let parsedItem = try XCTUnwrap(dataSet.sequenceItems(for: procedureCodeSequenceTag).first)
        XCTAssertEqual(parsedItem.dataSet.string(for: codeValueTag), "CHEST")
    }

    func testImplicitVRUndefinedLengthUNParsesAsSequenceAndContinues() throws {
        let data = implicitElementHeader(privateUndefinedLengthUNTag, length: .max)
            + item(undefinedValue: implicitElement(codeValueTag, value: "PRIVATE"))
            + delimiter(0xFFFEE0DD)
            + implicitElement(codeMeaningTag, value: "After sequence")

        let dataSet = try DicomDataSetParser.dataSet(from: data, transferSyntax: .implicitVRLittleEndian)
        let parsedItem = try XCTUnwrap(dataSet.sequenceItems(for: privateUndefinedLengthUNTag).first)

        XCTAssertEqual(parsedItem.dataSet.string(for: codeValueTag), "PRIVATE")
        XCTAssertEqual(dataSet.string(for: codeMeaningTag), "After sequence")
    }

    func testNestedUndefinedLengthSequenceParsesInnerItems() throws {
        let nested = sequence(
            modifierSequenceTag,
            undefinedValue: item(
                undefinedValue: element(codeMeaningTag, vr: "LO", value: "Contrast enhanced")
            )
        )
        let data = sequence(
            procedureCodeSequenceTag,
            undefinedValue: item(undefinedValue: element(codeValueTag, vr: "SH", value: "CHEST") + nested)
        )

        let dataSet = try DicomDataSetParser.dataSet(from: data)
        let parsedItem = try XCTUnwrap(dataSet.sequenceItems(for: procedureCodeSequenceTag).first)
        let parsedNested = try XCTUnwrap(parsedItem.dataSet.sequenceItems(for: modifierSequenceTag).first)

        XCTAssertEqual(parsedItem.dataSet.string(for: codeValueTag), "CHEST")
        XCTAssertEqual(parsedNested.dataSet.string(for: codeMeaningTag), "Contrast enhanced")
    }

    func testUndefinedLengthItemMissingDelimiterThrowsStableError() {
        var data = sequenceHeader(procedureCodeSequenceTag, length: .max)
        data += itemHeader(length: .max)
        data += element(codeValueTag, vr: "SH", value: "CHEST")

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data)) { error in
            XCTAssertEqual(error as? DicomSequenceValueParserError, .missingItemDelimiter)
        }
    }

    func testUndefinedLengthSequenceMissingDelimiterThrowsStableError() {
        var data = sequenceHeader(procedureCodeSequenceTag, length: .max)
        data += item(explicitValue: element(codeValueTag, vr: "SH", value: "CHEST"))

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data)) { error in
            XCTAssertEqual(error as? DicomSequenceValueParserError, .missingSequenceDelimiter)
        }
    }

    func testExplicitLengthSequenceTruncatedItemHeaderThrowsUnexpectedEnd() {
        let data = sequenceHeader(procedureCodeSequenceTag, length: 4) + Data([0xFE, 0xFF, 0x00, 0xE0])

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data)) { error in
            XCTAssertEqual(error as? DicomSequenceValueParserError, .unexpectedEnd)
        }
    }

    func testUndefinedLengthItemRejectsSequenceDelimiterAsMalformedNesting() {
        var data = sequenceHeader(procedureCodeSequenceTag, length: .max)
        data += itemHeader(length: .max)
        data += element(codeValueTag, vr: "SH", value: "CHEST")
        data += delimiter(0xFFFEE0DD)

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data)) { error in
            XCTAssertEqual(error as? DicomSequenceValueParserError, .unexpectedSequenceDelimiter)
        }
    }

    func testUndefinedLengthSequenceRejectsInvalidItemTag() {
        let data = sequenceHeader(procedureCodeSequenceTag, length: .max)
            + element(codeValueTag, vr: "SH", value: "CHEST")

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data)) { error in
            XCTAssertEqual(error as? DicomSequenceValueParserError, .expectedItem(codeValueTag))
        }
    }

    func testDelimiterWithNonZeroLengthThrowsStableError() {
        var data = sequenceHeader(procedureCodeSequenceTag, length: .max)
        data += item(explicitValue: element(codeValueTag, vr: "SH", value: "CHEST"))
        data += delimiter(0xFFFEE0DD, length: 4)

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data)) { error in
            XCTAssertEqual(
                error as? DicomSequenceValueParserError,
                .invalidDelimiterLength(tag: 0xFFFEE0DD, length: 4)
            )
        }
    }

    func testDecoderCachesUndefinedLengthSequenceAndContinuesParsingFollowingTags() throws {
        let url = try makePart10WithUndefinedLengthSequence()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let item = try XCTUnwrap(decoder.dataSet.sequenceItems(for: procedureCodeSequenceTag).first)

        XCTAssertEqual(item.dataSet.string(for: codeValueTag), "CHEST")
        XCTAssertEqual(decoder.width, 1)
        XCTAssertEqual(decoder.height, 1)
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), [7])
    }

    private func makePart10WithUndefinedLengthSequence() throws -> URL {
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)
        data += element(
            DicomTag.transferSyntaxUID.rawValue,
            vr: "UI",
            value: DicomTransferSyntax.explicitVRLittleEndian.rawValue
        )
        data += sequence(
            procedureCodeSequenceTag,
            undefinedValue: item(undefinedValue: element(codeValueTag, vr: "SH", value: "CHEST"))
        )
        data += element(DicomTag.samplesPerPixel.rawValue, vr: "US", value: UInt16(1))
        data += element(DicomTag.photometricInterpretation.rawValue, vr: "CS", value: "MONOCHROME2")
        data += element(DicomTag.rows.rawValue, vr: "US", value: UInt16(1))
        data += element(DicomTag.columns.rawValue, vr: "US", value: UInt16(1))
        data += element(DicomTag.bitsAllocated.rawValue, vr: "US", value: UInt16(16))
        data += element(DicomTag.bitsStored.rawValue, vr: "US", value: UInt16(16))
        data += element(DicomTag.highBit.rawValue, vr: "US", value: UInt16(15))
        data += element(DicomTag.pixelRepresentation.rawValue, vr: "US", value: UInt16(0))
        data += pixelData(UInt16(7))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("undefined_sequence_\(UUID().uuidString).dcm")
        try data.write(to: url)
        return url
    }

    private func sequence(_ tag: Int, explicitValue: Data) -> Data {
        sequenceHeader(tag, length: UInt32(explicitValue.count)) + explicitValue
    }

    private func sequence(_ tag: Int, undefinedValue: Data) -> Data {
        sequenceHeader(tag, length: .max) + undefinedValue + delimiter(0xFFFEE0DD)
    }

    private func item(explicitValue: Data) -> Data {
        itemHeader(length: UInt32(explicitValue.count)) + explicitValue
    }

    private func item(undefinedValue: Data) -> Data {
        itemHeader(length: .max) + undefinedValue + delimiter(0xFFFEE00D)
    }

    private func sequenceHeader(_ tag: Int, length: UInt32) -> Data {
        elementHeader(tag, vr: "SQ", length: length, uses32BitLength: true)
    }

    private func implicitElementHeader(_ tag: Int, length: UInt32) -> Data {
        tagData(tag) + uint32Data(length)
    }

    private func itemHeader(length: UInt32) -> Data {
        tagData(0xFFFEE000) + uint32Data(length)
    }

    private func delimiter(_ tag: Int, length: UInt32 = 0) -> Data {
        tagData(tag) + uint32Data(length)
    }

    private func element(_ tag: Int, vr: String, value: String) -> Data {
        let padding: UInt8 = vr == "UI" ? 0x00 : 0x20
        var bytes = Array(value.utf8)
        if bytes.count % 2 != 0 {
            bytes.append(padding)
        }
        return elementHeader(tag, vr: vr, length: UInt32(bytes.count), uses32BitLength: false) + Data(bytes)
    }

    private func implicitElement(_ tag: Int, value: String) -> Data {
        var bytes = Array(value.utf8)
        if bytes.count % 2 != 0 {
            bytes.append(0x20)
        }
        return implicitElementHeader(tag, length: UInt32(bytes.count)) + Data(bytes)
    }

    private func element(_ tag: Int, vr: String, value: UInt16) -> Data {
        elementHeader(tag, vr: vr, length: 2, uses32BitLength: false) + uint16Data(value)
    }

    private func pixelData(_ value: UInt16) -> Data {
        elementHeader(DicomTag.pixelData.rawValue, vr: "OW", length: 2, uses32BitLength: true) + uint16Data(value)
    }

    private func elementHeader(_ tag: Int, vr: String, length: UInt32, uses32BitLength: Bool) -> Data {
        var data = tagData(tag)
        data.append(contentsOf: vr.utf8)
        if uses32BitLength {
            data.append(contentsOf: [0x00, 0x00])
            data += uint32Data(length)
        } else {
            data += uint16Data(UInt16(length))
        }
        return data
    }

    private func tagData(_ tag: Int) -> Data {
        uint16Data(UInt16((tag >> 16) & 0xFFFF)) + uint16Data(UInt16(tag & 0xFFFF))
    }

    private func uint16Data(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private func uint32Data(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
