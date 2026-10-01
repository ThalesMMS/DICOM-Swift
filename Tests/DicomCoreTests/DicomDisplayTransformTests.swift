import XCTest
@testable import DicomCore

final class DicomDisplayTransformTests: XCTestCase {
    func test_storedPixelValues_enforcesOutputByteBudget() throws {
        let url = try makeTemporaryDICOM(pixelValues: [0, 100, 1024, 2048], extraElements: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)
        let requiredBytes = 4 * MemoryLayout<Int>.stride
        XCTAssertNil(decoder.storedPixelValues(maximumOutputBytes: requiredBytes - 1))
        XCTAssertNil(decoder.storedPixelValues(maximumOutputBytes: -1))
        XCTAssertEqual(decoder.storedPixelValues(maximumOutputBytes: requiredBytes), [0, 100, 1024, 2048])
        XCTAssertNil(decoder.storedPixelValues(frame: 1, maximumOutputBytes: requiredBytes))
        XCTAssertNil(decoder.storedPixelValues(sample: 1, maximumOutputBytes: requiredBytes))
    }

    func test_eightBitLookupTable_acceptsByteAndWordEntries() throws {
        for (bytes, littleEndian): ([UInt8], Bool) in [
            ([1, 64, 128, 255], true), ([1, 0, 64, 0, 128, 0, 255, 0], true),
            ([0, 1, 0, 64, 0, 128, 0, 255], false)
        ] {
            let dataSet = DicomDataSet(elements: [us(.lutDescriptor, [4, 0, 8]), self.bytes(.lutData, vr: .OW, Data(bytes))])
            let table = try XCTUnwrap(DicomLookupTableParser.lookupTable(from: dataSet, typeTag: nil, littleEndian: littleEndian))
            XCTAssertEqual(table.data, [1, 64, 128, 255])
        }
    }

