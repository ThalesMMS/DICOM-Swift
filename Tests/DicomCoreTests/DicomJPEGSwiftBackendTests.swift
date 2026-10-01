import DicomCodecs
import DicomJPEG
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DicomCore

/// Own JPEG backend (#2326): SOF0/SOF1/SOF2/SOF3 decode and encode cross-checked against ImageIO (libjpeg-turbo)
/// and the independent native lossless/extended decoders, reduced decode, inspection, mislabel detection,
/// transcoder routes and refusals.
final class DicomJPEGSwiftBackendTests: XCTestCase {
    // MARK: - Fixtures

    private static func gray8(_ width: Int, _ height: Int, seed: Int = 1) -> [UInt8] {
        (0..<(width * height)).map { UInt8(((($0 % width) * 9 + ($0 / width) * 17 + seed * 31) / 3) & 0xFF) }
    }

    /// Smooth chroma so 4:2:0 references (ImageIO subsamples) stay close to the source; sharp luma detail remains.
    private static func rgb8(_ width: Int, _ height: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let luma = UInt8(((x * 9 + y * 17) / 3) & 0xFF)
                bytes += [UInt8(min(255, 40 + x * 160 / max(1, width - 1))), luma, UInt8(min(255, 60 + y * 150 / max(1, height - 1)))]
            }
        }
        return bytes
    }

    private static func gray12(_ width: Int, _ height: Int) -> [UInt16] {
        (0..<(width * height)).map { UInt16((($0 % width) * 97 + ($0 / width) * 211) % 4096) }
    }

    /// ImageIO (libjpeg-turbo) encodes the reference codestreams: an implementation independent of DicomJPEG.
    private static func imageIOJPEG(gray: [UInt8]? = nil, rgb: [UInt8]? = nil, width: Int, height: Int, quality: Double = 0.95, progressive: Bool = false) throws -> Data {
        let components = gray != nil ? 1 : 3
        let bytes = gray ?? rgb!
        let colorSpace = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: width * components,
                                          space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                          decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if progressive { properties[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// ImageIO decode of a codestream to interleaved samples (the independent reference for DCT decoding).
    private static func imageIODecode(_ jpeg: Data, components: Int) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * (components == 1 ? 1 : 4))
        let colorSpace = components == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = components == 1 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = try XCTUnwrap(CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * (components == 1 ? 1 : 4),
                                              space: colorSpace, bitmapInfo: info))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if components == 1 { return buffer }
        var rgb: [UInt8] = []
        rgb.reserveCapacity(width * height * 3)
        for pixel in 0..<(width * height) { rgb += [buffer[pixel * 4], buffer[pixel * 4 + 1], buffer[pixel * 4 + 2]] }
        return rgb
    }

    private static func descriptor(_ syntax: DicomTransferSyntax, width: Int, height: Int, bitsStored: Int, samples: Int, photometric: String) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(transferSyntaxUID: syntax.rawValue, rows: height, columns: width, bitsAllocated: bitsStored > 8 ? 16 : 8,
                                       bitsStored: bitsStored, highBit: bitsStored - 1, pixelRepresentation: 0, samplesPerPixel: samples,
                                       photometricInterpretation: photometric, planarConfiguration: samples == 3 ? 0 : nil)
    }

    private static func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? Int.max
    }

    private func dicomFile(jpeg: Data, syntax: DicomTransferSyntax, width: Int, height: Int, bitsStored: Int, samples: Int, photometric: String) throws -> Data {
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23439001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23439002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23439003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(samples)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([photometric])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([bitsStored > 8 ? 16 : 8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(DicomInstanceSplitter.encapsulate(jpeg)))
        ]
        if samples == 3 { elements.append(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0]))) }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements), options: .init(transferSyntax: syntax))
    }

    // MARK: - Decode against ImageIO

    func test_baselineAndProgressiveDecodeAgreeWithImageIO() async throws {
        let width = 37, height = 23
        let gray = Self.gray8(width, height)
        let rgb = Self.rgb8(width, height)
        let cases: [(String, Data, Int, String)] = [
            ("gray", try Self.imageIOJPEG(gray: gray, width: width, height: height), 1, "MONOCHROME2"),
            ("rgb", try Self.imageIOJPEG(rgb: rgb, width: width, height: height), 3, "YBR_FULL_422"),
            ("gray-progressive", try Self.imageIOJPEG(gray: gray, width: width, height: height, progressive: true), 1, "MONOCHROME2"),
            ("rgb-progressive", try Self.imageIOJPEG(rgb: rgb, width: width, height: height, progressive: true), 3, "YBR_FULL_422")
        ]
        for (label, jpeg, samples, photometric) in cases {
            let inspection = try DicomJPEGFrameInspector.inspect(jpeg)
            XCTAssertEqual(inspection.process, label.hasSuffix("progressive") ? .progressive : .baseline, label)
            XCTAssertEqual(inspection.width, width, label); XCTAssertEqual(inspection.height, height, label)
            XCTAssertEqual(inspection.components.count, samples, label)
            XCTAssertGreaterThan(inspection.huffmanTableCount, 0, label); XCTAssertGreaterThan(inspection.quantizationTableCount, 0, label)
            if inspection.process == .progressive { XCTAssertGreaterThan(inspection.scans.count, 1, label); XCTAssertTrue(inspection.scans.contains { $0.spectralEnd > 0 }, label) }
            let descriptor = Self.descriptor(.jpegBaseline, width: width, height: height, bitsStored: 8, samples: samples, photometric: photometric)
            let decoded = try DicomJPEGSwiftBackend.decodeSynchronously(jpeg, descriptor: descriptor)
            XCTAssertEqual(decoded.width, width, label); XCTAssertEqual(decoded.height, height, label)
            XCTAssertEqual(decoded.buffer.data.count, width * height * samples, label)
            let reference = try Self.imageIODecode(jpeg, components: samples)
            let difference = Self.maxDifference([UInt8](decoded.buffer.data), reference)
            // Grayscale: IDCT rounding only. Colour: libjpeg-turbo's triangle ("fancy") chroma upsampling against the
            // vendored decoder's upsampling on 4:2:0 references, bounded on smooth chroma.
            XCTAssertLessThanOrEqual(difference, samples == 1 ? 1 : 8, "\(label): decoder agreement against libjpeg-turbo")
            let asyncFrame = try await DicomJPEGSwiftBackend().decode(DicomFrameDecodeRequest(frameData: jpeg, descriptor: descriptor, frameIndex: 0))
            XCTAssertEqual(asyncFrame.buffer.data, decoded.buffer.data, label)
        }
    }

    func test_reducedDecodeIsTheBoxAverageOfTheFullFrame() async throws {
        let width = 40, height = 24
        let jpeg = try Self.imageIOJPEG(gray: Self.gray8(width, height), width: width, height: height)
        let descriptor = Self.descriptor(.jpegBaseline, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2")
        let full = [UInt8](try DicomJPEGSwiftBackend.decodeSynchronously(jpeg, descriptor: descriptor).buffer.data)
        for level in 1...3 {
            let scale = 1 << level
            let request = DicomFrameDecodeRequest(frameData: jpeg, descriptor: descriptor, frameIndex: 0,
                                                  partialRequest: DicomCodecPartialDecodeRequest(region: nil, resolutionLevel: level, maximumQualityLayer: nil))
            let reduced = try await DicomJPEGSwiftBackend().decode(request)
            XCTAssertEqual(reduced.width, (width + scale - 1) / scale, "level \(level)")
            XCTAssertEqual(reduced.height, (height + scale - 1) / scale, "level \(level)")
            let bytes = [UInt8](reduced.buffer.data)
            var worst = 0
            for y in 0..<reduced.height {
                for x in 0..<reduced.width {
                    var sum = 0, count = 0
                    for dy in 0..<scale where y * scale + dy < height { for dx in 0..<scale where x * scale + dx < width { sum += Int(full[(y * scale + dy) * width + x * scale + dx]); count += 1 } }
                    worst = max(worst, abs(Int(bytes[y * reduced.width + x]) - (sum + count / 2) / count))
                }
            }
            XCTAssertLessThanOrEqual(worst, 2, "level \(level): coefficient-domain reduction is the box average of the block (rounding aside)")
        }
        let tooDeep = DicomFrameDecodeRequest(frameData: jpeg, descriptor: descriptor, frameIndex: 0,
                                              partialRequest: DicomCodecPartialDecodeRequest(region: nil, resolutionLevel: 4, maximumQualityLayer: nil))
        do { _ = try await DicomJPEGSwiftBackend().decode(tooDeep); XCTFail("level 4 accepted") } catch {}
    }

    // MARK: - 12-bit and lossless against the independent native decoders

    func test_twelveBitExtendedAndLosslessRoundTripsAgainstNativeDecoders() async throws {
        let width = 19, height = 11
        let samples = Self.gray12(width, height)
        var stored = Data()
        for value in samples { stored.append(UInt8(value & 0xFF)); stored.append(UInt8(value >> 8)) }
        let backend = DicomJPEGSwiftBackend()
        // Extended sequential 12-bit: decoded by the independent JPEGExtendedDecoder and by the backend itself.
        let extended = Self.descriptor(.jpegExtended, width: width, height: height, bitsStored: 12, samples: 1, photometric: "MONOCHROME2")
        let frame = DicomCodecDecodedFrame(buffer: .owned(stored), width: width, height: height, bitsPerSample: 12, componentCount: 1)
        let encoded = try await backend.encode(DicomFrameEncodeRequest(frame: frame, descriptor: extended, targetTransferSyntaxUID: extended.transferSyntaxUID, intent: .irreversible(quality: 1)))
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(encoded).process, .extendedSequential)
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(encoded).precision, 12)
        let native = try JPEGExtendedDecoder.decode(encoded)
        let own = try DicomJPEGSwiftBackend.decodeSynchronously(encoded, descriptor: extended)
        let ownSamples = own.buffer.data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        XCTAssertEqual(native.width, width); XCTAssertEqual(native.precision, 12)
        XCTAssertLessThanOrEqual(zip(native.pixels, ownSamples).map { abs(Int($0) - Int($1)) }.max() ?? Int.max, 1, "two IDCT implementations agree within one LSB")
        XCTAssertLessThanOrEqual(zip(samples, ownSamples).map { abs(Int($0) - Int($1)) }.max() ?? Int.max, 24, "quality 1 keeps the 12-bit signal close")
        // Lossless (SOF3) 8/12/16-bit grayscale and 8-bit RGB: decoded exactly by the independent JPEGLosslessDecoder.
        for bits in [8, 12, 16] {
            let values: [UInt16] = samples.map { bits == 8 ? $0 >> 4 : bits == 12 ? $0 : $0 * 16 + 3 }
            var bytes = Data()
            for value in values { if bits == 8 { bytes.append(UInt8(value)) } else { bytes.append(UInt8(value & 0xFF)); bytes.append(UInt8(value >> 8)) } }
            for syntax in [DicomTransferSyntax.jpegLossless, .jpegLosslessFirstOrder] {
                let descriptor = Self.descriptor(syntax, width: width, height: height, bitsStored: bits, samples: 1, photometric: "MONOCHROME2")
                let frame = DicomCodecDecodedFrame(buffer: .owned(bytes), width: width, height: height, bitsPerSample: bits, componentCount: 1)
                let codestream = try await backend.encode(DicomFrameEncodeRequest(frame: frame, descriptor: descriptor, targetTransferSyntaxUID: syntax.rawValue, intent: .reversible))
                let inspection = try DicomJPEGFrameInspector.inspect(codestream)
                XCTAssertEqual(inspection.process, .lossless, "\(bits)-bit \(syntax.rawValue)")
                XCTAssertTrue(inspection.scans.allSatisfy { $0.predictor == 1 })
                let reference = try JPEGLosslessDecoder().decode(data: codestream)
                XCTAssertEqual(reference.pixels.map { UInt16($0) }, values, "\(bits)-bit lossless decodes exactly in the native decoder")
                let back = try DicomJPEGSwiftBackend.decodeSynchronously(codestream, descriptor: descriptor)
                XCTAssertEqual(back.buffer.data, bytes, "\(bits)-bit lossless round trip")
                do { _ = try await backend.encode(DicomFrameEncodeRequest(frame: frame, descriptor: descriptor, targetTransferSyntaxUID: syntax.rawValue, intent: .irreversible(quality: 0.5))); XCTFail("lossy intent for a lossless syntax") } catch {}
            }
        }
        let rgb = Self.rgb8(width, height)
        let rgbDescriptor = Self.descriptor(.jpegLossless, width: width, height: height, bitsStored: 8, samples: 3, photometric: "RGB")
        let rgbFrame = DicomCodecDecodedFrame(buffer: .owned(Data(rgb)), width: width, height: height, bitsPerSample: 8, componentCount: 3)
        let rgbStream = try await backend.encode(DicomFrameEncodeRequest(frame: rgbFrame, descriptor: rgbDescriptor, targetTransferSyntaxUID: rgbDescriptor.transferSyntaxUID, intent: .reversible))
        XCTAssertEqual(try JPEGLosslessDecoder().decode(data: rgbStream).pixels.map { UInt8($0) }, rgb, "RGB lossless decodes exactly in the native decoder")
        XCTAssertEqual([UInt8](try DicomJPEGSwiftBackend.decodeSynchronously(rgbStream, descriptor: rgbDescriptor).buffer.data), rgb)
    }

    /// Issue #2852: sequential scans written with Ss = Se = 0 (the D_CLUNIE_*_JPLY encoder) and a pad byte after EOI
    /// that is neither 0x00 nor 0xFF (0xA2 in PHILIPS_Gyroscan-12-Jpeg_Extended_Process_2_4) decode as libjpeg and
    /// GDCM read them: the scan covers every coefficient and the pad is ignored.
    func test_twelveBitExtended_withZeroSpectralEndAndAnyPadAfterEOI_decodesAsTheStandardStream() async throws {
        let width = 19, height = 11
        var stored = Data()
        for value in Self.gray12(width, height) { stored.append(UInt8(value & 0xFF)); stored.append(UInt8(value >> 8)) }
        let extended = Self.descriptor(.jpegExtended, width: width, height: height, bitsStored: 12, samples: 1, photometric: "MONOCHROME2")
        let frame = DicomCodecDecodedFrame(buffer: .owned(stored), width: width, height: height, bitsPerSample: 12, componentCount: 1)
        let encoded = try await DicomJPEGSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: frame, descriptor: extended, targetTransferSyntaxUID: extended.transferSyntaxUID, intent: .irreversible(quality: 0.9)))
        let reference = try DicomJPEGSwiftBackend.decodeSynchronously(encoded, descriptor: extended).buffer.data

        var bytes = [UInt8](encoded)
        let sos = try XCTUnwrap((0 ..< bytes.count - 1).first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA })
        let length = Int(bytes[sos + 2]) << 8 | Int(bytes[sos + 3])
        XCTAssertEqual(bytes[sos + length], 63, "the encoder writes Se = 63")
        bytes[sos + length] = 0
        bytes.append(0xA2)
        let variant = Data(bytes)
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(variant).process, .extendedSequential)
        XCTAssertEqual(try DicomJPEGSwiftBackend.decodeSynchronously(variant, descriptor: extended).buffer.data, reference)
    }

    func test_twelveBitDCT_reportsItsWordSampleWidth() async throws {
        let descriptor = Self.descriptor(.jpegExtended, width: 8, height: 8, bitsStored: 12,
                                         samples: 1, photometric: "MONOCHROME2")
        let source = Self.gray12(8, 8).withUnsafeBytes { Data($0) }
        let frame = DicomCodecDecodedFrame(buffer: .owned(source), width: 8, height: 8,
                                          bitsPerSample: 12, componentCount: 1)
        let codestream = try await DicomJPEGSwiftBackend().encode(.init(frame: frame, descriptor: descriptor,
            targetTransferSyntaxUID: descriptor.transferSyntaxUID, intent: .irreversible(quality: 1)))
        let decoded = try DicomJPEGSwiftBackend.decodeSynchronously(codestream, descriptor: descriptor)
        XCTAssertEqual(decoded.bitsPerSample, 16)
        XCTAssertEqual(decoded.buffer.data.count, 128)
    }

    func test_signedLosslessWithWiderCodestream_keepsItsSignedPrecision() async throws {
        let words: [UInt16] = [0x8000, 0xFFFF, 0, 1, 0x7FFF]
        let full = Self.descriptor(.jpegLossless, width: 5, height: 1, bitsStored: 16, samples: 1, photometric: "MONOCHROME2")
        let frame = DicomCodecDecodedFrame(buffer: .owned(words.withUnsafeBytes { Data($0) }),
            width: 5, height: 1, bitsPerSample: 16, componentCount: 1)
        let codestream = try await DicomJPEGSwiftBackend().encode(.init(frame: frame, descriptor: full,
            targetTransferSyntaxUID: full.transferSyntaxUID, intent: .reversible))
        let declared = DicomCompressedFrameDescriptor(transferSyntaxUID: full.transferSyntaxUID,
            rows: 1, columns: 5, bitsAllocated: 16, bitsStored: 12, highBit: 11, pixelRepresentation: 1,
            samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
        let decoded = try DicomJPEGSwiftBackend.decodeSynchronously(codestream, descriptor: declared)
        XCTAssertEqual(decoded.buffer.data, words.withUnsafeBytes { Data($0) })
        XCTAssertEqual(decoded.bitsPerSample, 16)
    }

    /// Issue #2856 (`SC16BitsAllocated_8BitsStoredJPEG`): an 8-bit lossless codestream under Bits Allocated and
    /// Bits Stored 16 is delivered as 8-bit samples at its own precision, the pixel format GDCM gives it.
    func test_eightBitLosslessCodestreamUnderSixteenBitDeclaration_yieldsEightBitSamples() async throws {
        let width = 13, height = 7
        let samples = Self.gray8(width, height)
        let eightBit = Self.descriptor(.jpegLossless, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2")
        let frame = DicomCodecDecodedFrame(buffer: .owned(Data(samples)), width: width, height: height, bitsPerSample: 8, componentCount: 1)
        let codestream = try await DicomJPEGSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: frame, descriptor: eightBit, targetTransferSyntaxUID: eightBit.transferSyntaxUID, intent: .reversible))
        let declared16 = DicomCompressedFrameDescriptor(
            transferSyntaxUID: DicomTransferSyntax.jpegLossless.rawValue, rows: height, columns: width, bitsAllocated: 16,
            bitsStored: 16, highBit: 15, pixelRepresentation: 0, samplesPerPixel: 1,
            photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
        let decoded = try DicomJPEGSwiftBackend.decodeSynchronously(codestream, descriptor: declared16)
        XCTAssertEqual(decoded.bitsPerSample, 8)
        XCTAssertEqual([UInt8](decoded.buffer.data), samples, "one byte per sample, the codestream's values")
    }

    /// Issue #2487: PS3.5 A.4.1 makes the Extended syntax Process 2 & 4, so an 8-bit frame under .51 is written as
    /// SOF1; the same frame under .50 stays SOF0.
    func test_eightBitFramesUnderTheExtendedSyntax_areWrittenAsSOF1() async throws {
        let width = 8, height = 8
        let samples = Data(repeating: 100, count: width * height)
        let frame = DicomCodecDecodedFrame(buffer: .owned(samples), width: width, height: height, bitsPerSample: 8, componentCount: 1)
        let backend = DicomJPEGSwiftBackend()
        let extended = Self.descriptor(.jpegExtended, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2")
        let sof1 = try await backend.encode(DicomFrameEncodeRequest(frame: frame, descriptor: extended, targetTransferSyntaxUID: extended.transferSyntaxUID, intent: .irreversible(quality: 1)))
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(sof1).process, .extendedSequential)
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(sof1).precision, 8)
        XCTAssertEqual(Set(try JPEGExtendedDecoder.decode(sof1).pixels), [100], "the independent decoder reads the 8-bit SOF1 frame")
        XCTAssertEqual([UInt8](try DicomJPEGSwiftBackend.decodeSynchronously(sof1, descriptor: extended).buffer.data), [UInt8](samples))
        let metadata = DicomDataSet(elements: [
            .init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([UInt(height)])), .init(tag: 0x00280011, vr: .US, value: .unsignedIntegers([UInt(width)])),
            .init(tag: 0x00280002, vr: .US, value: .unsignedIntegers([1])), .init(tag: 0x00280004, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: 0x00280100, vr: .US, value: .unsignedIntegers([8])), .init(tag: 0x00280101, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: 0x00280102, vr: .US, value: .unsignedIntegers([7])), .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([0]))])
        XCTAssertEqual(DicomJPEGFrameValidator.validate(metadata, frame: sof1, transferSyntax: .jpegExtended)[.codestream], .passed, "the validator no longer sees a Process 1 frame under .51")
        let baseline = Self.descriptor(.jpegBaseline, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2")
        let sof0 = try await backend.encode(DicomFrameEncodeRequest(frame: frame, descriptor: baseline, targetTransferSyntaxUID: baseline.transferSyntaxUID, intent: .irreversible(quality: 1)))
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(sof0).process, .baseline)
    }

    // MARK: - Refusals and mislabels

    func test_refusalsCoverTruncationTablesOverflowIntentAndMislabelledProcesses() async throws {
        let width = 16, height = 8
        let jpeg = try Self.imageIOJPEG(gray: Self.gray8(width, height), width: width, height: height)
        let progressive = try Self.imageIOJPEG(gray: Self.gray8(width, height), width: width, height: height, progressive: true)
        let descriptor = Self.descriptor(.jpegBaseline, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2")
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.decodeSynchronously(jpeg.prefix(jpeg.count / 2), descriptor: descriptor), "truncated scan")
        var badTables = jpeg
        if let dht = jpeg.range(of: Data([0xFF, 0xC4])) { badTables[dht.upperBound + 2] = 0xFF }
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.decodeSynchronously(badTables, descriptor: descriptor), "invalid Huffman table")
        var wrongSize = jpeg
        if let sof = jpeg.range(of: Data([0xFF, 0xC0])) { wrongSize[sof.upperBound + 3] = 0xFF; wrongSize[sof.upperBound + 4] = 0xFF }
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.decodeSynchronously(wrongSize, descriptor: descriptor), "declared dimensions overflow the descriptor")
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.decodeSynchronously(jpeg, descriptor: Self.descriptor(.jpegLossless, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2")), "DCT codestream under a lossless syntax")
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.decodeSynchronously(jpeg, descriptor: Self.descriptor(.jpegBaseline, width: width, height: height, bitsStored: 8, samples: 3, photometric: "YBR_FULL")), "component count mismatch")
        XCTAssertNil(DicomJPEGSwiftBackend().capabilities.unsupportedReason(for: descriptor))
        XCTAssertNotNil(DicomJPEGSwiftBackend().capabilities.unsupportedReason(for: Self.descriptor(.jpegBaseline, width: width, height: height, bitsStored: 8, samples: 4, photometric: "CMYK")))
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.validateDescriptor(Self.descriptor(.jpegBaseline, width: width, height: height, bitsStored: 12, samples: 1, photometric: "MONOCHROME2"), operation: .decode), "12-bit baseline")
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.validateDescriptor(Self.descriptor(.jpegExtended, width: width, height: height, bitsStored: 16, samples: 1, photometric: "MONOCHROME2"), operation: .decode), "16-bit DCT")
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.validateDescriptor(Self.descriptor(.jpegBaseline, width: width, height: height, bitsStored: 8, samples: 3, photometric: "RGB"), operation: .decode), "RGB photometric has no unambiguous transform")
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.validateEncoding(descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID, intent: .reversible), "lossy syntax without explicit intent")
        // A progressive codestream under the Baseline syntax is decoded for robustness but reported as mislabelled.
        let mislabelled = try dicomFile(jpeg: progressive, syntax: .jpegBaseline, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2")
        let report = DicomJPEGFrameValidator.validate(try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: mislabelled)), frame: progressive, transferSyntax: .jpegBaseline)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .codestreamProfileMismatch })
        XCTAssertFalse(report.diagnostics.contains { $0.code == .invalidCodestream })
        let clean = DicomJPEGFrameValidator.validate(try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: try dicomFile(jpeg: jpeg, syntax: .jpegBaseline, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2"))), frame: jpeg, transferSyntax: .jpegBaseline)
        XCTAssertFalse(clean.diagnostics.contains { $0.code == .codestreamProfileMismatch || $0.code == .invalidCodestream || $0.code == .codestreamPayloadUnverified })
        let corrupt = DicomJPEGFrameValidator.validate(try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: try dicomFile(jpeg: jpeg, syntax: .jpegBaseline, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2"))), frame: badTables, transferSyntax: .jpegBaseline)
        XCTAssertTrue(corrupt.diagnostics.contains { $0.code == .invalidCodestream })
        // Arithmetic coding is an explicit refusal of the inspector.
        var arithmetic = jpeg
        if let sof = jpeg.range(of: Data([0xFF, 0xC0])) { arithmetic[sof.lowerBound + 1] = 0xC9 }
        XCTAssertThrowsError(try DicomJPEGFrameInspector.inspect(arithmetic)) { XCTAssertEqual($0 as? DicomJPEGFrameInspector.Failure, .unsupportedProcess) }
    }

    // MARK: - DICOM pipeline and rollout

    func test_pipelineUsesTheOwnBackendAndFallsBackWhenDisabled() async throws {
        let width = 24, height = 16
        let gray = Self.gray8(width, height), rgb = Self.rgb8(width, height)
        let grayFile = try dicomFile(jpeg: try Self.imageIOJPEG(gray: gray, width: width, height: height), syntax: .jpegBaseline, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2")
        let rgbFile = try dicomFile(jpeg: try Self.imageIOJPEG(rgb: rgb, width: width, height: height), syntax: .jpegBaseline, width: width, height: height, bitsStored: 8, samples: 3, photometric: "YBR_FULL_422")
        for (label, file, expected) in [("gray", grayFile, gray), ("rgb", rgbFile, rgb)] {
            let preferred = try await DicomDecodedFrameReader(decoder: try DCMDecoder(data: file)).frameExecution(at: 0, environment: [:])
            XCTAssertEqual(preferred.backendIdentifier, "jpegswift", label)
            let pixels: [UInt8]
            switch preferred.frame.pixels {
            case .gray8(let values): pixels = values
            case .rgb8(let values): pixels = values
            default: XCTFail(label); continue
            }
            XCTAssertLessThanOrEqual(Self.maxDifference(pixels, expected), label == "gray" ? 4 : 12, "\(label): lossy 4:2:0 reference within a few LSB of the source")
            let disabled = try await DicomDecodedFrameReader(decoder: try DCMDecoder(data: file)).frameExecution(at: 0, environment: ["DICOM_JPEGSWIFT_MODE": "disabled"])
            XCTAssertEqual(disabled.backendIdentifier, "imageio-jpeg-baseline", label)
            switch (preferred.frame.pixels, disabled.frame.pixels) {
            case (.gray8(let a), .gray8(let b)): XCTAssertLessThanOrEqual(Self.maxDifference(a, b), 1, label)
            case (.rgb8(let a), .rgb8(let b)): XCTAssertLessThanOrEqual(Self.maxDifference(a, b), 8, label)
            default: XCTFail(label)
            }
            let forced = try await DicomDecodedFrameReader(decoder: try DCMDecoder(data: file)).frameExecution(at: 0, environment: ["DICOM_JPEGSWIFT_MODE": "forced-for-tests"])
            XCTAssertEqual(forced.backendIdentifier, "jpegswift", label)
            // The synchronous reader takes the same path.
            let sync = try DCMDecoder(data: file)
            XCTAssertEqual(sync.width, width, label)
            if label == "gray" { XCTAssertLessThanOrEqual(Self.maxDifference(try XCTUnwrap(sync.getPixels8()), gray), 4, label) }
        }
        let capabilities = DicomCodecCapabilities.backendStatuses(environment: [:])
        let own = try XCTUnwrap(capabilities.first { $0.identifier == "jpegswift" })
        XCTAssertTrue(own.encodeTransferSyntaxUIDs.contains(DicomTransferSyntax.jpegBaseline.rawValue))
        XCTAssertTrue(own.decodeTransferSyntaxUIDs.contains(DicomTransferSyntax.jpegLossless.rawValue))
        let decision = DicomCodecCapabilities.resolve(.init(operation: .decode, descriptor: Self.descriptor(.jpegExtended, width: 8, height: 8, bitsStored: 12, samples: 1, photometric: "MONOCHROME2")), environment: [:])
        XCTAssertEqual(decision.backendIdentifier, "jpegswift")
        let disabledDecision = DicomCodecCapabilities.resolve(.init(operation: .decode, descriptor: Self.descriptor(.jpegExtended, width: 8, height: 8, bitsStored: 12, samples: 1, photometric: "MONOCHROME2")), environment: ["DICOM_JPEGSWIFT_MODE": "disabled"])
        XCTAssertEqual(disabledDecision.backendIdentifier, "native-jpeg-extended")
    }

    func test_preferredRollout_explicitLegacyBackendWithoutFallbackIsHonored() {
        let descriptor = Self.descriptor(.jpegBaseline, width: 8, height: 8, bitsStored: 8,
                                         samples: 1, photometric: "MONOCHROME2")
        let decision = DicomCodecCapabilities.resolve(
            .init(operation: .decode, descriptor: descriptor, preferredBackend: "imageio-jpeg-baseline",
                  allowsFallback: false),
            environment: ["DICOM_JPEGSWIFT_MODE": "preferred"]
        )
        XCTAssertTrue(decision.canExecute)
        XCTAssertEqual(decision.backendIdentifier, "imageio-jpeg-baseline")
    }

    func test_disabledRollout_preferredOwnBackendHonorsFallbackPolicy() {
        let descriptor = Self.descriptor(.jpegBaseline, width: 8, height: 8, bitsStored: 8,
                                         samples: 1, photometric: "MONOCHROME2")
        for allowsFallback in [true, false] {
            let decision = DicomCodecCapabilities.resolve(
                .init(operation: .decode, descriptor: descriptor, preferredBackend: "jpegswift",
                      allowsFallback: allowsFallback),
                environment: ["DICOM_JPEGSWIFT_MODE": "disabled"]
            )
            if allowsFallback {
                XCTAssertTrue(decision.canExecute)
                XCTAssertEqual(decision.backendIdentifier, "imageio-jpeg-baseline")
            } else {
                XCTAssertFalse(decision.canExecute)
                XCTAssertNil(decision.backendIdentifier)
                XCTAssertEqual(decision.reasonCode, .profileForbidden)
            }
        }
    }

    // MARK: - Progressive export

    func test_imageExporterWritesProgressiveJPEGWithTheOwnEncoder() throws {
        let width = 12, height = 10
        // A native 8-bit source: the exporter renders frames from uncompressed pixels.
        var native = DicomDataSet(elements: [])
        let jpeg = try Self.imageIOJPEG(gray: Self.gray8(width, height), width: width, height: height)
        for element in try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: try dicomFile(jpeg: jpeg, syntax: .jpegBaseline, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2"))).elements where element.tag != DicomTag.pixelData.rawValue && element.group != 0x0002 {
            native.set(element)
        }
        native.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data(Self.gray8(width, height)))))
        let decoder = try DCMDecoder(data: try DicomDataSetWriter.part10Data(from: native))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("progressive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let progressive = directory.appendingPathComponent("frame.jpg"), sequential = directory.appendingPathComponent("baseline.jpg")
        _ = try decoder.exportImage(to: progressive, options: DicomImageExportOptions(format: .jpeg, quality: 0.9, overwrite: true, progressiveJPEG: true))
        _ = try decoder.exportImage(to: sequential, options: DicomImageExportOptions(format: .jpeg, quality: 0.9, overwrite: true))
        let exported = try DicomJPEGFrameInspector.inspect(try Data(contentsOf: progressive))
        XCTAssertEqual(exported.process, .progressive)
        XCTAssertGreaterThan(exported.scans.count, 1)
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(try Data(contentsOf: sequential)).process, .baseline)
        XCTAssertEqual(try Self.imageIODecode(try Data(contentsOf: progressive), components: 1).count, width * height, "ImageIO decodes the progressive export")
    }

    // MARK: - Transcoder routes

    func test_transcoderEncodesBaselineExtendedAndLosslessWithProvenance() async throws {
        let width = 32, height = 20
        var native8 = DicomDataSet(elements: [])
        let gray = Self.gray8(width, height)
        for element in try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: try dicomFile(jpeg: try Self.imageIOJPEG(gray: gray, width: width, height: height), syntax: .jpegBaseline, width: width, height: height, bitsStored: 8, samples: 1, photometric: "MONOCHROME2"))).elements where element.tag != DicomTag.pixelData.rawValue && element.group != 0x0002 {
            native8.set(element)
        }
        native8.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data(gray))))
        let nativeFile = try DicomDataSetWriter.part10Data(from: native8)
        let transcoder = DicomTranscoder()
        XCTAssertThrowsError(try transcoder.plan(nativeFile, to: .jpegBaseline), "baseline needs explicit loss intent")
        let plan = try transcoder.plan(nativeFile, to: .jpegBaseline, intent: .irreversible(quality: 0.9))
        XCTAssertEqual(plan.kind, .encode)
        XCTAssertTrue(plan.assignsNewSOPInstanceUID)
        XCTAssertEqual(plan.steps.last, .recordLossHistory(method: "ISO_10918_1"))
        let baselineExecution = try await transcoder.execute(plan, source: nativeFile)
        let baseline = try XCTUnwrap(baselineExecution.data)
        let decoder = try DCMDecoder(data: baseline)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegBaseline.rawValue)
        XCTAssertNotEqual(decoder.info(for: .sopInstanceUID), "2.25.23439001")
        XCTAssertEqual(decoder.dataSet.strings(for: .lossyImageCompressionMethod), ["ISO_10918_1"])
        let reader = try DicomEncapsulatedPixelFrameReader(descriptor: try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor), fileData: baseline)
        let codestream = try reader.frame(at: 0).data
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(codestream).process, .baseline)
        XCTAssertLessThanOrEqual(Self.maxDifference(try Self.imageIODecode(codestream, components: 1), gray), 6, "libjpeg-turbo decodes our baseline within a few LSB of the source")
        let legacy = try await transcoder.transcode(nativeFile, to: .jpegBaseline, intent: .irreversible(quality: 0.9))
        XCTAssertEqual(try DCMDecoder(data: legacy).info(for: .transferSyntaxUID), DicomTransferSyntax.jpegBaseline.rawValue)
        // Lossless JPEG keeps identity and samples; the decoded frame equals the native source exactly.
        let lossless = try await transcoder.transcode(nativeFile, to: .jpegLossless, intent: .reversible)
        let losslessDecoder = try DCMDecoder(data: lossless)
        XCTAssertEqual(losslessDecoder.info(for: .sopInstanceUID), "2.25.23439001")
        XCTAssertEqual(try XCTUnwrap(losslessDecoder.getPixels8()), gray)
        XCTAssertEqual(try transcoder.plan(nativeFile, to: .jpegLosslessFirstOrder).kind, .encode)
        // 12-bit native → Extended with quality; reopened through the pipeline.
        let samples = Self.gray12(width, height)
        var stored = Data()
        for value in samples { stored.append(UInt8(value & 0xFF)); stored.append(UInt8(value >> 8)) }
        var native12 = native8
        native12.set(DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])))
        native12.set(DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([12])))
        native12.set(DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([11])))
        native12.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(stored)))
        let native12File = try DicomDataSetWriter.part10Data(from: native12)
        XCTAssertThrowsError(try transcoder.plan(native12File, to: .jpegBaseline, intent: .irreversible(quality: 0.9)), "12-bit cannot be Baseline")
        let extended = try await transcoder.transcode(native12File, to: .jpegExtended, intent: .irreversible(quality: 1))
        let extendedDecoder = try DCMDecoder(data: extended)
        XCTAssertEqual(extendedDecoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegExtended.rawValue)
        let reopened = try XCTUnwrap(extendedDecoder.getPixels16())
        XCTAssertLessThanOrEqual(zip(reopened, samples).map { abs(Int($0) - Int($1)) }.max() ?? Int.max, 24)
        let back = try await transcoder.transcode(extended, to: .explicitVRLittleEndian, intent: .reversible)
        XCTAssertEqual(try DCMDecoder(data: back).info(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        // Colour: YBR_FULL declared for DCT output, decodable by ImageIO.
        let rgb = Self.rgb8(width, height)
        var nativeRGB = native8
        nativeRGB.set(DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([3])))
        nativeRGB.set(DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["RGB"])))
        nativeRGB.set(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0])))
        nativeRGB.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data(rgb))))
        let colour = try await transcoder.transcode(try DicomDataSetWriter.part10Data(from: nativeRGB), to: .jpegBaseline, intent: .irreversible(quality: 0.95))
        let colourDecoder = try DCMDecoder(data: colour)
        XCTAssertEqual(colourDecoder.info(for: .photometricInterpretation), "YBR_FULL")
        let colourReader = try DicomEncapsulatedPixelFrameReader(descriptor: try XCTUnwrap(colourDecoder.encapsulatedPixelDataDescriptor), fileData: colour)
        XCTAssertEqual(try DicomJPEGFrameInspector.inspect(try colourReader.frame(at: 0).data).chromaSubsampling.map { [$0.horizontal, $0.vertical] }, [1, 1], "no chroma subsampling on DICOM output")
        XCTAssertLessThanOrEqual(Self.maxDifference(try Self.imageIODecode(try colourReader.frame(at: 0).data, components: 3), rgb), 8)
    }

    // MARK: - JPEG backend timing comparison

    func test_measureBaselineDecodeAndEncodeAgainstImageIO() async throws {
        let width = 512, height = 512
        let gray = (0..<(width * height)).map { UInt8((($0 % width) / 2 + ($0 / width) / 3) & 0xFF) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(gray) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let jpeg = output as Data
        let descriptor = DicomCompressedFrameDescriptor(transferSyntaxUID: DicomTransferSyntax.jpegBaseline.rawValue, rows: height, columns: width,
                                                        bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0, samplesPerPixel: 1,
                                                        photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
        func time(_ iterations: Int, _ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { try body() }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000
        }
        _ = try DicomJPEGSwiftBackend.decodeSynchronously(jpeg, descriptor: descriptor)
        let own = try time(20) { _ = try DicomJPEGSwiftBackend.decodeSynchronously(jpeg, descriptor: descriptor) }
        let imageIO = time(20) {
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
            let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            var buffer = [UInt8](repeating: 0, count: width * height)
            let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let reduced = try time(20) {
            _ = try DicomJPEGSwiftBackend.decodeSynchronously(jpeg, descriptor: descriptor, scale: 4)
        }
        let frame = DicomCodecDecodedFrame(buffer: .owned(Data(gray)), width: width, height: height, bitsPerSample: 8, componentCount: 1)
        let request = DicomFrameEncodeRequest(frame: frame, descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID, intent: .irreversible(quality: 0.9))
        let backend = DicomJPEGSwiftBackend()
        let encodeStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 { _ = try await backend.encode(request) }
        let encode = Double(DispatchTime.now().uptimeNanoseconds - encodeStart) / 10 / 1_000_000
        print("JPEG-BENCH 512x512 gray8 baseline: own decode \(String(format: "%.2f", own)) ms, ImageIO decode \(String(format: "%.2f", imageIO)) ms, own decode 1/4 \(String(format: "%.2f", reduced)) ms, own encode q0.9 \(String(format: "%.2f", encode)) ms, codestream \(jpeg.count) bytes, decoded buffer \(width * height) bytes (single copy)")
    }
}
