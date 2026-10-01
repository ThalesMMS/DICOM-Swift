//
//  DicomDecodedFrameReaderTests.swift
//  DicomCoreTests
//
//  Coverage for the production decoded frame reader (issue #1227): decoded
//  pixel hashes and metadata against curated non-PHI fixtures, multiframe
//  per-frame access, the unified typed error surface, cancellation, and the
//  dataset entry point.
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomDecodedFrameReaderTests: XCTestCase {
    // MARK: - Curated fixture parity (pixel hashes pinned by #1224)

    func testJPEGLosslessParityFixtureDecodesWithPinnedHashAndMetadata() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("DecoderParity/jpeg_lossless_sv1_parity.dcm")
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        XCTAssertEqual(reader.frameCount, 1)
        let frame = try reader.frame(at: 0)
        guard case .gray16(let pixels) = frame.pixels else {
            return XCTFail("expected 16-bit grayscale, got \(frame.pixels)")
        }
        XCTAssertEqual(
            ClinicalParityCuratedFixtureTests.pixelHash(pixels.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            ClinicalParityCuratedFixtureTests.jpegLosslessExpectedPixelHash,
            "decoded JPEG Lossless pixels must match the curated parity hash"
        )

        XCTAssertEqual(frame.metadata.transferSyntaxUID, DicomTransferSyntax.jpegLosslessFirstOrder.rawValue)
        XCTAssertEqual(frame.metadata.samplesPerPixel, 1)
        XCTAssertEqual(frame.metadata.pixelRepresentation, 0)
        XCTAssertEqual(frame.metadata.frameCount, 1)
        XCTAssertEqual(pixels.count, frame.metadata.width * frame.metadata.height)
    }

    func testRLEParityFixtureDecodesWithPinnedHashViaAsyncPath() async throws {
        let url = Self.fixturesDirectory.appendingPathComponent("DecoderParity/rle_parity.dcm")
        let reader = try DicomDecodedFrameReader(contentsOf: url)

        let frame = try await reader.frame(at: 0)
        guard case .gray8(let pixels) = frame.pixels else {
            return XCTFail("expected 8-bit grayscale, got \(frame.pixels)")
        }
        XCTAssertEqual(
            ClinicalParityCuratedFixtureTests.pixelHash(pixels),
            ClinicalParityCuratedFixtureTests.rleExpectedPixelHash,
            "decoded RLE pixels must match the curated parity hash"
        )
        XCTAssertEqual(frame.metadata.transferSyntaxUID, DicomTransferSyntax.rleLossless.rawValue)
    }

    /// The reader must agree with the legacy whole-buffer surface for
    /// native files (same normalization contract).
    func testNativeCTFixtureMatchesLegacyPixelBufferAndExposesVOI() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("CT/ct_synthetic.dcm")
        let decoder = try DCMDecoder(contentsOf: url)
        let reader = DicomDecodedFrameReader(decoder: decoder)

        let frame = try reader.frame(at: 0)
        guard case .gray16(let pixels) = frame.pixels else {
            return XCTFail("expected 16-bit grayscale, got \(frame.pixels)")
        }
        XCTAssertEqual(pixels, try XCTUnwrap(decoder.getPixels16()),
                       "frame 0 of a native file must match getPixels16()")

        let metadata = frame.metadata
        XCTAssertEqual(metadata.width, decoder.width)
        XCTAssertEqual(metadata.height, decoder.height)
        XCTAssertEqual(metadata.bitsAllocated, 16)
        XCTAssertEqual(metadata.transferSyntaxUID, decoder.info(for: .transferSyntaxUID))
        if let window = metadata.windowSettings {
            XCTAssertTrue(window.isValid)
            XCTAssertEqual(window, decoder.windowSettingsV2)
        }
        XCTAssertEqual(metadata.rescaleParameters, decoder.rescaleParametersV2)
    }

    // MARK: - Multiframe access (native and encapsulated)

    func testNativeMultiframeDecodesEachFrameWithoutFullSeriesDecode() throws {
        let frames: [[UInt8]] = [
            [0x10, 0x20, 0x30, 0x40],
            [0x50, 0x60, 0x70, 0x80],
            [0x90, 0xA0, 0xB0, 0xC0]
        ]
        let file = try Self.makeNativeMultiframeFile(framePixels: frames)
        let reader = try Self.reader(for: file)

        XCTAssertEqual(reader.frameCount, 3)
        for (index, expected) in frames.enumerated() {
            let frame = try reader.frame(at: index)
            guard case .gray8(let pixels) = frame.pixels else {
                return XCTFail("expected 8-bit grayscale for frame \(index)")
            }
            XCTAssertEqual(pixels, expected, "frame \(index) must decode only its own bytes")
            XCTAssertEqual(frame.metadata.frameCount, 3)
        }
    }

    func testEncapsulatedRLEMultiframeDecodesEachFrame() throws {
        let frameSamples: [[UInt8]] = [[10, 20, 30, 40], [50, 60, 70, 80]]
        let fragments = frameSamples.map { Self.rleSegment(samples: $0) }
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .rleLossless,
            fragments: fragments,
            declaredFrames: 2
        )
        let reader = try Self.reader(for: file)

        XCTAssertEqual(reader.frameCount, 2)
        for (index, expected) in frameSamples.enumerated() {
            let frame = try reader.frame(at: index)
            guard case .gray8(let pixels) = frame.pixels else {
                return XCTFail("expected 8-bit grayscale for frame \(index)")
            }
            XCTAssertEqual(Array(pixels.prefix(4)), expected)
        }
    }

    func testFrameStreamDeliversFramesInOrderAndHonorsCancellation() async throws {
        let frameSamples: [[UInt8]] = [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11, 12]]
        let file = try Self.makeNativeMultiframeFile(framePixels: frameSamples)
        let reader = try Self.reader(for: file)

        var indexes: [Int] = []
        for try await frame in reader.frames() {
            indexes.append(frame.index)
        }
        XCTAssertEqual(indexes, [0, 1, 2])

        let consumed = expectation(description: "first frame consumed")
        let task = Task {
            var count = 0
            for try await _ in reader.frames() {
                count += 1
                consumed.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return count
        }
        await fulfillment(of: [consumed], timeout: 10)
        task.cancel()
        let count = try? await task.value
        XCTAssertNotEqual(count, frameSamples.count, "cancellation must stop the stream early")
    }

    // MARK: - Unified typed error surface

    func testUnsupportedTransferSyntaxIsTypedWithResolverDiagnostics() throws {
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpeg2000Part2MulticomponentLossless,
            fragments: [Data([0xFF, 0x4F, 0xFF, 0x51])],
            declaredFrames: 1
        )
        let reader = try Self.reader(for: file)

        // #2331: Part 2 objects are component collections; a fragment that is not a codestream is a typed
        // encapsulation error, and the disabled rollout stays a typed unsupported-syntax error.
        XCTAssertThrowsError(try reader.frame(at: 0)) { error in
            guard case DicomDecodedFrameReader.ReadError.unusableEncapsulation(let diagnostics) = error else {
                return XCTFail("expected unusableEncapsulation, got \(error)")
            }
            XCTAssertTrue(diagnostics.contains { $0.contains("component collection 0") }, "\(diagnostics)")
        }
    }

    func testCorruptPayloadFailsTypedThroughTheSameSurface() throws {
        let file = try EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .jpegLosslessFirstOrder,
            fragments: [Data([0x00, 0x01, 0x02, 0x03])],
            declaredFrames: 1
        )
        let reader = try Self.reader(for: file)

        XCTAssertThrowsError(try reader.frame(at: 0)) { error in
            guard case DicomDecodedFrameReader.ReadError.decodeFailed(let uid, _) = error else {
                return XCTFail("expected decodeFailed, got \(error)")
            }
            XCTAssertEqual(uid, DicomTransferSyntax.jpegLosslessFirstOrder.rawValue)
        }
    }

    func testFrameIndexOutOfRangeIsTypedForNativeAndEncapsulated() throws {
        let nativeReader = try Self.reader(for: Self.makeNativeMultiframeFile(framePixels: [[1, 2, 3, 4]]))
        XCTAssertThrowsError(try nativeReader.frame(at: 5)) { error in
            XCTAssertEqual(
                error as? DicomDecodedFrameReader.ReadError,
                .frameIndexOutOfRange(index: 5, frameCount: 1)
            )
        }

        let encapsulatedReader = try Self.reader(for: EncapsulatedFixtureFactory.makeFile(
            transferSyntax: .rleLossless,
            fragments: [Self.rleSegment(samples: [1, 2, 3, 4])],
            declaredFrames: 1
        ))
        XCTAssertThrowsError(try encapsulatedReader.frame(at: 2)) { error in
            XCTAssertEqual(
                error as? DicomDecodedFrameReader.ReadError,
                .frameIndexOutOfRange(index: 2, frameCount: 1)
            )
        }
    }

    // MARK: - Dataset entry point

    func testDataSetEntryPointDecodesEncapsulatedFrames() throws {
        let dataSet = EncapsulatedFixtureFactory.makeDataSet(
            transferSyntax: .rleLossless,
            fragments: [Self.rleSegment(samples: [11, 22, 33, 44])],
            declaredFrames: 1
        )
        let reader = try DicomDecodedFrameReader(
            dataSet: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .rleLossless,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12270001"
            )
        )

        let frame = try reader.frame(at: 0)
        guard case .gray8(let pixels) = frame.pixels else {
            return XCTFail("expected 8-bit grayscale, got \(frame.pixels)")
        }
        XCTAssertEqual(Array(pixels.prefix(4)), [11, 22, 33, 44])
        XCTAssertEqual(frame.metadata.transferSyntaxUID, DicomTransferSyntax.rleLossless.rawValue)
    }

    func testDataSetEntryPointDoesNotSerializeThroughTemporaryFile() throws {
        let source = try String(
            contentsOf: Self.packageRoot.appendingPathComponent("Sources/DicomCore/DicomDecodedFrameReader.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("decoded-frame-reader-"))
    }

    // MARK: - Helpers

    private static func reader(for fileData: Data) throws -> DicomDecodedFrameReader {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decoded-frame-\(UUID().uuidString).dcm")
        try fileData.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DicomDecodedFrameReader(contentsOf: url)
    }

    private static func makeNativeMultiframeFile(framePixels: [[UInt8]]) throws -> Data {
        var pixelData = Data()
        for frame in framePixels {
            pixelData.append(contentsOf: frame)
        }
        if pixelData.count % 2 != 0 {
            pixelData.append(0x00)
        }
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12270002"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PARITY^DECODED"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PARITY-1227"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12270003"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.12270004"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([2])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS,
                             value: .strings(["\(framePixels.count)"])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(pixelData))
        ])
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.12270002"
            )
        )
    }

    private static func rleSegment(samples: [UInt8]) -> Data {
        var rle = Data()
        var header = [UInt32](repeating: 0, count: 16)
        header[0] = 1
        header[1] = 64
        for value in header {
            withUnsafeBytes(of: value.littleEndian) { rle.append(contentsOf: $0) }
        }
        rle.append(UInt8(samples.count - 1))
        rle.append(contentsOf: samples)
        if rle.count % 2 != 0 {
            rle.append(0x00)
        }
        return rle
    }

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

