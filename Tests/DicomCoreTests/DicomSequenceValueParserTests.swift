import XCTest
@testable import DicomCore

final class DicomSequenceValueParserTests: XCTestCase {
    func test_slicedData_valueReaderReceivesAbsoluteRanges() throws {
        let storage = Data([0xEE, 0xEE, 0xEE,
                            0xFE, 0xFF, 0x00, 0xE0, 10, 0, 0, 0,
                            0x10, 0, 0x10, 0, 0x50, 0x4E, 2, 0, 0x41, 0x42])
        let data = storage.dropFirst(3)
        var ranges: [Range<Int>] = []
        let items = try DicomSequenceValueParser.parseItems(
            in: data, valueOffset: 0, valueLength: data.count, littleEndian: true, explicitVR: true,
            valueDataReader: { bytes, range, _, _ in
                ranges.append(range)
                return Data(bytes[range])
            }
        )
        let reference = try DicomSequenceValueParser.parseItems(
            in: data, valueOffset: 0, valueLength: data.count, littleEndian: true, explicitVR: true
        )
        XCTAssertEqual(ranges, [19..<21])
        XCTAssertEqual(items, reference)
        XCTAssertEqual(items.first?.dataSet.string(for: .patientName), "AB")
    }

    private let procedureCodeSequenceTag = 0x00081032
    private let modifierSequenceTag = 0x00080110
    private let codeValueTag = 0x00080100
    private let codeMeaningTag = 0x00080104
    private let privateUndefinedLengthUNTag = 0x77771001

    func test_newLongVRHeaders_preserveFollowingElementAlignment() throws {
        for (code, value) in [("UC", Data("Long text ".utf8)),
                              ("SV", Data(repeating: 0xFF, count: 8)),
                              ("UV", Data(repeating: 0x01, count: 8))] {
            let vr = try XCTUnwrap(DicomVR(code: code))
            XCTAssertTrue(vr.uses32BitLength)
            let bytes = elementHeader(privateUndefinedLengthUNTag, vr: code,
                                      length: UInt32(value.count), uses32BitLength: true) + value
                + element(codeMeaningTag, vr: "LO", value: "Following")
            let parsed = try DicomDataSetParser.dataSet(from: bytes)
            XCTAssertEqual(parsed.element(for: privateUndefinedLengthUNTag)?.vr, vr)
            XCTAssertEqual(parsed.string(for: codeMeaningTag), "Following")
        }
    }

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
                value: .strings(["", "ISO 2022 IR 87"])
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

    // Regression: C-FIND response identifiers negotiated as Implicit VR Little
    // Endian used to decode every study-level tag as UN, so patient name, dates,
    // and StudyInstanceUID were silently dropped.
    func testImplicitVRStudyLevelFindIdentifierDecodesStringValues() throws {
        let studyInstanceUID = "1.2.840.99999.100.20"
        let fragments: [Data] = [
            implicitElement(DicomTag.specificCharacterSet.rawValue, value: "ISO_IR 192"),
            implicitElement(DicomTag.studyDate.rawValue, value: "20260115"),
            implicitElement(DicomTag.studyTime.rawValue, value: "093000"),
            implicitElement(0x00080050, value: "ACC001"),
            implicitElement(0x00080052, value: "STUDY"),
            implicitElement(DicomTag.modalitiesInStudy.rawValue, value: "CT\\SR"),
            implicitElement(DicomTag.institutionName.rawValue, value: "GENERAL HOSPITAL"),
            implicitElement(DicomTag.studyDescription.rawValue, value: "CHEST CT"),
            implicitElement(DicomTag.patientName.rawValue, value: "DOE^JOHN"),
            implicitElement(DicomTag.patientID.rawValue, value: "PID-001"),
            implicitElement(0x00100030, value: "19800115"),
            implicitElement(DicomTag.patientSex.rawValue, value: "M"),
            implicitElement(DicomTag.studyInstanceUID.rawValue, value: studyInstanceUID),
            implicitElement(DicomTag.studyID.rawValue, value: "ST-1"),
            implicitElement(DicomTag.numberOfStudyRelatedSeries.rawValue, value: "6"),
            implicitElement(0x00201208, value: "120")
        ]
        let data = fragments.reduce(Data(), +)

        let dataSet = try DicomDataSetParser.dataSet(from: data, transferSyntax: .implicitVRLittleEndian)

        XCTAssertEqual(dataSet.string(for: .specificCharacterSet), "ISO_IR 192")
        XCTAssertEqual(dataSet.string(for: .studyDate), "20260115")
        XCTAssertEqual(dataSet.string(for: .studyTime), "093000")
        XCTAssertEqual(dataSet.string(for: 0x00080050), "ACC001")
        XCTAssertEqual(dataSet.string(for: 0x00080052), "STUDY")
        XCTAssertEqual(dataSet.strings(for: .modalitiesInStudy), ["CT", "SR"])
        XCTAssertEqual(dataSet.string(for: .institutionName), "GENERAL HOSPITAL")
        XCTAssertEqual(dataSet.string(for: .studyDescription), "CHEST CT")
        XCTAssertEqual(dataSet.string(for: .patientName), "DOE^JOHN")
        XCTAssertEqual(dataSet.string(for: .patientID), "PID-001")
        XCTAssertEqual(dataSet.string(for: 0x00100030), "19800115")
        XCTAssertEqual(dataSet.string(for: .patientSex), "M")
        XCTAssertEqual(dataSet.string(for: .studyInstanceUID), studyInstanceUID)
        XCTAssertEqual(dataSet.string(for: .studyID), "ST-1")
        XCTAssertEqual(dataSet.int(for: .numberOfStudyRelatedSeries), 6)
        XCTAssertEqual(dataSet.int(for: 0x00201208), 120)
    }

