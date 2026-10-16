import Foundation
import XCTest
@testable import DicomCore

/// Issue #3053: structures outside PS3.5 that GDCM reads and IsiX displays, read by the own path to the same samples.
/// Each fixture is synthetic and reproduces one gdcmData object's structure; the samples stay bit-exact.
final class GDCMToleratedStructureTests: XCTestCase {
    private static let width = 7, height = 5

    private static func samples(precision: Int, seed: Int = 0) -> [UInt16] {
        (0..<(width * height)).map { UInt16(($0 * 397 + seed * 1_013 + 11) % (1 << precision)) }
    }

    private static func littleEndian(_ samples: [UInt16]) -> Data {
        Data(samples.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    private static func header(tag: UInt32, length: UInt32) -> Data {
        var bytes = Data()
        for value in [UInt16(tag >> 16), UInt16(tag & 0xFFFF)] { bytes.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((length >> UInt32(shift)) & 0xFF)) }
        return bytes
    }

    private static func item(_ value: Data) -> Data { header(tag: 0xFFFEE000, length: UInt32(value.count)) + value }

    private static func offsetTable(_ offsets: [UInt32]) -> Data {
        item(offsets.reduce(into: Data()) { data, offset in
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((offset >> UInt32(shift)) & 0xFF)) }
        })
    }

    private static func dataSet(bitsAllocated: Int, bitsStored: Int, frames: Int = 1,
                                extra: [DicomDataElement] = []) -> DicomDataSet {
        DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.30530001"])),
            .init(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(frames)"])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsAllocated)])),
            .init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored)])),
            .init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored - 1)])),
            .init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0]))
        ] + extra)
    }

    /// A Part 10 object whose Pixel Data value is `pixelValue`, under the given length (undefined by default).
    private static func part10(_ dataSet: DicomDataSet, pixelValue: Data, definedLength: Bool = false,
                               syntax: DicomTransferSyntax = .jpegLosslessFirstOrder) throws -> Data {
        var encoded = try DicomDataSetWriter.dataSetData(from: dataSet)
        encoded.append(contentsOf: [0xE0, 0x7F, 0x10, 0, 0x4F, 0x42, 0, 0])
        let length = definedLength ? UInt32(pixelValue.count) : UInt32.max
        for shift in stride(from: 0, to: 32, by: 8) { encoded.append(UInt8((length >> UInt32(shift)) & 0xFF)) }
        encoded.append(pixelValue)
        return try DicomDataSetWriter.part10Data(fromEncodedDataSet: encoded, transferSyntax: syntax,
                                                 mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.7",
                                                 mediaStorageSOPInstanceUID: "2.25.30530001")
    }

    private static func codestream(_ samples: [UInt16], precision: Int) throws -> Data {
        try JPEGLosslessEncoder.encode(samples: samples, width: width, height: height, precision: precision, componentCount: 1)
    }

    private static func storedSamples(_ object: Data, frame: Int = 0) async throws -> (Data, Int) {
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: object))
        let decoded = try await session.frame(at: frame)
        await session.close()
        return (decoded.storedSampleData(), decoded.metadata.bitsAllocated)
    }

    /// `MARCONI_MxTWin-12-MONO2-JpegLossless-ZeroLengthSQ`, `NM_Kakadu44_SOTmarkerincons`: a fragment of odd length.
    func test_oddLengthFragment_isDecodedAsDeclared() async throws {
        let source = Self.samples(precision: 12)
        var fragment = try Self.codestream(source, precision: 12)
        // One byte after EOI, as those encoders leave it, makes the item length odd.
        if fragment.count % 2 == 0 { fragment.append(0) }
        let object = try Self.part10(Self.dataSet(bitsAllocated: 16, bitsStored: 12),
                                     pixelValue: Self.item(Data()) + Self.item(fragment) + Self.header(tag: 0xFFFEE0DD, length: 0))
        let (decoded, _) = try await Self.storedSamples(object)
        XCTAssertEqual(decoded, Self.littleEndian(source))
    }

    /// `JPEGDefinedLengthSequenceOfFragments`: the item sequence, delimiter included, under a defined length.
    func test_definedLengthEncapsulatedPixelData_isReadAsItsItems() async throws {
        let source = Self.samples(precision: 12, seed: 2)
        var fragment = try Self.codestream(source, precision: 12)
        if fragment.count % 2 == 1 { fragment.append(0) }
        let object = try Self.part10(Self.dataSet(bitsAllocated: 16, bitsStored: 12),
                                     pixelValue: Self.item(Data()) + Self.item(fragment) + Self.header(tag: 0xFFFEE0DD, length: 0),
                                     definedLength: true)
        let metadata = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: object))
        XCTAssertTrue(metadata.pixelDataIsEncapsulated)
        let (decoded, _) = try await Self.storedSamples(object)
        XCTAssertEqual(decoded, Self.littleEndian(source))
    }

    /// `00191113`: a Basic Offset Table with one entry too many, none at an item start. The JPEG markers delimit the
    /// frames; a table over fragments that are not complete codestreams stays refused
    /// (`DicomSourceFrameIndexTests.test_badTables_neverFallBackToFragmentCount`).
    func test_offsetTableNamingNoItemStart_framesFollowTheCodestreamMarkers() async throws {
        let frames = [Self.samples(precision: 8, seed: 3), Self.samples(precision: 8, seed: 4)]
        var fragments = try frames.map { try Self.codestream($0, precision: 8) }
        for index in fragments.indices where fragments[index].count % 2 == 1 { fragments[index].append(0) }
        let second = UInt32(8 + fragments[0].count)
        let object = try Self.part10(Self.dataSet(bitsAllocated: 8, bitsStored: 8, frames: 2),
                                     pixelValue: Self.offsetTable([0, second + 1, second * 2 + 2])
                                        + fragments.reduce(into: Data()) { $0.append(Self.item($1)) }
                                        + Self.header(tag: 0xFFFEE0DD, length: 0))
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: object))
        XCTAssertEqual(session.index.encapsulatedLayout?.frameFragmentIndexes, [[0], [1]])
        XCTAssertTrue(session.index.encapsulatedLayout?.diagnostics.contains { $0.severity == .warning } == true)
        for (index, expected) in frames.enumerated() {
            let decoded = try await session.frame(at: index)
            XCTAssertEqual(decoded.storedSampleData(), Data(expected.map { UInt8($0) }), "frame \(index)")
        }
        await session.close()
    }

    /// `PHILIPS_Gyroscan-8-MONO2-Odd_Sequence`: a File Meta Information Group Length 4 bytes short ends inside the
    /// last File Meta element. Compatibility reads walk group 0002 to its end; the validated modes still refuse it.
    func test_fileMetaGroupLengthEndingInsideAnElement_compatibilityReadWalksGroup0002() async throws {
        let source = Self.samples(precision: 16, seed: 5)
        let dataSet = Self.dataSet(bitsAllocated: 16, bitsStored: 16, extra: [
            .init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Self.littleEndian(source)))
        ])
        let original = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .implicitVRLittleEndian))
        // The writer starts the File Meta with its 12-byte group length element; its value sits at bytes 140..<144.
        let declared = Int(original[140]) | Int(original[141]) << 8 | Int(original[142]) << 16 | Int(original[143]) << 24
        for wrong in [declared - 4, declared + 4] {
            var object = original
            object.replaceSubrange(140..<144, with: (0..<4).map { UInt8((wrong >> ($0 * 8)) & 0xFF) })
            let metadata = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: object))
            XCTAssertEqual(metadata.transferSyntax, .implicitVRLittleEndian, "length \(wrong)")
            let (decoded, _) = try await Self.storedSamples(object)
            XCTAssertEqual(decoded, Self.littleEndian(source), "length \(wrong)")
            // The whole-file decoder walks the same File Meta before it looks for a deflated data set.
            XCTAssertEqual(try DCMDecoder(data: object).getPixels16(), source, "length \(wrong)")
            do {
                _ = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: object), mode: .strict)
                XCTFail("a validated read guessed the File Meta boundary (length \(wrong))")
            } catch {
                XCTAssertEqual(error as? DicomSourceMetadata.Failure, .invalidFileMetaLength)
            }
        }
    }

    /// `JPEGLosslessSeNonZero`: a lossless scan whose Se is 63 decodes as the same scan with Se 0.
    func test_losslessScanWithNonZeroSe_decodesAsTheScanWithSeZero() throws {
        let source = Self.samples(precision: 12, seed: 6)
        var codestream = try Self.codestream(source, precision: 12)
        let sos = try XCTUnwrap((0..<(codestream.count - 1)).first { codestream[$0] == 0xFF && codestream[$0 + 1] == 0xDA })
        let components = Int(codestream[sos + 4])
        let se = sos + 4 + 1 + 2 * components + 1
        XCTAssertEqual(codestream[se], 0)
        codestream[se] = 63
        XCTAssertEqual(try JPEGLosslessDecoder().decode(data: codestream).pixels, source)
    }

    /// `DCMTK_JPEGExt_12Bits`, `JPEGLosslessSeNonZero`: Bits Allocated 12 over a 12-bit codestream decodes into
    /// 16-bit words, as GDCM delivers it.
    func test_compressedBitsAllocated12_decodesInto16BitWords() async throws {
        let source = Self.samples(precision: 12, seed: 7)
        var fragment = try Self.codestream(source, precision: 12)
        if fragment.count % 2 == 1 { fragment.append(0) }
        let object = try Self.part10(Self.dataSet(bitsAllocated: 12, bitsStored: 12),
                                     pixelValue: Self.item(Data()) + Self.item(fragment) + Self.header(tag: 0xFFFEE0DD, length: 0))
        let (decoded, bitsAllocated) = try await Self.storedSamples(object)
        XCTAssertEqual(bitsAllocated, 16)
        XCTAssertEqual(decoded, Self.littleEndian(source))
    }

    /// The Philips subtraction MR of DICOM_Example (maintainer decision on #3053): Rescale Slope 0 is read as 1, as
    /// GDCM reads it, and the stored value stays readable.
    func test_rescaleSlopeZero_isReadAsOne() async throws {
        let source = Self.samples(precision: 12, seed: 8)
        let dataSet = Self.dataSet(bitsAllocated: 16, bitsStored: 12, extra: [
            .init(tag: DicomTag.rescaleIntercept.rawValue, vr: .DS, value: .strings(["5"])),
            .init(tag: DicomTag.rescaleSlope.rawValue, vr: .DS, value: .strings(["0"])),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Self.littleEndian(source)))
        ])
        let object = try DicomDataSetWriter.part10Data(from: dataSet)
        let decoder = try DCMDecoder(data: object)
        XCTAssertEqual(decoder.rescaleParametersV2.slope, 1)
        XCTAssertEqual(decoder.rescaleParametersV2.intercept, 5)
        XCTAssertEqual(decoder.info(for: .rescaleSlope), "0")
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: object))
        let frame = try await session.frame(at: 0)
        XCTAssertEqual(frame.metadata.rescaleParameters.slope, 1)
        XCTAssertEqual(frame.metadata.rescaleParameters.intercept, 5)
        XCTAssertEqual(frame.storedSampleData(), Self.littleEndian(source))
        await session.close()
    }

    /// `MARCONI_MxTWin-12-MONO2-JpegLossless-ZeroLengthSQ`: a 16-bit stream of the Cornell encoder writes 16 bits
    /// after each SSSS 16 code. The standard reading meets an invalid code and fails; the Cornell reading (GDCM's
    /// retry) decodes it. Three samples of 32767: SSSS 16 with 0xFFFF (difference 65535 from 32768), then two zeros.
    func test_cornellCategory16Stream_decodesWithTheExtraBits() throws {
        var stream = Data([0xFF, 0xD8])
        stream += [0xFF, 0xC3, 0x00, 0x0B, 16, 0x00, 0x01, 0x00, 0x03, 0x01, 0x01, 0x11, 0x00]
        // One DC table: '0' codes SSSS 0, '10' codes SSSS 16.
        stream += [0xFF, 0xC4, 0x00, 0x15, 0x00, 1, 1] + [UInt8](repeating: 0, count: 14) + [0x00, 0x10]
        stream += [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x01, 0x00, 0x00]
        // '10' + sixteen ones + '0' + '0', padded with ones; 0xFF is stuffed.
        stream += [0xBF, 0xFF, 0x00, 0xCF, 0xFF, 0xD9]
        let decoded = try JPEGLosslessDecoder().decode(data: stream)
        XCTAssertEqual(decoded.pixels, [32767, 32767, 32767])
        XCTAssertEqual(decoded.bitDepth, 16)
    }
}