// MARK: - Explicit VR Big Endian 8-bit samples (own-provider corpus parity, 2026-09-12)

extension DicomDecodedFrameReaderTests {
    /// An OW Pixel Data element under Explicit VR Big Endian holds 16-bit words (PS3.5 §7.6.1.1.1), so
    /// 8-bit samples are byte-swapped in pairs on disk. The reader restores raster order on every native
    /// path; an odd frame length keeps the word pairing across frames and the missing pad byte reads as zero.
    func testBigEndianOWEightBitRGBSamplesAreWordSwappedBack() throws {
        let samples: [UInt8] = (0..<27).map { UInt8($0 * 9 + 1) } // 3×3 RGB, odd length
        let file = try Self.makeBigEndianEightBitFile(samples: [samples], width: 3, height: 3, samplesPerPixel: 3,
                                                       photometric: "RGB", planar: 0, vr: .OW)
        let reader = try Self.reader(for: file)
        let typed = try reader.frame(at: 0)
        guard case .rgb8(let interleaved) = typed.pixels else { return XCTFail("expected rgb8, got \(typed.pixels)") }
        XCTAssertEqual(interleaved, samples)
        let backed = try reader.dataBackedFrame(at: 0)
        XCTAssertEqual(Array(backed.pixels.data), samples)
        XCTAssertEqual(Array(try backed.copyingToArrayBackedFrame().storedSampleData()), samples)
        let decoder = try DCMDecoder(data: file)
        XCTAssertEqual(decoder.pixelDataVR, .OW)
        XCTAssertTrue(decoder.nativeEightBitSamplesAreWordSwapped)
        XCTAssertEqual(Array(decoder.getFrame(0)?.data ?? Data()), samples)
        XCTAssertEqual(Array(try decoder.displayRGBPixelBuffer(frame: 0).rgbData), samples)
    }

