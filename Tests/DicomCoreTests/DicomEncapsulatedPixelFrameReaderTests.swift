//
//  DicomEncapsulatedPixelFrameReaderTests.swift
//  DicomCoreTests
//
//  Fixture-backed coverage for the codec-agnostic encapsulated frame
//  reader (issue #1226): JPEG Baseline, JPEG Lossless, JPEG 2000 and RLE
//  files, empty-BOT fallback, Extended Offset Table mapping, multi-fragment
//  frames, and NumberOfFrames validation — never decoding the payloads.
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomEncapsulatedPixelFrameReaderTests: XCTestCase {
    // MARK: - Committed fixture coverage (codec payloads untouched)

    /// The committed JPEG Baseline fixture stores its codestream with a
    /// defined length (no item sequence), so it is typed `.notEncapsulated`;
    /// re-wrapping the same real codestream as encapsulated Pixel Data must
    /// round-trip the JPEG bytes through the reader untouched.
    func testReaderExtractsReEncapsulatedCommittedJPEGBaselineCodestream() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("Compressed/jpeg_baseline_synthetic.dcm")
        let definedLengthDecoder = try DCMDecoder(contentsOf: url)
        XCTAssertThrowsError(try definedLengthDecoder.makeEncapsulatedPixelFrameReader()) { error in
            XCTAssertEqual(
                error as? DicomEncapsulatedPixelFrameReader.ReaderError,
                .notEncapsulated,
                "defined-length compressed Pixel Data is not encapsulated"
            )
        }

        let codestream = try Self.jpegCodestream(inFixtureAt: url)
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegBaseline,
            fragments: [codestream],
            declaredFrames: 1
        )
        let reader = try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()

        XCTAssertEqual(reader.frameCount, 1)
        try reader.validateDeclaredFrameCount()
        XCTAssertEqual(try reader.frameData(at: 0), codestream, "JPEG codestream must be preserved, not decoded")
    }

    func testReaderExtractsFrameFromCommittedJPEGLosslessParityFixture() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("DecoderParity/jpeg_lossless_sv1_parity.dcm")
        let decoder = try DCMDecoder(contentsOf: url)
        let reader = try decoder.makeEncapsulatedPixelFrameReader()

        XCTAssertEqual(reader.frameCount, 1)
        try reader.validateDeclaredFrameCount()
        let payload = try reader.frameData(at: 0)
        XCTAssertEqual(payload.prefix(2), Data([0xFF, 0xD8]))
        XCTAssertEqual(payload.suffix(2), Data([0xFF, 0xD9]))
    }

    func testReaderExtractsFramesFromCommittedRLEParityFixture() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("DecoderParity/rle_parity.dcm")
        let decoder = try DCMDecoder(contentsOf: url)
        let reader = try decoder.makeEncapsulatedPixelFrameReader()

        XCTAssertEqual(reader.frameCount, 1)
        let payload = try reader.frameData(at: 0)
        // RLE header: one segment at offset 64.
        XCTAssertEqual(payload.prefix(4), Data([0x01, 0x00, 0x00, 0x00]))
    }

    /// Frame extraction is codec-agnostic: a JPEG 2000 transfer syntax with
    /// an opaque codestream payload is sliced without any J2K decoding.
    func testReaderExtractsOpaqueJPEG2000PayloadWithoutDecoding() throws {
        let opaqueCodestream = Data([0xFF, 0x4F, 0xFF, 0x51] + Array(repeating: 0xAB, count: 60)) // SOC/SIZ markers + filler
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: [opaqueCodestream],
            declaredFrames: 1
        )
        let decoder = try Self.decoder(for: file)
        let reader = try decoder.makeEncapsulatedPixelFrameReader()

        XCTAssertEqual(reader.frameCount, 1)
        XCTAssertEqual(try reader.frameData(at: 0), opaqueCodestream)
    }

    // MARK: - Offset table behaviors

    func testEmptyBasicOffsetTableFallsBackToFragmentMapping() throws {
        let frames = [Data([0x01, 0x02]), Data([0x03, 0x04]), Data([0x05, 0x06])]
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: frames,
            declaredFrames: 3,
            includeBasicOffsetTable: false
        )
        let reader = try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()

        XCTAssertEqual(reader.frameCount, 3)
        XCTAssertTrue(reader.diagnostics.contains { $0.message.contains("Basic Offset Table is empty") })
        for (index, expected) in frames.enumerated() {
            XCTAssertEqual(try reader.frameData(at: index), expected)
        }
    }

    func testOneFrameManyFragmentsAssemblesSinglePayload() throws {
        let fragments = [Data([0xAA, 0xBB]), Data([0xCC, 0xDD]), Data([0xEE, 0xFF])]
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: fragments,
            declaredFrames: 1,
            includeBasicOffsetTable: false
        )
        let reader = try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()

        XCTAssertEqual(reader.frameCount, 1)
        let frame = try reader.frame(at: 0)
        XCTAssertEqual(frame.fragmentIndexes, [0, 1, 2])
        XCTAssertEqual(frame.data, Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
    }

    func testExtendedOffsetTableMapsMultiFragmentFrames() throws {
        // Two frames, three fragments: frame 0 = fragments 0+1, frame 1 = fragment 2.
        let fragments = [Data([0x10, 0x11]), Data([0x12, 0x13]), Data([0x20, 0x21])]
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: fragments,
            declaredFrames: 2,
            includeBasicOffsetTable: false,
            extendedOffsetTableFrameStartFragmentIndexes: [0, 2]
        )
        let reader = try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()

        XCTAssertEqual(reader.frameCount, 2)
        try reader.validateDeclaredFrameCount()
        XCTAssertEqual(try reader.frameData(at: 0), Data([0x10, 0x11, 0x12, 0x13]))
        XCTAssertEqual(try reader.frameData(at: 1), Data([0x20, 0x21]))
    }

    // MARK: - Frames delimited by codestream markers (issue #2814)

    func testFragmentsWithoutOffsetTable_groupIntoFramesByJPEGMarkers() throws {
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegBaseline,
            fragments: [Data([0xFF, 0xD8, 0x01, 0x02]), Data([0x03, 0x04]), Data([0x05, 0xFF, 0xD9]),
                        Data([0xFF, 0xD8, 0x06]), Data([0x07, 0xFF, 0xD9, 0x00])],
            declaredFrames: 2,
            includeBasicOffsetTable: false
        )
        let reader = try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()
        try reader.validateDeclaredFrameCount()
        XCTAssertEqual(try reader.frameData(at: 0), Data([0xFF, 0xD8, 0x01, 0x02, 0x03, 0x04, 0x05, 0xFF, 0xD9]))
        XCTAssertEqual(try reader.frameData(at: 1), Data([0xFF, 0xD8, 0x06, 0x07, 0xFF, 0xD9, 0x00]))
    }

    func testJPEG2000FragmentOpeningWithSOCMidFrame_staysInItsFrame() throws {
        // The second fragment of frame 0 happens to open with FF4F, but the fragment before it does not close
        // with EOC, so it is not a new frame.
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: [Data([0xFF, 0x4F, 0xFF, 0x51]), Data([0xFF, 0x4F, 0x10]), Data([0x11, 0xFF, 0xD9]),
                        Data([0xFF, 0x4F, 0xFF, 0x51, 0xFF, 0xD9]),
                        Data([0xFF, 0x4F, 0x20]), Data([0xFF, 0xD9])],
            declaredFrames: 3,
            includeBasicOffsetTable: false
        )
        let reader = try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()
        XCTAssertEqual(reader.frameCount, 3)
        XCTAssertEqual(try reader.frameData(at: 0), Data([0xFF, 0x4F, 0xFF, 0x51, 0xFF, 0x4F, 0x10, 0x11, 0xFF, 0xD9]))
        XCTAssertEqual(try reader.frameData(at: 1), Data([0xFF, 0x4F, 0xFF, 0x51, 0xFF, 0xD9]))
        XCTAssertEqual(try reader.frameData(at: 2), Data([0xFF, 0x4F, 0x20, 0xFF, 0xD9]))
    }

    func testMarkersDelimitingAnotherFrameCount_areRefusedTyped() throws {
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegBaseline,
            fragments: [Data([0xFF, 0xD8, 0x01]), Data([0xFF, 0xD9]), Data([0xFF, 0xD8, 0x02]), Data([0xFF, 0xD9])],
            declaredFrames: 3,
            includeBasicOffsetTable: false
        )
        XCTAssertThrowsError(try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()) { error in
            guard case DicomEncapsulatedPixelFrameReader.ReaderError.unusableFrameMap(let diagnostics) = error else {
                return XCTFail("expected unusableFrameMap, got \(error)")
            }
            XCTAssertTrue(diagnostics.contains { $0.message.contains("Codestream markers delimit 2 frame(s)") })
        }
    }

    func testRLEFragmentsWithoutOffsetTable_areNotGrouped() throws {
        let header = Data([0x01, 0x00, 0x00, 0x00, 0x40]) + Data(count: 59)
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .rleLossless,
            fragments: [header, Data([0x00, 0x05]), header],
            declaredFrames: 2,
            includeBasicOffsetTable: false
        )
        XCTAssertThrowsError(try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()) { error in
            guard case DicomEncapsulatedPixelFrameReader.ReaderError.unusableFrameMap(let diagnostics) = error else {
                return XCTFail("expected unusableFrameMap, got \(error)")
            }
            XCTAssertTrue(diagnostics.contains { $0.message.contains("Cannot safely map") })
        }
    }

    /// Real codestreams from gdcmData whose single frame spans several fragments, repeated as a three-frame
    /// object with neither offset table: every frame decodes like the original (opt-in, `ISIS_GDCM_DATA_DIR`).
    func testGDCMCorpusCodestreamsSplitAcrossFragments_decodeFrameByFrameWithoutOffsetTable() throws {
        guard let root = ProcessInfo.processInfo.environment["ISIS_GDCM_DATA_DIR"], !root.isEmpty else {
            throw XCTSkip("ISIS_GDCM_DATA_DIR is not set")
        }
        let names = ["GE_RHAPSODE-16-MONO2-JPEG-Fragments.dcm", "D_CLUNIE_CT1_JPLL.dcm", "D_CLUNIE_CT1_JLSL.dcm",
                     "D_CLUNIE_CT1_J2KR.dcm"]
        for name in names {
            let url = URL(fileURLWithPath: root).appendingPathComponent(name)
            let source = try DCMDecoder(contentsOf: url)
            let fileData = try Data(contentsOf: url)
            let fragments = try source.makeEncapsulatedPixelFrameReader().descriptor.fragments.map {
                Data(fileData[(fileData.startIndex + $0.valueRange.lowerBound)..<(fileData.startIndex + $0.valueRange.upperBound)])
            }
            XCTAssertGreaterThan(fragments.count, 1, name)
            let syntax = try XCTUnwrap(DicomTransferSyntax(uid: source.transferSyntaxUID), name)
            let bitsStored = source.intValue(for: .bitsStored) ?? source.bitDepth
            let file = try EncapsulatedFixtureFactory.makeFile(
                transferSyntax: syntax, fragments: fragments + fragments + fragments, declaredFrames: 3,
                includeBasicOffsetTable: false, rows: source.height, columns: source.width,
                bitsAllocated: source.bitDepth, bitsStored: bitsStored, highBit: bitsStored - 1,
                pixelRepresentation: source.pixelRepresentationTagValue
            )
            let decoder = try Self.decoder(for: file)
            XCTAssertEqual(try decoder.makeEncapsulatedPixelFrameReader().frameCount, 3, name)
            let reference = try DicomDecodedFrameReader(decoder: source).frame(at: 0).pixels
            for index in 0 ..< 3 {
                XCTAssertEqual(try DicomDecodedFrameReader(decoder: decoder).frame(at: index).pixels, reference,
                               "\(name) frame \(index)")
            }
        }
    }

    // MARK: - NumberOfFrames validation and deterministic errors

    func testDeclaredFrameCountLargerThanFragmentsIsUnusable() throws {
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: [Data([0x01]), Data([0x02])],
            declaredFrames: 5,
            includeBasicOffsetTable: false
        )
        let decoder = try Self.decoder(for: file)

        XCTAssertThrowsError(try decoder.makeEncapsulatedPixelFrameReader()) { error in
            guard case DicomEncapsulatedPixelFrameReader.ReaderError.unusableFrameMap(let diagnostics) = error else {
                return XCTFail("expected unusableFrameMap, got \(error)")
            }
            XCTAssertTrue(diagnostics.contains { $0.message.contains("Cannot safely map") })
        }
    }

    func testAbsentNumberOfFramesDefaultsToSingleFrameAndValidates() throws {
        let fragments = [Data([0x01, 0x02]), Data([0x03, 0x04])]
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: fragments,
            declaredFrames: nil,
            includeBasicOffsetTable: false
        )
        let reader = try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()

        XCTAssertEqual(reader.declaredNumberOfFrames, 1)
        XCTAssertEqual(reader.frameCount, 1, "single-frame default assembles all fragments into one payload")
        try reader.validateDeclaredFrameCount()
        XCTAssertEqual(try reader.frameData(at: 0), Data([0x01, 0x02, 0x03, 0x04]))
    }

    func testFrameIndexOutOfRangeIsTyped() throws {
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Lossless,
            fragments: [Data([0x01, 0x02])],
            declaredFrames: 1
        )
        let reader = try Self.decoder(for: file).makeEncapsulatedPixelFrameReader()

        XCTAssertThrowsError(try reader.frame(at: 3)) { error in
            XCTAssertEqual(
                error as? DicomEncapsulatedPixelFrameReader.ReaderError,
                .frameIndexOutOfRange(index: 3, frameCount: 1)
            )
        }
    }

    func testNativeFileIsTypedNotEncapsulated() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("CT/ct_synthetic.dcm")
        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertThrowsError(try decoder.makeEncapsulatedPixelFrameReader()) { error in
            XCTAssertEqual(
                error as? DicomEncapsulatedPixelFrameReader.ReaderError,
                .notEncapsulated
            )
        }
    }

    // MARK: - Helpers

    private static func decoder(for fileData: Data) throws -> DCMDecoder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-reader-\(UUID().uuidString).dcm")
        try fileData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    /// Slices the JPEG payload out of a defined-length (7FE0,0010) OB
    /// element so it can be re-wrapped as encapsulated Pixel Data.
    private static func jpegCodestream(inFixtureAt url: URL) throws -> Data {
        struct MissingPixelData: Error {}
        let fileData = try Data(contentsOf: url)
        let pixelDataElementStart = Data([0xE0, 0x7F, 0x10, 0x00, 0x4F, 0x42, 0x00, 0x00])
        guard let tagRange = fileData.range(of: pixelDataElementStart) else {
            throw MissingPixelData()
        }
        let lengthStart = tagRange.upperBound
        guard lengthStart + 4 <= fileData.count else { throw MissingPixelData() }
        let lengthBytes = [UInt8](fileData[lengthStart..<(lengthStart + 4)])
        let length = Int(lengthBytes[0]) | Int(lengthBytes[1]) << 8
            | Int(lengthBytes[2]) << 16 | Int(lengthBytes[3]) << 24
        let payloadStart = lengthStart + 4
        guard payloadStart + length <= fileData.count else { throw MissingPixelData() }
        return Data(fileData[payloadStart..<(payloadStart + length)])
    }

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
}