    func testImplicitVRSeriesLevelFindIdentifierDecodesStringAndBinaryValues() throws {
        let seriesInstanceUID = "1.2.840.99999.300.40"
        let fragments: [Data] = [
            implicitElement(DicomTag.seriesDate.rawValue, value: "20260116"),
            implicitElement(DicomTag.seriesTime.rawValue, value: "101500"),
            implicitElement(0x00080052, value: "SERIES"),
            implicitElement(DicomTag.modality.rawValue, value: "CT"),
            implicitElement(DicomTag.seriesDescription.rawValue, value: "AXIAL 1MM"),
            implicitElement(DicomTag.seriesInstanceUID.rawValue, value: seriesInstanceUID),
            implicitElement(DicomTag.seriesNumber.rawValue, value: "3"),
            implicitElement(DicomTag.numberOfSeriesRelatedInstances.rawValue, value: "240"),
            implicitElementHeader(DicomTag.rows.rawValue, length: 2) + uint16Data(512),
            implicitElementHeader(DicomTag.columns.rawValue, length: 2) + uint16Data(256)
        ]
        let data = fragments.reduce(Data(), +)

        let dataSet = try DicomDataSetParser.dataSet(from: data, transferSyntax: .implicitVRLittleEndian)

        XCTAssertEqual(dataSet.string(for: .seriesDate), "20260116")
        XCTAssertEqual(dataSet.string(for: .seriesTime), "101500")
        XCTAssertEqual(dataSet.string(for: .modality), "CT")
        XCTAssertEqual(dataSet.string(for: .seriesDescription), "AXIAL 1MM")
        XCTAssertEqual(dataSet.string(for: .seriesInstanceUID), seriesInstanceUID)
        XCTAssertEqual(dataSet.int(for: .seriesNumber), 3)
        XCTAssertEqual(dataSet.int(for: .numberOfSeriesRelatedInstances), 240)
        XCTAssertEqual(dataSet.int(for: .rows), 512)
        XCTAssertEqual(dataSet.int(for: .columns), 256)
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

    func test_dataSetParser_definedUndefinedAndMixedDepthAtLimit_parses() throws {
        let limits = DicomDataSetParseLimits(
            maximumSequenceDepth: 3,
            maximumElementCount: 4,
            maximumItemCount: 4
        )
        let encodings = [
            [false, false, false],
            [true, true, true],
            [false, true, false]
        ]

        for encoding in encodings {
            XCTAssertNoThrow(try DicomDataSetParser.dataSet(
                from: nestedSequences(undefinedLengths: encoding),
                limits: limits
            ))
        }
    }

    func test_dataSetParser_definedUndefinedAndMixedDepthAboveLimit_throwsTypedError() {
        let limits = DicomDataSetParseLimits(
            maximumSequenceDepth: 3,
            maximumElementCount: 4,
            maximumItemCount: 4
        )
        let encodings = [
            [false, false, false, false],
            [true, true, true, true],
            [false, true, false, true]
        ]

        for encoding in encodings {
            assertParseError(
                .maximumSequenceDepthExceeded(limit: 3),
                data: nestedSequences(undefinedLengths: encoding),
                limits: limits
            )
        }
    }

    func test_dataSetParser_implicitUndefinedLengthUNDepth_enforcesInclusiveLimit() throws {
        let limits = DicomDataSetParseLimits(
            maximumSequenceDepth: 2,
            maximumElementCount: 3,
            maximumItemCount: 3
        )

        XCTAssertNoThrow(try DicomDataSetParser.dataSet(
            from: nestedImplicitUndefinedLengthUN(depth: 2),
            transferSyntax: .implicitVRLittleEndian,
            limits: limits
        ))
        assertParseError(
            .maximumSequenceDepthExceeded(limit: 2),
            data: nestedImplicitUndefinedLengthUN(depth: 3),
            transferSyntax: .implicitVRLittleEndian,
            limits: limits
        )
    }

    func test_dataSetParser_elementCount_enforcesInclusiveLimit() throws {
        let limits = DicomDataSetParseLimits(
            maximumSequenceDepth: 0,
            maximumElementCount: 3,
            maximumItemCount: 0
        )

        XCTAssertNoThrow(try DicomDataSetParser.dataSet(from: emptyElements(count: 3), limits: limits))
        assertParseError(
            .maximumElementCountExceeded(limit: 3),
            data: emptyElements(count: 4),
            limits: limits
        )
    }

    func test_dataSetParser_definedAndUndefinedItemCount_enforcesInclusiveLimit() throws {
        let limits = DicomDataSetParseLimits(
            maximumSequenceDepth: 1,
            maximumElementCount: 1,
            maximumItemCount: 3
        )

        for undefinedLength in [false, true] {
            XCTAssertNoThrow(try DicomDataSetParser.dataSet(
                from: sequenceWithEmptyItems(count: 3, undefinedLength: undefinedLength),
                limits: limits
            ))
            assertParseError(
                .maximumItemCountExceeded(limit: 3),
                data: sequenceWithEmptyItems(count: 4, undefinedLength: undefinedLength),
                limits: limits
            )
        }
    }

    func test_dataSetParser_elementBudgetAcrossMixedItems_isGlobal() throws {
        let limits = DicomDataSetParseLimits(
            maximumSequenceDepth: 1,
            maximumElementCount: 3,
            maximumItemCount: 2
        )

        XCTAssertNoThrow(try DicomDataSetParser.dataSet(
            from: sequenceWithElementsPerItem([1, 1]),
            limits: limits
        ))
        assertParseError(
            .maximumElementCountExceeded(limit: 3),
            data: sequenceWithElementsPerItem([1, 2]),
            limits: limits
        )
    }

    func test_dataSetParser_itemBudgetAcrossDefinedAndUndefinedSequences_isGlobal() throws {
        let limits = DicomDataSetParseLimits(
            maximumSequenceDepth: 1,
            maximumElementCount: 2,
            maximumItemCount: 3
        )

        XCTAssertNoThrow(try DicomDataSetParser.dataSet(
            from: siblingSequencesWithItemCounts(first: 1, second: 2),
            limits: limits
        ))
        assertParseError(
            .maximumItemCountExceeded(limit: 3),
            data: siblingSequencesWithItemCounts(first: 2, second: 2),
            limits: limits
        )
    }

    func test_dataSetParser_withoutExplicitLimits_rejectsDefaultDepthPlusOne() {
        let depth = DicomDataSetParseLimits.default.maximumSequenceDepth + 1
        let data = nestedSequences(undefinedLengths: Array(repeating: false, count: depth))

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data)) { error in
            XCTAssertEqual(
                error as? DicomDataSetParseError,
                .maximumSequenceDepthExceeded(
                    limit: DicomDataSetParseLimits.default.maximumSequenceDepth
                )
            )
        }
    }

    func test_dataSetParser_withoutExplicitLimits_rejectsDefaultElementCountPlusOne() {
        let limit = DicomDataSetParseLimits.default.maximumElementCount

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: emptyElements(count: limit + 1))) { error in
            XCTAssertEqual(
                error as? DicomDataSetParseError,
                .maximumElementCountExceeded(limit: limit)
            )
        }
    }

    func test_dataSetParser_withoutExplicitLimits_rejectsDefaultItemCountPlusOne() {
        let limit = DicomDataSetParseLimits.default.maximumItemCount
        let data = sequenceWithEmptyItems(count: limit + 1, undefinedLength: false)

        XCTAssertThrowsError(try DicomDataSetParser.dataSet(from: data)) { error in
            XCTAssertEqual(
                error as? DicomDataSetParseError,
                .maximumItemCountExceeded(limit: limit)
            )
        }
    }

    func test_dataSetParser_whenTaskIsAlreadyCancelled_throwsCancellationError() async {
        let data = emptyElements(count: 1)
        let task = Task<DicomDataSet, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DicomDataSetParser.dataSet(
                from: data,
                limits: DicomDataSetParseLimits(
                    maximumSequenceDepth: 0,
                    maximumElementCount: 1,
                    maximumItemCount: 0
                )
            )
        }

        do {
            _ = try await task.value
            XCTFail("An already-cancelled parser task should not publish a dataset")
        } catch is CancellationError {
            // Expected before the parser consumes the first element.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
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

    private func nestedSequences(undefinedLengths: [Bool]) -> Data {
        var nested = Data()
        for undefinedLength in undefinedLengths.reversed() {
            let encodedItem = undefinedLength
                ? item(undefinedValue: nested)
                : item(explicitValue: nested)
            nested = undefinedLength
                ? sequence(procedureCodeSequenceTag, undefinedValue: encodedItem)
                : sequence(procedureCodeSequenceTag, explicitValue: encodedItem)
        }
        return nested
    }

    private func nestedImplicitUndefinedLengthUN(depth: Int) -> Data {
        var nested = Data()
        for _ in 0..<depth {
            nested = implicitElementHeader(privateUndefinedLengthUNTag, length: .max)
                + item(undefinedValue: nested)
                + delimiter(0xFFFEE0DD)
        }
        return nested
    }

    private func emptyElements(count: Int) -> Data {
        let encodedElement = elementHeader(codeMeaningTag, vr: "LO", length: 0, uses32BitLength: false)
        var data = Data()
        data.reserveCapacity(encodedElement.count * count)
        for _ in 0..<count {
            data.append(encodedElement)
        }
        return data
    }

    private func sequenceWithEmptyItems(count: Int, undefinedLength: Bool) -> Data {
        let encodedItem = undefinedLength ? item(undefinedValue: Data()) : item(explicitValue: Data())
        var items = Data()
        items.reserveCapacity(encodedItem.count * count)
        for _ in 0..<count {
            items.append(encodedItem)
        }
        return undefinedLength
            ? sequence(procedureCodeSequenceTag, undefinedValue: items)
            : sequence(procedureCodeSequenceTag, explicitValue: items)
    }

    private func sequenceWithElementsPerItem(_ elementCounts: [Int]) -> Data {
        let items = elementCounts.enumerated().reduce(into: Data()) { data, entry in
            let value = emptyElements(count: entry.element)
            data += entry.offset.isMultiple(of: 2)
                ? item(explicitValue: value)
                : item(undefinedValue: value)
        }
        return sequence(procedureCodeSequenceTag, undefinedValue: items)
    }

    private func siblingSequencesWithItemCounts(first: Int, second: Int) -> Data {
        let firstItems = (0..<first).reduce(into: Data()) { data, _ in
            data += item(explicitValue: Data())
        }
        let secondItems = (0..<second).reduce(into: Data()) { data, _ in
            data += item(undefinedValue: Data())
        }
        return sequence(procedureCodeSequenceTag, explicitValue: firstItems)
            + sequence(modifierSequenceTag, undefinedValue: secondItems)
    }

    private func assertParseError(
        _ expected: DicomDataSetParseError,
        data: Data,
        transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
        limits: DicomDataSetParseLimits,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DicomDataSetParser.dataSet(
                from: data,
                transferSyntax: transferSyntax,
                limits: limits
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? DicomDataSetParseError, expected, file: file, line: line)
        }
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