    func testBigEndianOWPlanarRGBAndTwoOddFramesKeepTheWordPairing() throws {
        // Planar configuration 1: the swap applies to the planar bytes, the reader then interleaves.
        let pixels = 5 // 5×1, odd plane and frame lengths (15 bytes per frame)
        let frame0 = (0..<15).map { UInt8(10 + $0) }, frame1 = (0..<15).map { UInt8(100 + $0) }
        let file = try Self.makeBigEndianEightBitFile(samples: [frame0, frame1], width: pixels, height: 1, samplesPerPixel: 3,
                                                       photometric: "RGB", planar: 1, vr: .OW)
        let reader = try Self.reader(for: file)
        XCTAssertEqual(reader.frameCount, 2)
        for (index, planes) in [frame0, frame1].enumerated() {
            let expected = (0..<pixels).flatMap { [planes[$0], planes[pixels + $0], planes[2 * pixels + $0]] }
            let backed = try reader.dataBackedFrame(at: index)
            XCTAssertEqual(Array(backed.pixels.data), expected, "frame \(index)")
            guard case .rgb8(let interleaved) = try reader.frame(at: index).pixels else { return XCTFail("rgb8") }
            XCTAssertEqual(interleaved, expected, "frame \(index)")
        }
    }

    func testBigEndianOWEightBitGrayAndOBSamplesFollowTheValueRepresentation() throws {
        let gray: [UInt8] = (0..<12).map { UInt8($0 * 20) }
        let grayFile = try Self.makeBigEndianEightBitFile(samples: [gray], width: 4, height: 3, samplesPerPixel: 1,
                                                           photometric: "MONOCHROME2", planar: nil, vr: .OW)
        guard case .gray8(let grayPixels) = try Self.reader(for: grayFile).frame(at: 0).pixels else { return XCTFail("gray8") }
        XCTAssertEqual(grayPixels, gray)
        let decoder = try DCMDecoder(data: grayFile)
        XCTAssertEqual(decoder.getPixels8(), gray, "the whole-buffer reader restores the word order too")

        // OB is a byte stream: nothing is swapped whatever the transfer syntax.
        let rgb: [UInt8] = (0..<27).map { UInt8($0 * 7) }
        let obFile = try Self.makeBigEndianEightBitFile(samples: [rgb], width: 3, height: 3, samplesPerPixel: 3,
                                                         photometric: "RGB", planar: 0, vr: .OB)
        let obDecoder = try DCMDecoder(data: obFile)
        XCTAssertEqual(obDecoder.pixelDataVR, .OB)
        XCTAssertFalse(obDecoder.nativeEightBitSamplesAreWordSwapped)
        guard case .rgb8(let obPixels) = try Self.reader(for: obFile).frame(at: 0).pixels else { return XCTFail("rgb8") }
        XCTAssertEqual(obPixels, rgb)
    }

