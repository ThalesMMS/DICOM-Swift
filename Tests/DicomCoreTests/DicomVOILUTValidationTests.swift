//
//  DicomVOILUTValidationTests.swift
//  DICOM-Swift
//
//  Issue #1865 phase A: the decoded-frame metadata carries every valid VOI
//  LUT Sequence item, and a malformed item is dropped with a typed reason —
//  never by failing the decode. `validatedVOILookupTables()` names the
//  defects the silent `displayTransformProfile.voiLUTs` path only omits.
//

import XCTest
@testable import DicomCore

final class DicomVOILUTValidationTests: XCTestCase {

    // MARK: - Valid tables reach the decoded-frame metadata

    func test_readerMetadata_carriesTheValidVOILUT() throws {
        let url = try makeTemporaryDICOM(extraElements: [
            sequence(.voiLUTSequence, [
                DicomDataSet(elements: [
                    us(.lutDescriptor, [4, 0, 8]),
                    string(.lutExplanation, vr: .LO, "VOI ramp"),
                    us(.lutData, [0, 64, 128, 255])
                ])
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let frame = try awaitFrame(reader)

        XCTAssertEqual(frame.metadata.voiLUTs.count, 1)
        let lut = try XCTUnwrap(frame.metadata.voiLUTs.first)
        XCTAssertEqual(lut.descriptor.entryCount, 4)
        XCTAssertEqual(lut.descriptor.firstMappedValue, 0)
        XCTAssertEqual(lut.descriptor.bitsPerEntry, 8)
        XCTAssertEqual(lut.data, [0, 64, 128, 255])
        XCTAssertEqual(lut.explanation, "VOI ramp")
    }

    func test_readerMetadata_unpacksEightBitOWDataIntoDeclaredEntries() throws {
        let url = try makeTemporaryDICOM(extraElements: [
            sequence(.voiLUTSequence, [
                DicomDataSet(elements: [
                    us(.lutDescriptor, [4, 0, 8]),
                    bytes(.lutData, vr: .OW, Data([0, 64, 128, 255]))
                ])
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = try awaitFrame(try DicomDecodedFrameReader(contentsOf: url))

        XCTAssertEqual(frame.metadata.voiLUTs.first?.data, [0, 64, 128, 255])
    }

    func test_readerMetadata_acceptsLegacyEightBitOWDataAllocatedAsWords() throws {
        let url = try makeTemporaryDICOM(extraElements: [
            sequence(.voiLUTSequence, [
                DicomDataSet(elements: [
                    us(.lutDescriptor, [4, 0, 8]),
                    bytes(.lutData, vr: .OW, Data(littleEndianBytes(values: [0, 64, 128, 255])))
                ])
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = try awaitFrame(try DicomDecodedFrameReader(contentsOf: url))

        XCTAssertEqual(frame.metadata.voiLUTs.first?.data, [0, 64, 128, 255])
    }

    func test_readerMetadata_boundsOversizedEightBitOWDataToDeclaredEntries() throws {
        var oversizedData = Data([0, 64, 128, 255])
        oversizedData.append(Data(repeating: 0xAA, count: 1_048_576))
        let url = try makeTemporaryDICOM(extraElements: [
            sequence(.voiLUTSequence, [
                DicomDataSet(elements: [
                    us(.lutDescriptor, [4, 0, 8]),
                    bytes(.lutData, vr: .OW, oversizedData)
                ])
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = try awaitFrame(try DicomDecodedFrameReader(contentsOf: url))

        XCTAssertEqual(frame.metadata.voiLUTs.first?.data, [0, 64, 128, 255])
    }

    func test_readerMetadata_preservesSignedFirstMappedValue() throws {
        let url = try makeTemporaryDICOM(extraElements: [
            sequence(.voiLUTSequence, [
                DicomDataSet(elements: [
                    ss(.lutDescriptor, [4, -2, 12]),
                    us(.lutData, [0, 1024, 2048, 4095])
                ])
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let lut = try XCTUnwrap(
            try awaitFrame(DicomDecodedFrameReader(contentsOf: url)).metadata.voiLUTs.first
        )

        XCTAssertEqual(lut.descriptor.firstMappedValue, -2)
        XCTAssertEqual(lut.descriptor.bitsPerEntry, 12)
        XCTAssertEqual(lut.data, [0, 1024, 2048, 4095])
    }

    func test_readerMetadata_descriptorZeroMeans65536Entries() throws {
        let values = (0..<65_536).map(UInt16.init)
        let url = try makeTemporaryDICOM(extraElements: [
            sequence(.voiLUTSequence, [
                DicomDataSet(elements: [
                    us(.lutDescriptor, [0, 0, 16]),
                    bytes(.lutData, vr: .OW, Data(littleEndianBytes(values: values)))
                ])
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let lut = try XCTUnwrap(
            try awaitFrame(DicomDecodedFrameReader(contentsOf: url)).metadata.voiLUTs.first
        )

        XCTAssertEqual(lut.descriptor.entryCount, 65_536)
        XCTAssertEqual(lut.data.count, 65_536)
        XCTAssertEqual(lut.data.first, 0)
        XCTAssertEqual(lut.data.last, 65_535)
    }

    func test_boundedReader_capsLUTPayloadRequestsToDeclaredEntries() throws {
        let cases: [(vr: DicomVR, bitsPerEntry: Int, value: DicomDataValue, expectedBytes: Int)] = [
            (.US, 16, .unsignedIntegers(Array(repeating: 1, count: 32)), 8),
            (.SS, 16, .signedIntegers(Array(repeating: -1, count: 32)), 8),
            (.OW, 8, .bytes(Data(repeating: 1, count: 64)), 8),
            (.OB, 8, .bytes(Data(repeating: 1, count: 64)), 4),
            (.OW, 16, .bytes(Data(repeating: 1, count: 64)), 8)
        ]

        for testCase in cases {
            let sequenceValue = try encodedVOILUTSequenceValue(
                descriptor: [4, 0, testCase.bitsPerEntry],
                dataVR: testCase.vr,
                dataValue: testCase.value
            )
            var requestedLUTDataLengths: [Int] = []

            let items = try DicomSequenceValueParser.parseItems(
                in: sequenceValue,
                valueOffset: 0,
                valueLength: sequenceValue.count,
                littleEndian: true,
                explicitVR: true,
                valueLengthLimit: DCMDecoder.voiLUTValueLengthLimit,
                valueDataReader: { data, range, tag, _ in
                    if tag == DicomTag.lutData.rawValue {
                        requestedLUTDataLengths.append(range.count)
                    }
                    return Data(data[range])
                }
            )

            XCTAssertEqual(requestedLUTDataLengths, [testCase.expectedBytes], "VR: \(testCase.vr)")
            let parsedElement = try XCTUnwrap(items.first?.dataSet.element(for: .lutData))
            switch parsedElement.value {
            case .unsignedIntegers(let values):
                XCTAssertEqual(values.count, 4)
            case .signedIntegers(let values):
                XCTAssertEqual(values.count, 4)
            case .bytes(let data):
                XCTAssertEqual(data.count, testCase.expectedBytes)
            default:
                XCTFail("Unexpected bounded LUT value for VR: \(testCase.vr)")
            }

            let undefinedLengthValue = sequenceValue + Data([0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
            requestedLUTDataLengths.removeAll()
            let bounds = try DicomSequenceValueParser.undefinedLengthSequenceBounds(
                in: undefinedLengthValue,
                valueOffset: 0,
                end: undefinedLengthValue.count,
                littleEndian: true,
                explicitVR: true,
                valueLengthLimit: DCMDecoder.voiLUTValueLengthLimit,
                valueDataReader: { data, range, tag, _ in
                    if tag == DicomTag.lutData.rawValue {
                        requestedLUTDataLengths.append(range.count)
                    }
                    return Data(data[range])
                }
            )
            XCTAssertEqual(bounds.valueLength, sequenceValue.count)
            XCTAssertEqual(requestedLUTDataLengths, [testCase.expectedBytes], "undefined VR: \(testCase.vr)")
        }
    }

    func test_objectWithoutVOILUTSequence_hasEmptyMetadataLUTs() throws {
        let url = try makeTemporaryDICOM()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = try awaitFrame(try DicomDecodedFrameReader(contentsOf: url))
        XCTAssertTrue(frame.metadata.voiLUTs.isEmpty)
    }

    // MARK: - Typed rejection, decode unharmed

    func test_shortDescriptor_isRejectedAsMalformed() throws {
        try assertRejected(
            item: DicomDataSet(elements: [
                us(.lutDescriptor, [4, 0]),
                us(.lutData, [0, 64, 128, 255])
            ]),
            as: .malformedDescriptor([4, 0])
        )
    }

    func test_missingDescriptor_isRejected() throws {
        try assertRejected(
            item: DicomDataSet(elements: [
                us(.lutData, [0, 64, 128, 255])
            ]),
            as: .missingDescriptor
        )
    }

    func test_missingData_isRejectedAsEmpty() throws {
        try assertRejected(
            item: DicomDataSet(elements: [
                us(.lutDescriptor, [4, 0, 8])
            ]),
            as: .emptyData
        )
    }

    func test_unsupportedBitsPerEntry_isRejected() throws {
        try assertRejected(
            item: DicomDataSet(elements: [
                us(.lutDescriptor, [4, 0, 32]),
                us(.lutData, [0, 64, 128, 255])
            ]),
            as: .unsupportedBitsPerEntry(32)
        )
    }

    func test_dataShorterThanDeclared_isRejectedAsShortfall() throws {
        try assertRejected(
            item: DicomDataSet(elements: [
                us(.lutDescriptor, [16, 0, 16]),
                us(.lutData, [0, 1, 2, 3])
            ]),
            as: .entryCountShortfall(declared: 16, actual: 4)
        )
    }

    func test_displayProfile_usesTheSameValidatedTablesAndKeepsTheValidWindowDefault() throws {
        let url = try makeTemporaryDICOM(extraElements: [
            ds(.windowCenter, ["2"]),
            ds(.windowWidth, ["4"]),
            sequence(.voiLUTSequence, [
                DicomDataSet(elements: [
                    us(.lutDescriptor, [4, 0, 32]),
                    us(.lutData, [0, 64, 128, 255])
                ]),
                DicomDataSet(elements: [
                    us(.lutDescriptor, [4, 0, 16]),
                    us(.lutData, [0, 1])
                ])
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let validation = decoder.validatedVOILookupTables()
        let profile = decoder.displayTransformProfile

        XCTAssertTrue(validation.accepted.isEmpty)
        XCTAssertEqual(validation.rejected, [
            .unsupportedBitsPerEntry(32),
            .entryCountShortfall(declared: 4, actual: 2)
        ])
        XCTAssertEqual(profile.voiLUTs, validation.accepted)
        XCTAssertEqual(profile.defaultSelection, .window(index: 0))
    }

    /// One bad item never drags down its valid sibling — accepted and
    /// rejected are reported side by side, and the metadata keeps the
    /// valid one.
    func test_mixedSequence_keepsTheValidItemAndNamesTheBadOne() throws {
        let url = try makeTemporaryDICOM(extraElements: [
            sequence(.voiLUTSequence, [
                DicomDataSet(elements: [
                    us(.lutDescriptor, [4, 0, 8]),
                    us(.lutData, [0, 64, 128, 255])
                ]),
                DicomDataSet(elements: [
                    us(.lutDescriptor, [4, 0]),
                    us(.lutData, [0, 64, 128, 255])
                ])
            ])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let result = decoder.validatedVOILookupTables()
        XCTAssertEqual(result.accepted.count, 1)
        XCTAssertEqual(result.rejected, [.malformedDescriptor([4, 0])])

        let frame = try awaitFrame(try DicomDecodedFrameReader(contentsOf: url))
        XCTAssertEqual(frame.metadata.voiLUTs.count, 1)
        XCTAssertEqual(frame.metadata.voiLUTs.first?.data, [0, 64, 128, 255])
    }

    private func assertRejected(
        item: DicomDataSet,
        as expected: DicomVOILUTValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = try makeTemporaryDICOM(extraElements: [
            sequence(.voiLUTSequence, [item])
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let result = decoder.validatedVOILookupTables()
        XCTAssertTrue(result.accepted.isEmpty, file: file, line: line)
        XCTAssertEqual(result.rejected, [expected], file: file, line: line)

        // The image itself still decodes — a broken VOI LUT is a display
        // hint gone wrong, not a broken image.
        let frame = try awaitFrame(try DicomDecodedFrameReader(contentsOf: url))
        XCTAssertTrue(frame.metadata.voiLUTs.isEmpty, file: file, line: line)
    }

    private func awaitFrame(_ reader: DicomDecodedFrameReader) throws -> DicomDecodedFrame {
        let expectation = expectation(description: "frame decoded")
        let outcome = DicomSynchronousResult<DicomDecodedFrame>()
        Task {
            do {
                outcome.resolve(.success(try await reader.frame(at: 0)))
            } catch {
                outcome.resolve(.failure(error))
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
        return try XCTUnwrap(outcome.get())
    }

    // MARK: - Fixture helpers (mirrors DicomDisplayTransformTests)

    private func makeTemporaryDICOM(
        pixelValues: [UInt16] = [0, 1, 2, 3],
        extraElements: [DicomDataElement] = []
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voi_lut_validation_\(UUID().uuidString).dcm")
        let dataSet = DicomDataSet(elements: [
            string(0x00080016, vr: .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "1.2.826.0.1.3680043.10.223.\(Int.random(in: 1...999999))"),
            string(.modality, vr: .CS, "CT"),
            us(.samplesPerPixel, [1]),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            us(.rows, [1]),
            us(.columns, [pixelValues.count]),
            us(.bitsAllocated, [16]),
            us(.bitsStored, [16]),
            us(.highBit, [15]),
            us(.pixelRepresentation, [0]),
            bytes(.pixelData, vr: .OW, Data(littleEndianBytes(values: pixelValues)))
        ] + extraElements)

        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        try data.write(to: url)
        return url
    }

    private func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private func encodedVOILUTSequenceValue(
        descriptor: [Int],
        dataVR: DicomVR,
        dataValue: DicomDataValue
    ) throws -> Data {
        let encoded = try DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: [
            sequence(.voiLUTSequence, [
                DicomDataSet(elements: [
                    us(.lutDescriptor, descriptor),
                    DicomDataElement(tag: DicomTag.lutData.rawValue, vr: dataVR, value: dataValue)
                ])
            ])
        ]))
        let explicitSequenceHeaderLength = 12
        return Data(encoded.dropFirst(explicitSequenceHeaderLength))
    }

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private func string(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    private func us(_ tag: DicomTag, _ values: [Int]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers(values.map(UInt.init)))
    }

    private func ss(_ tag: DicomTag, _ values: [Int]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .SS, value: .signedIntegers(values))
    }

    private func ds(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
    }

    private func bytes(_ tag: DicomTag, vr: DicomVR, _ value: Data) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .bytes(value))
    }

    private func littleEndianBytes(values: [UInt16]) -> [UInt8] {
        values.flatMap { value in
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
    }
}