/// Deterministic encapsulated Part 10 factory shared by the frame-reader
/// tests: arbitrary opaque fragments, optional BOT/EOT, optional declared
/// NumberOfFrames.
enum EncapsulatedFixtureFactory {
    static func makeFile(
        transferSyntax: DicomTransferSyntax,
        fragments: [Data],
        declaredFrames: Int?,
        includeBasicOffsetTable: Bool = true,
        extendedOffsetTableFrameStartFragmentIndexes: [Int]? = nil,
        rows: Int = 2,
        columns: Int = 2,
        bitsAllocated: Int = 8,
        bitsStored: Int = 8,
        highBit: Int = 7,
        samplesPerPixel: Int = 1,
        photometricInterpretation: String = "MONOCHROME2",
        pixelRepresentation: Int = 0
    ) throws -> Data {
        try DicomDataSetWriter.part10Data(
            from: makeDataSet(
                transferSyntax: transferSyntax,
                fragments: fragments,
                declaredFrames: declaredFrames,
                includeBasicOffsetTable: includeBasicOffsetTable,
                extendedOffsetTableFrameStartFragmentIndexes: extendedOffsetTableFrameStartFragmentIndexes,
                rows: rows,
                columns: columns,
                bitsAllocated: bitsAllocated,
                bitsStored: bitsStored,
                highBit: highBit,
                samplesPerPixel: samplesPerPixel,
                photometricInterpretation: photometricInterpretation,
                pixelRepresentation: pixelRepresentation
            ),
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12260001"
            )
        )
    }

    static func makeDataSet(
        transferSyntax: DicomTransferSyntax,
        fragments: [Data],
        declaredFrames: Int?,
        includeBasicOffsetTable: Bool = true,
        extendedOffsetTableFrameStartFragmentIndexes: [Int]? = nil,
        rows: Int = 2,
        columns: Int = 2,
        bitsAllocated: Int = 8,
        bitsStored: Int = 8,
        highBit: Int = 7,
        samplesPerPixel: Int = 1,
        photometricInterpretation: String = "MONOCHROME2",
        pixelRepresentation: Int = 0
    ) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12260001"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PARITY^FRAMES"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PARITY-1226"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12260002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12260003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(samplesPerPixel)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS,
                             value: .strings([photometricInterpretation])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(rows)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(columns)])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsAllocated)])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(highBit)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([UInt(pixelRepresentation)]))
        ]
        if let declaredFrames {
            elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS,
                                             value: .strings(["\(declaredFrames)"])))
        }
        if let starts = extendedOffsetTableFrameStartFragmentIndexes {
            let offsets = frameStartOffsets(fragments: fragments, frameStartFragmentIndexes: starts)
            let lengths = frameLengths(fragments: fragments, frameStartFragmentIndexes: starts)
            elements.append(DicomDataElement(tag: DicomTag.extendedOffsetTable.rawValue, vr: .OV,
                                             value: .bytes(uint64Data(offsets))))
            elements.append(DicomDataElement(tag: DicomTag.extendedOffsetTableLengths.rawValue, vr: .OV,
                                             value: .bytes(uint64Data(lengths))))
        }
        elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                                         value: .bytes(encapsulatedPixelData(
                                            fragments: fragments,
                                            includeBasicOffsetTable: includeBasicOffsetTable
                                         ))))
        return DicomDataSet(elements: elements)
    }

    private static func frameStartOffsets(fragments: [Data], frameStartFragmentIndexes: [Int]) -> [UInt64] {
        let fragmentOffsets = relativeFragmentOffsets(fragments)
        return frameStartFragmentIndexes.map { UInt64(fragmentOffsets[$0]) }
    }

    private static func frameLengths(fragments: [Data], frameStartFragmentIndexes: [Int]) -> [UInt64] {
        var lengths: [UInt64] = []
        for (position, start) in frameStartFragmentIndexes.enumerated() {
            let end = position + 1 < frameStartFragmentIndexes.count
                ? frameStartFragmentIndexes[position + 1]
                : fragments.count
            lengths.append(UInt64(fragments[start..<end].reduce(0) { $0 + $1.count }))
        }
        return lengths
    }

    private static func uint64Data(_ values: [UInt64]) -> Data {
        var data = Data()
        for value in values {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func relativeFragmentOffsets(_ fragments: [Data]) -> [Int] {
        var offsets: [Int] = []
        var running = 0
        for fragment in fragments {
            offsets.append(running)
            running += 8 + fragment.count
        }
        return offsets
    }

    private static func encapsulatedPixelData(fragments: [Data], includeBasicOffsetTable: Bool) -> Data {
        var data = Data()
        if includeBasicOffsetTable {
            var table = Data()
            for offset in relativeFragmentOffsets(fragments) {
                withUnsafeBytes(of: UInt32(offset).littleEndian) { table.append(contentsOf: $0) }
            }
            appendItem(table, to: &data)
        } else {
            appendItem(Data(), to: &data)
        }
        for fragment in fragments {
            appendItem(fragment, to: &data)
        }
        appendTag(0xFFFE_E0DD, to: &data)
        withUnsafeBytes(of: UInt32(0).littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    private static func appendItem(_ payload: Data, to data: inout Data) {
        appendTag(0xFFFE_E000, to: &data)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
    }

    private static func appendTag(_ tag: UInt32, to data: inout Data) {
        withUnsafeBytes(of: UInt16(tag >> 16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(tag & 0xFFFF).littleEndian) { data.append(contentsOf: $0) }
    }
}
