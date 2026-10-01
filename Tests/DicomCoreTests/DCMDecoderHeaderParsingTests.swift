import XCTest
@testable import DicomCore

final class DCMDecoderHeaderParsingTests: XCTestCase {
    func testUndefinedLengthSequenceBeforeDimensionsDoesNotSuppressDimensionHandlers() throws {
        let url = try makeDicomWithUndefinedSequenceBeforeDimensions(rows: 3, columns: 5)
        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.height, 3)
        XCTAssertEqual(decoder.width, 5)
        XCTAssertEqual(decoder.intValue(for: .rows), 3)
        XCTAssertEqual(decoder.intValue(for: .columns), 5)
    }

    func testCommandGroupLengthTagBeforeImageDataDoesNotTerminateHeaderParsing() throws {
        let url = try makeDicomWithUndefinedSequenceBeforeDimensions(
            rows: 3,
            columns: 5,
            includesCommandGroupLength: true
        )
        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertEqual(decoder.height, 3)
        XCTAssertEqual(decoder.width, 5)
        XCTAssertGreaterThan(decoder.offset, 0)
    }

    @MainActor
    func test_cancelledTask_completedHeaderParseSucceeds() async throws {
        let image = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Data([0, 0])))
        ])
        // Also exercise the no-Pixel-Data branch without evaluating the RT Dose DVH accessor (#2517).
        let structureSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomRTStructureSet.storageSOPClassUID]))
        ])
        for source in [image, structureSet] {
            let data = try DicomDataSetWriter.part10Data(from: source)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try DCMDecoder(data: data)
            }
            let decoder = try await task.value
            XCTAssertTrue(decoder.fileReadSucceeded)
            XCTAssertTrue(decoder.dicomFound)
            XCTAssertEqual(decoder.width, 1)
        }
    }

    @MainActor
    func test_cancelledDVHAccessor_discardsIncompleteHeader() async throws {
        let data = try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomRTDoseVolume.storageSOPClassUID])),
            DicomDataElement(tag: 0x30040050, vr: .SQ, value: .sequence([
                DicomSequenceItem(dataSet: DicomDataSet())
            ]))
        ]))
        let decoder = DCMDecoder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try decoder.loadDicomData(data)
        }
        do {
            try await task.value
            XCTFail("expected cancellation from the DVH sequence accessor")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(decoder.fileReadSucceeded)
        XCTAssertTrue(decoder.tagMetadataCache.isEmpty)
        XCTAssertTrue(decoder.dicomData.isEmpty)
    }

    @MainActor
    func test_cancelledSequenceScan_codecWorkflowPreservesCancellation() async throws {
        let data = try makeEncapsulatedDicomWithUndefinedSequence()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DicomCodecWorkflowEngine().inspect(data)
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation through makeDecoder")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func test_cancelledSequenceScan_deidentifierPreservesCancellation() async throws {
        let data = try makeEncapsulatedDicomWithUndefinedSequence()
        let deidentifier = try DicomDeidentifier(profile: .basic, session: DicomDeidentificationSession())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try deidentifier.apply(data)
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation through deidentification")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func test_cancelledSequenceScan_throwsBeforePixelData() async throws {
        let data = try makeEncapsulatedDicomWithUndefinedSequence()
        let decoder = DCMDecoder()
        decoder.dicomData = data
        let reader = DCMBinaryReader(data: data, littleEndian: true)
        decoder.reader = reader
        decoder.tagParser = DCMTagParser(data: data, dict: decoder.dict, binaryReader: reader)
        let sequenceHeader = Data([0x08, 0x00, 0x32, 0x10, 0x53, 0x51, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        let sequence = try XCTUnwrap(data.range(of: sequenceHeader))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try decoder.readFileInfoUnsafe()
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        // The scanner, rather than an earlier entry check, observed cancellation (#2517).
        XCTAssertEqual(decoder.location, sequence.upperBound)
        XCTAssertFalse(decoder.fileReadSucceeded)
        let reparsed = try DCMDecoder(data: data)
        XCTAssertNotNil(reparsed.encapsulatedPixelDataDescriptor)
        XCTAssertGreaterThan(reparsed.offset, 0)
    }

    @MainActor
    func test_cancelledLoad_discardsPartialMetadataAndAllowsRetry() async throws {
        let data = try makeEncapsulatedDicomWithUndefinedSequence()
        let decoder = DCMDecoder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try decoder.loadDicomData(data)
        }
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(decoder.fileReadSucceeded)
        XCTAssertFalse(decoder.dicomFound)
        XCTAssertTrue(decoder.dicomFileName.isEmpty)
        XCTAssertTrue(decoder.dicomData.isEmpty)
        XCTAssertTrue(decoder.dicomInfoDict.isEmpty)
        XCTAssertTrue(decoder.cachedInfo.isEmpty)
        XCTAssertTrue(decoder.tagMetadataCache.isEmpty)
        XCTAssertNil(decoder.reader)
        XCTAssertNil(decoder.tagParser)
        XCTAssertNil(decoder.encapsulatedPixelDataDescriptor)
        XCTAssertEqual(decoder.offset, 0)
        XCTAssertEqual(decoder.width, 0)
        XCTAssertNil(decoder.imagePosition)
        try decoder.loadDicomData(data)
        XCTAssertTrue(decoder.fileReadSucceeded)
        XCTAssertNotNil(decoder.encapsulatedPixelDataDescriptor)
        XCTAssertGreaterThan(decoder.offset, 0)
    }

    @MainActor
    func test_cancelledInitializers_preserveCancellationError() async throws {
        let data = try makeEncapsulatedDicomWithUndefinedSequence()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // Synchronous closures disambiguate the sync and async file initializers.
        let loaders: [@Sendable () throws -> DCMDecoder] = [
            { try DCMDecoder(data: data) },
            { try DCMDecoder(contentsOf: url) },
            { try DCMDecoder(contentsOfFile: url.path) }
        ]
        for load in loaders {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try load()
            }
            do {
                _ = try await task.value
                XCTFail("expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
        for useURL in [true, false] {
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                if useURL { return try await DCMDecoder(contentsOf: url) }
                return try await DCMDecoder(contentsOfFile: url.path)
            }
            do {
                _ = try await task.value
                XCTFail("expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
    }

    private func makeEncapsulatedDicomWithUndefinedSequence() throws -> Data {
        var data = Data()
        appendTag(0x00081032, to: &data)
        data.append(contentsOf: [0x53, 0x51, 0, 0])
        appendUInt32(UInt32.max, to: &data)
        let item = try DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: [
            DicomDataElement(tag: 0x00080100, vr: .SH, value: .strings(["TEST"]))
        ]))
        appendTag(0xFFFEE000, to: &data)
        appendUInt32(UInt32(item.count), to: &data)
        data.append(item)
        appendTag(0xFFFEE0DD, to: &data)
        appendUInt32(0, to: &data)
        data.append(try DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16]))
        ])))
        appendTag(DicomTag.pixelData.rawValue, to: &data)
        data.append(contentsOf: [0x4F, 0x42, 0, 0])
        appendUInt32(UInt32.max, to: &data)
        appendTag(0xFFFEE000, to: &data)
        appendUInt32(0, to: &data)
        appendTag(0xFFFEE000, to: &data)
        appendUInt32(4, to: &data)
        data.append(contentsOf: [0xFF, 0x4F, 0xFF, 0xD9])
        appendTag(0xFFFEE0DD, to: &data)
        appendUInt32(0, to: &data)
        return try DicomDataSetWriter.part10Data(
            fromEncodedDataSet: data, transferSyntax: .jpeg2000,
            mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            mediaStorageSOPInstanceUID: "2.25.2517")
    }

    private func makeDicomWithUndefinedSequenceBeforeDimensions(
        rows: UInt16,
        columns: UInt16,
        includesCommandGroupLength: Bool = false
    ) throws -> URL {
        var data = Data(repeating: 0, count: 128)
        data.append(contentsOf: "DICM".utf8)

        appendElement(DicomTag.transferSyntaxUID.rawValue, vr: "UI", value: paddedUID("1.2.840.10008.1.2.1"), to: &data)
        if includesCommandGroupLength {
            appendElement(0x00000000, vr: "UL", value: Data(repeating: 0, count: 4), to: &data)
        }
        appendUndefinedDerivationCodeSequence(to: &data)
        appendElement(DicomTag.samplesPerPixel.rawValue, vr: "US", value: uint16(rows == 0 ? 0 : 1), to: &data)
        appendElement(DicomTag.photometricInterpretation.rawValue, vr: "CS", value: paddedASCII("MONOCHROME2"), to: &data)
        appendElement(DicomTag.rows.rawValue, vr: "US", value: uint16(rows), to: &data)
        appendElement(DicomTag.columns.rawValue, vr: "US", value: uint16(columns), to: &data)
        appendElement(DicomTag.bitsAllocated.rawValue, vr: "US", value: uint16(16), to: &data)
        appendElement(DicomTag.pixelRepresentation.rawValue, vr: "US", value: uint16(0), to: &data)

        let pixelCount = Int(rows) * Int(columns)
        appendElement(DicomTag.pixelData.rawValue, vr: "OW", value: Data(repeating: 0, count: pixelCount * 2), to: &data)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dcm")
        try data.write(to: url)
        return url
    }

    private func appendUndefinedDerivationCodeSequence(to data: inout Data) {
        appendTag(0x00089215, to: &data)
        data.append(contentsOf: "SQ".utf8)
        data.append(contentsOf: [0, 0])
        appendUInt32(UInt32.max, to: &data)

        appendTag(0xFFFEE000, to: &data)
        appendUInt32(UInt32.max, to: &data)
        appendElement(0x00080100, vr: "SH", value: paddedASCII("121327"), to: &data)
        appendElement(0x00080102, vr: "SH", value: paddedASCII("DCM"), to: &data)
        appendElement(0x00080104, vr: "LO", value: paddedASCII("Full fidelity image"), to: &data)
        appendTag(0xFFFEE00D, to: &data)
        appendUInt32(0, to: &data)

        appendTag(0xFFFEE0DD, to: &data)
        appendUInt32(0, to: &data)
    }

    private func appendElement(_ tag: Int, vr: String, value: Data, to data: inout Data) {
        appendTag(tag, to: &data)
        data.append(contentsOf: vr.utf8)
        if ["OB", "OD", "OF", "OW", "OV", "SQ", "UN", "UR", "UT"].contains(vr) {
            data.append(contentsOf: [0, 0])
            appendUInt32(UInt32(value.count), to: &data)
        } else {
            appendUInt16(UInt16(value.count), to: &data)
        }
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

    private func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private func paddedASCII(_ value: String) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 != 0 {
            data.append(0x20)
        }
        return data
    }

    private func paddedUID(_ value: String) -> Data {
        var data = Data(value.utf8)
        if data.count % 2 != 0 {
            data.append(0)
        }
        return data
    }
}