    /// The frame-addressed session reads the whole 16-bit words covering a frame, so a frame of odd length
    /// whose first sample sits in the previous frame's last word is still delivered in raster order.
    func testFrameAddressedSessionRestoresWordSwappedFramesOfOddLength() async throws {
        let frame0 = (0..<15).map { UInt8(10 + $0) }, frame1 = (0..<15).map { UInt8(100 + $0) }
        let file = try Self.makeBigEndianEightBitFile(samples: [frame0, frame1], width: 5, height: 1, samplesPerPixel: 3,
                                                       photometric: "RGB", planar: 0, vr: .OW)
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: file))
        XCTAssertEqual(session.index.frameCount, 2)
        XCTAssertEqual(try session.index.wordSwapLeadingBytes(forFrame: 0), 0)
        XCTAssertEqual(try session.index.wordSwapLeadingBytes(forFrame: 1), 1, "frame 1 starts inside frame 0's last word")
        let reader = try Self.reader(for: file)
        for (index, expected) in [frame0, frame1].enumerated() {
            let raw = try await session.frameData(at: index)
            XCTAssertEqual(Array(raw), expected, "the raw consumer receives one reordered frame without neighboring samples")
            let viaSession = try await session.dataBackedFrame(at: index)
            let viaReader: DicomDataBackedDecodedFrame = try await reader.dataBackedFrame(at: index)
            XCTAssertEqual(Array(viaSession.pixels.data), expected, "frame \(index) through the session")
            XCTAssertEqual(Array(viaSession.pixels.data), Array(viaReader.pixels.data),
                           "frame \(index): the session and the whole-file reader agree")
        }
        var streamed: [[UInt8]] = []
        for try await element in try session.frames() {
            streamed.append(Array(element.data))
        }
        XCTAssertEqual(streamed, [frame0, frame1])
        await session.close()
    }

    func testNativeFrameDataSwapsWordsRelativeToThePixelDataStart() {
        let descriptor = DicomPixelDataDescriptor(rows: 1, columns: 3, numberOfFrames: 2, bitsAllocated: 8, bitsStored: 8, highBit: 7,
                                                  pixelRepresentation: 0, samplesPerPixel: 1, planarConfiguration: nil,
                                                  photometricInterpretation: "MONOCHROME2", pixelDataOffset: 1,
                                                  eightBitSamplesAreWordSwapped: true)!
        // Value bytes (from offset 1): b a d c f e → samples a b c | d e f; the pad byte after f is absent.
        let data = Data([0xFF, 0x0B, 0x0A, 0x0D, 0x0C, 0x0F, 0x0E])
        XCTAssertEqual(Array(descriptor.nativeFrameData(in: data, frame: 0) ?? Data()), [0x0A, 0x0B, 0x0C])
        XCTAssertEqual(Array(descriptor.nativeFrameData(in: data, frame: 1) ?? Data()), [0x0D, 0x0E, 0x0F])
        let truncated = Data([0xFF, 0x0B, 0x0A, 0x0D, 0x0C, 0x0F])
        XCTAssertNil(descriptor.nativeFrameData(in: truncated, frame: 1), "a frame outside the data is refused")
        let single = DicomPixelDataDescriptor(rows: 1, columns: 3, numberOfFrames: 1, bitsAllocated: 8, bitsStored: 8, highBit: 7,
                                              pixelRepresentation: 0, samplesPerPixel: 1, planarConfiguration: nil,
                                              photometricInterpretation: "MONOCHROME2", pixelDataOffset: 0,
                                              eightBitSamplesAreWordSwapped: true)!
        XCTAssertEqual(Array(single.nativeFrameData(in: Data([0x0B, 0x0A, 0x0C]), frame: 0) ?? Data()), [0x0A, 0x0B, 0x00],
                       "a missing pad byte reads as zero")
        XCTAssertFalse(DicomPixelDataDescriptor(rows: 1, columns: 1, numberOfFrames: 1, bitsAllocated: 16, bitsStored: 16, highBit: 15,
                                                pixelRepresentation: 0, samplesPerPixel: 1, planarConfiguration: nil,
                                                photometricInterpretation: "MONOCHROME2", pixelDataOffset: 0,
                                                eightBitSamplesAreWordSwapped: true)!.eightBitSamplesAreWordSwapped,
                       "the flag only applies to 8-bit samples")
    }

    /// Writes the object under Explicit VR Big Endian with the samples laid out as the file would carry them:
    /// OW pairs are swapped on disk (the writer copies binary values verbatim), OB bytes are not.
    private static func makeBigEndianEightBitFile(samples: [[UInt8]], width: Int, height: Int, samplesPerPixel: Int,
                                                  photometric: String, planar: Int?, vr: DicomVR) throws -> Data {
        var raster = samples.flatMap { $0 }
        if raster.count % 2 != 0 { raster.append(0) }
        var onDisk = raster
        if vr == .OW { for pair in stride(from: 0, to: onDisk.count, by: 2) { onDisk.swapAt(pair, pair + 1) } }
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI,
                             value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.20260912"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PARITY^BIGENDIAN"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PARITY-BE"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.20260912.1"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.20260912.2"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(samplesPerPixel)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([photometric])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0]))
        ]
        if let planar { elements.append(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([UInt(planar)]))) }
        if samples.count > 1 { elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(samples.count)"]))) }
        elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: vr, value: .bytes(Data(onDisk))))
        return try DicomDataSetWriter.part10Data(
            from: DicomDataSet(elements: elements),
            options: DicomPart10WriterOptions(transferSyntax: .explicitVRBigEndian,
                                              mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                                              mediaStorageSOPInstanceUID: "2.25.20260912")
        )
    }
}