    func test_presentationTable_clampsEntriesToDescriptorBitDepth() throws {
        let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 4, firstMappedValue: 0, bitsPerEntry: 8))
        let table = DicomLookupTable(descriptor: descriptor, explanation: nil, lutType: nil,
                                    data: [0, 128, 256, UInt16.max])
        let profile = DicomDisplayTransformProfile(presentationLUT: table)
        let selection = DicomDisplaySelection.customWindow(WindowSettings(center: 2, width: 4))
        XCTAssertEqual([0.0, 1, 2, 3].map {
            profile.displayValue(forStoredPixelValue: $0, selection: selection)
        }, [0, 128, 255, 255])
    }

    func test_linearWindowAndInversion_quantizesExactBytes() {
        let selection = DicomDisplaySelection.customWindow(WindowSettings(center: 2, width: 4))
        let profile = DicomDisplayTransformProfile()
        let inverse = DicomDisplayTransformProfile(presentationLUTShape: .inverse)
        // lower = 0, denominator = 3: floor([0, 1/3, 2/3, 1] * 255).
        XCTAssertEqual([0.0, 1, 2, 3].map { profile.displayValue(forStoredPixelValue: $0, selection: selection) },
                       [0, 85, 170, 255])
        XCTAssertEqual(inverse.displayValue(forStoredPixelValue: 0.5, selection: selection), 213)
        let threshold = DicomDisplaySelection.customWindow(WindowSettings(center: 2, width: 1))
        XCTAssertEqual(profile.displayValue(forStoredPixelValue: 1.5, selection: threshold), 0)
        XCTAssertEqual(profile.displayValue(forStoredPixelValue: 1.5001, selection: threshold), 255)
    }

    func test_presentationTable_appliesAfterMonochromeInversionAndIgnoresShape() throws {
        let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 4, firstMappedValue: 7, bitsPerEntry: 8))
        let table = DicomLookupTable(descriptor: descriptor, explanation: "Presentation", lutType: nil,
                                    data: [0, 32, 128, 255])
        let profile = DicomDisplayTransformProfile(presentationLUTShape: .inverse,
                                                   photometricInterpretation: "MONOCHROME1", presentationLUT: table)
        let selection = DicomDisplaySelection.customWindow(WindowSettings(center: 2, width: 4))
        XCTAssertEqual([0.0, 1, 2, 3].map { profile.displayValue(forStoredPixelValue: $0, selection: selection) },
                       [255, 128, 32, 0])
    }

    func test_presentationTable_indexesFullVOIRangeAndTruncatesOutput() throws {
        let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 4, firstMappedValue: 7, bitsPerEntry: 16))
        let table = DicomLookupTable(descriptor: descriptor, explanation: nil, lutType: nil,
                                    data: [0, 10000, 40000, 65535])
        let selection = DicomDisplaySelection.customWindow(WindowSettings(center: 2, width: 4))
        for (photometric, expected): (String, [UInt8]) in [
            ("MONOCHROME2", [0, 38, 155, 255, 255]),
            ("MONOCHROME1", [255, 255, 155, 38, 0])
        ] {
            let profile = DicomDisplayTransformProfile(presentationLUTShape: .inverse,
                photometricInterpretation: photometric, presentationLUT: table)
            XCTAssertEqual([0.0, 0.5, 1.5, 2.5, 3].map {
                profile.displayValue(forStoredPixelValue: $0, selection: selection)
            }, expected.map(Optional.some))
        }
    }

    func test_presentationTable_preservesAdjacentTwelveBitInputs() throws {
        let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 4096, firstMappedValue: 0, bitsPerEntry: 8))
        let table = DicomLookupTable(descriptor: descriptor, explanation: nil, lutType: nil,
                                    data: (0..<4096).map { $0.isMultiple(of: 2) ? 0 : 255 })
        let profile = DicomDisplayTransformProfile(presentationLUT: table)
        let selection = DicomDisplaySelection.customWindow(WindowSettings(center: 2048, width: 4096))
        XCTAssertEqual([1000.0, 1001, 1002, 1003].map {
            profile.displayValue(forStoredPixelValue: $0, selection: selection)
        }, [0, 255, 0, 255])
    }

    func testRawAndModalityValuesUseDecoderDisplayProfile() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [0, 100, 1024, 2048],
            extraElements: [
                ds(.rescaleIntercept, ["-1024"]),
                ds(.rescaleSlope, ["1"]),
                string(.rescaleType, vr: .LO, "HU")
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let profile = decoder.displayTransformProfile

        XCTAssertEqual(decoder.storedPixelValue(at: 0), 0)
        XCTAssertEqual(decoder.storedPixelValue(at: 2), 1024)
        XCTAssertEqual(decoder.modalityPixelValue(at: 2), 0)
        XCTAssertEqual(profile.rescaleParameters, RescaleParameters(intercept: -1024, slope: 1))
        XCTAssertEqual(profile.rescaleType, "HU")
        XCTAssertEqual(
            decoder.calculatePercentileWindow(lower: 0, upper: 1),
            WindowSettings(center: 0, width: 2048)
        )
        XCTAssertTrue(decoder.pixelsNotLoaded)
    }

    func testStoredModalityAndPercentileValuesUsePlanarRGBLayout() throws {
        let url = try makeTemporaryRGBDICOM(
            pixelBytes: Data([10, 20, 30, 40, 50, 60]),
            extraElements: [
                ds(.rescaleIntercept, ["1"]),
                ds(.rescaleSlope, ["2"])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.storedPixelValue(at: 0, sample: 0), 10)
        XCTAssertEqual(decoder.storedPixelValue(at: 0, sample: 1), 30)
        XCTAssertEqual(decoder.storedPixelValue(at: 0, sample: 2), 50)
        XCTAssertEqual(decoder.storedPixelValue(at: 1, sample: 0), 20)
        XCTAssertEqual(decoder.storedPixelValue(at: 1, sample: 1), 40)
        XCTAssertEqual(decoder.storedPixelValue(at: 1, sample: 2), 60)
        XCTAssertEqual(decoder.modalityPixelValue(at: 0, sample: 1), 61)
        XCTAssertEqual(
            decoder.calculatePercentileWindow(lower: 0, upper: 1),
            WindowSettings(center: 31, width: 20)
        )
    }

    func testMultipleWindowsArePairedWithExplanations() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [0],
            extraElements: [
                ds(.windowCenter, ["40", "80"]),
                ds(.windowWidth, ["400", "2000"]),
                string(.windowCenterWidthExplanation, vr: .LO, ["Soft Tissue", "Lung"])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let profile = decoder.displayTransformProfile

        XCTAssertEqual(decoder.windowSettingsV2, WindowSettings(center: 80, width: 2000))
        XCTAssertEqual(decoder.info(for: .windowCenter), "40\\80")
        XCTAssertEqual(profile.windows.count, 2)
        XCTAssertEqual(profile.windows[0].settings, WindowSettings(center: 40, width: 400))
        XCTAssertEqual(profile.windows[0].explanation, "Soft Tissue")
        XCTAssertEqual(profile.windows[1].settings, WindowSettings(center: 80, width: 2000))
        XCTAssertEqual(profile.windows[1].explanation, "Lung")
    }

    func testVOILUTSequenceAppliesDisplaySelection() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [0, 1, 2, 3],
            extraElements: [
                sequence(.voiLUTSequence, [
                    DicomDataSet(elements: [
                        us(.lutDescriptor, [4, 0, 8]),
                        string(.lutExplanation, vr: .LO, "VOI ramp"),
                        us(.lutData, [0, 64, 128, 255])
                    ])
                ])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let profile = decoder.displayTransformProfile

        XCTAssertEqual(profile.voiLUTs.count, 1)
        XCTAssertEqual(profile.voiLUTs[0].explanation, "VOI ramp")
        XCTAssertEqual(profile.displayValue(forStoredPixelValue: 0, selection: .voiLUT(index: 0)), 0)
        XCTAssertEqual(profile.displayValue(forStoredPixelValue: 2, selection: .voiLUT(index: 0)), 128)
        XCTAssertEqual(profile.displayValue(forStoredPixelValue: 3, selection: .voiLUT(index: 0)), 255)
    }

    func testMonochromeAndPresentationShapeInvertDisplayValue() throws {
        let monochromeURL = try makeTemporaryDICOM(
            pixelValues: [0, 50, 100],
            photometricInterpretation: "MONOCHROME1",
            extraElements: [
                ds(.windowCenter, ["50"]),
                ds(.windowWidth, ["100"]),
                string(.presentationLUTShape, vr: .CS, "IDENTITY")
            ]
        )
        defer { try? FileManager.default.removeItem(at: monochromeURL) }

        let monochromeProfile = try DCMDecoder(contentsOf: monochromeURL).displayTransformProfile
        XCTAssertTrue(monochromeProfile.isMonochrome1)
        XCTAssertTrue(monochromeProfile.isPresentationInverted)
        XCTAssertEqual(monochromeProfile.presentationLUTShape, .identity)
        XCTAssertEqual(monochromeProfile.displayValue(forStoredPixelValue: 0, selection: .window(index: 0)), 255)
        XCTAssertEqual(monochromeProfile.displayValue(forStoredPixelValue: 100, selection: .window(index: 0)), 0)

        let inverseURL = try makeTemporaryDICOM(
            pixelValues: [0, 100],
            extraElements: [
                ds(.windowCenter, ["50"]),
                ds(.windowWidth, ["100"]),
                string(.presentationLUTShape, vr: .CS, "INVERSE")
            ]
        )
        defer { try? FileManager.default.removeItem(at: inverseURL) }

        let inverseProfile = try DCMDecoder(contentsOf: inverseURL).displayTransformProfile
        XCTAssertEqual(inverseProfile.presentationLUTShape, .inverse)
        XCTAssertTrue(inverseProfile.isPresentationInverted)
        XCTAssertEqual(inverseProfile.displayValue(forStoredPixelValue: 0, selection: .window(index: 0)), 255)
    }

    private func makeTemporaryDICOM(
        pixelValues: [UInt16],
        photometricInterpretation: String = "MONOCHROME2",
        extraElements: [DicomDataElement] = []
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("display_transform_\(UUID().uuidString).dcm")
        let dataSet = DicomDataSet(elements: [
            string(0x00080016, vr: .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "1.2.826.0.1.3680043.10.222.\(Int.random(in: 1...999999))"),
            string(.modality, vr: .CS, "CT"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, photometricInterpretation),
            us(.rows, 1),
            us(.columns, pixelValues.count),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            bytes(.pixelData, vr: .OW, Data(littleEndianBytes(values: pixelValues)))
        ] + extraElements)

        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        try data.write(to: url)
        return url
    }

    private func makeTemporaryRGBDICOM(
        pixelBytes: Data,
        extraElements: [DicomDataElement] = []
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("display_transform_rgb_\(UUID().uuidString).dcm")
        let dataSet = DicomDataSet(elements: [
            string(0x00080016, vr: .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "1.2.826.0.1.3680043.10.222.\(Int.random(in: 1...999999))"),
            string(.modality, vr: .CS, "OT"),
            us(.samplesPerPixel, 3),
            string(.photometricInterpretation, vr: .CS, "RGB"),
            us(.planarConfiguration, 1),
            us(.rows, 1),
            us(.columns, 2),
            us(.bitsAllocated, 8),
            us(.bitsStored, 8),
            us(.highBit, 7),
            us(.pixelRepresentation, 0),
            bytes(.pixelData, vr: .OB, pixelBytes)
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

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        string(tag.rawValue, vr: vr, value)
    }

    private func string(_ tag: DicomTag, vr: DicomVR, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings(values))
    }

    private func string(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    private func ds(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
    }

    private func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        us(tag, [value])
    }

    private func us(_ tag: DicomTag, _ values: [Int]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers(values.map(UInt.init)))
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
