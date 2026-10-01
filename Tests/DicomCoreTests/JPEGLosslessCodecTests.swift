import DicomCodecs
import DicomJPEG
import Foundation
import XCTest
@testable import DicomCore

/// Own JPEG lossless codec (#2327): the SOF3 encoder and the optimised decoder round-trip across precisions,
/// predictors, point transforms, restart intervals and colour; the vendored JLISwift decoder cross-checks the
/// encoder output; malformed streams fail typed; the backend, transcoder and pixel reader keep signed samples.
final class JPEGLosslessCodecTests: XCTestCase {
    // MARK: - Fixtures

    /// Deterministic noisy gradient covering the whole sample range (all difference categories appear).
    private static func samples(width: Int, height: Int, precision: Int, components: Int, seed: UInt32 = 7) -> [UInt16] {
        var state = seed
        let limit = 1 << precision
        return (0..<(width * height * components)).map { index in
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Int(state >> 8) % max(1, limit / 8)
            let x = (index / components) % width, y = (index / components) / width
            let gradient = (x * limit / max(1, width) / 2 + y * limit / max(1, height) / 4)
            return UInt16((gradient + noise + (index % components) * (limit / 16)) % limit)
        }
    }

    private static func descriptor(_ syntax: DicomTransferSyntax, width: Int, height: Int, bitsStored: Int, samples: Int = 1,
                                   photometric: String = "MONOCHROME2", signed: Bool = false) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(transferSyntaxUID: syntax.rawValue, rows: height, columns: width, bitsAllocated: bitsStored > 8 ? 16 : 8,
                                       bitsStored: bitsStored, highBit: bitsStored - 1, pixelRepresentation: signed ? 1 : 0, samplesPerPixel: samples,
                                       photometricInterpretation: photometric, planarConfiguration: samples == 3 ? 0 : nil)
    }

    private static func littleEndianBytes(_ samples: [UInt16], bitsAllocated: Int) -> Data {
        var data = Data(capacity: samples.count * (bitsAllocated > 8 ? 2 : 1))
        for value in samples {
            data.append(UInt8(value & 0xFF))
            if bitsAllocated > 8 { data.append(UInt8(value >> 8)) }
        }
        return data
    }

    private static func nativeFile(samples: [UInt16], width: Int, height: Int, bitsStored: Int, frames: Int = 1, samplesPerPixel: Int = 1,
                                   photometric: String = "MONOCHROME2", signed: Bool = false) throws -> Data {
        let bitsAllocated: UInt = bitsStored > 8 ? 16 : 8
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23270001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23270002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23270003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(samplesPerPixel)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([photometric])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([bitsAllocated])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([signed ? 1 : 0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: bitsAllocated > 8 ? .OW : .OB,
                             value: .bytes(littleEndianBytes(samples, bitsAllocated: Int(bitsAllocated))))
        ]
        if frames > 1 { elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(frames)"]))) }
        if samplesPerPixel == 3 { elements.append(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0]))) }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements))
    }

    private static func maxCodeLength(in codestream: Data) throws -> Int {
        var longest = 0
        var index = 2
        while index + 4 <= codestream.count, codestream[index] == 0xFF, codestream[index + 1] != 0xDA {
            let length = Int(codestream[index + 2]) << 8 | Int(codestream[index + 3])
            if codestream[index + 1] == 0xC4 {
                var position = index + 4
                let end = index + 2 + length
                while position + 17 <= end {
                    let counts = (0..<16).map { Int(codestream[position + 1 + $0]) }
                    longest = max(longest, (counts.lastIndex { $0 > 0 } ?? -1) + 1)
                    position += 17 + counts.reduce(0, +)
                }
            }
            index += 2 + length
        }
        return longest
    }

    // MARK: - Encoder ↔ decoder

    func test_roundTripsAcrossPrecisionsPredictorsPointTransformsRestartsAndColour() throws {
        let width = 13, height = 9
        var cases = 0
        for precision in [2, 4, 8, 12, 16] {
            for components in [1, 3] {
                let source = Self.samples(width: width, height: height, precision: precision, components: components)
                for predictor in 1...7 {
                    for pointTransform in [0, min(2, precision - 1)] {
                        for restartRows in [0, 1, 4] where predictor == 1 || restartRows == 0 || pointTransform == 0 {
                            let parameters = JPEGLosslessEncodingParameters(predictor: predictor, pointTransform: pointTransform, restartIntervalRows: restartRows)
                            let codestream = try JPEGLosslessEncoder.encode(samples: source, width: width, height: height, precision: precision,
                                                                            componentCount: components, parameters: parameters)
                            let decoded = try JPEGLosslessDecoder().decode(data: codestream)
                            let expected = source.map { ($0 >> UInt16(pointTransform)) << UInt16(pointTransform) }
                            XCTAssertEqual(decoded.pixels, expected, "P=\(precision) c=\(components) sv=\(predictor) pt=\(pointTransform) rst=\(restartRows)")
                            XCTAssertEqual(decoded.bitDepth, precision)
                            XCTAssertEqual(decoded.componentCount, components)
                            XCTAssertLessThanOrEqual(try Self.maxCodeLength(in: codestream), 16)
                            let inspection = try DicomJPEGFrameInspector.inspect(codestream)
                            XCTAssertEqual(inspection.process, .lossless)
                            XCTAssertEqual(inspection.restartInterval, restartRows * width)
                            cases += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(cases, 200)
    }

    func test_vendoredJLIDecoderAgreesWithTheOwnEncoderAndTheOwnDecoderReadsJLIEncoderOutput() throws {
        let width = 24, height = 10
        for (precision, components) in [(8, 1), (12, 1), (16, 1), (8, 3)] {
            let source = Self.samples(width: width, height: height, precision: precision, components: components, seed: 3)
            for predictor in [1, 4, 7] {
                let codestream = try JPEGLosslessEncoder.encode(samples: source, width: width, height: height, precision: precision, componentCount: components,
                                                                parameters: JPEGLosslessEncodingParameters(predictor: predictor, restartIntervalRows: predictor == 4 ? 2 : 0))
                let jli = try JLIDecoder().decode(from: [UInt8](codestream), configuration: JLIDecoderConfiguration(
                    outputPixelFormat: precision > 8 ? .uint16 : .uint8, outputColorModel: components == 3 ? .rgb : .grayscale))
                let expected = Self.littleEndianBytes(source, bitsAllocated: precision > 8 ? 16 : 8)
                XCTAssertEqual(Data(jli.data), expected, "JLISwift decodes P=\(precision) c=\(components) sv=\(predictor)")
            }
            // The vendored encoder's SOF3 output decodes exactly in the own decoder.
            let image = try JLIImage(width: width, height: height, pixelFormat: precision > 8 ? .uint16 : .uint8,
                                     colorModel: components == 3 ? .rgb : .grayscale,
                                     data: [UInt8](Self.littleEndianBytes(source, bitsAllocated: precision > 8 ? 16 : 8)), isSigned: false)
            let encoded = try JLIEncoder().encode(image, configuration: JLIEncoderConfiguration(
                lossless: true, losslessPredictor: 1, losslessPrecision: precision, optimiseHuffman: true, adaptiveQuantization: false, perceptualQuantTables: false))
            XCTAssertEqual(try JPEGLosslessDecoder().decode(data: Data(encoded)).pixels, source, "own decoder reads JLISwift P=\(precision) c=\(components)")
        }
    }

    func test_optimalTablesAreLengthLimitedWithoutAnAllOnesCode() throws {
        // Fibonacci-like frequencies force code lengths beyond 16 before the Annex K.3 adjustment.
        var histogram = [Int](repeating: 0, count: 257)
        var a = 1, b = 1
        for category in 0...16 {
            histogram[category] = a
            (a, b) = (b, a + b)
        }
        let table = JPEGLosslessEncoder.optimalTable(histogram: histogram)
        XCTAssertEqual(table.values.count, 17)
        XCTAssertEqual(table.counts.count, 16)
        let kraft = table.counts.enumerated().reduce(0.0) { $0 + Double($1.element) / pow(2, Double($1.offset + 1)) }
        XCTAssertLessThan(kraft, 1, "the reserved all-ones code is left unused")
        let codes = JPEGLosslessHuffmanCodes.canonical(symbolCounts: table.counts)
        XCTAssertEqual(codes.count, 17)
        for code in codes { XCTAssertNotEqual(code.value, (1 << code.length) - 1, "no all-ones code") }
        XCTAssertEqual(Set(table.values), Set((0...16).map { UInt8($0) }))
        // A flat image yields a single one-bit code; decoding still works through the lookup table.
        let flat = [UInt16](repeating: 5, count: 30)
        let codestream = try JPEGLosslessEncoder.encode(samples: flat, width: 6, height: 5, precision: 4, componentCount: 1)
        XCTAssertEqual(try JPEGLosslessDecoder().decode(data: codestream).pixels, flat)
        // 16-bit noise exercises categories up to 16 (difference −32768 carries no extra bits).
        var noise = Self.samples(width: 8, height: 8, precision: 16, components: 1, seed: 11)
        noise[9] = 0; noise[10] = 32768; noise[11] = 0; noise[12] = 65535
        let wide = try JPEGLosslessEncoder.encode(samples: noise, width: 8, height: 8, precision: 16, componentCount: 1,
                                                  parameters: JPEGLosslessEncodingParameters(predictor: 1))
        XCTAssertEqual(try JPEGLosslessDecoder().decode(data: wide).pixels, noise)
        XCTAssertEqual(JPEGLosslessEncoder.categorize(-32768).category, 16)
        XCTAssertEqual(JPEGLosslessEncoder.categorize(-1).bits, 0)
        XCTAssertEqual(JPEGLosslessEncoder.categorize(3).category, 2)
    }

    func test_encoderRejectsInvalidParametersAndImages() {
        let samples = Self.samples(width: 4, height: 4, precision: 8, components: 1)
        func encode(_ parameters: JPEGLosslessEncodingParameters, precision: Int = 8, samples: [UInt16] = samples, width: Int = 4, height: Int = 4) throws -> Data {
            try JPEGLosslessEncoder.encode(samples: samples, width: width, height: height, precision: precision, componentCount: 1, parameters: parameters)
        }
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(predictor: 0))) { XCTAssertEqual($0 as? JPEGLosslessEncoderError, .invalidParameters("predictor 0 must be 1...7")) }
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(predictor: 8)))
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(pointTransform: 8)))
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(restartIntervalRows: -1)))
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(restartIntervalRows: 20000))) { error in
            guard case .invalidParameters(let reason)? = error as? JPEGLosslessEncoderError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("DRI"), reason)
        }
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(), precision: 17))
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(), precision: 1))
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(), samples: [300, 0, 0, 0] + samples.dropFirst(4))) { error in
            guard case .invalidImage(let reason)? = error as? JPEGLosslessEncoderError else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("exceeds the 8-bit range"), reason)
        }
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(), samples: Array(samples.dropLast())))
        XCTAssertThrowsError(try encode(JPEGLosslessEncodingParameters(), width: 0))
        XCTAssertThrowsError(try JPEGLosslessEncoder.encode(samples: samples, width: 4, height: 4, precision: 8, componentCount: 2))
    }

    // MARK: - Malformed streams

    func test_malformedStreamsFailWithTypedReasons() throws {
        let source = Self.samples(width: 16, height: 6, precision: 12, components: 1)
        let codestream = try JPEGLosslessEncoder.encode(samples: source, width: 16, height: 6, precision: 12, componentCount: 1,
                                                        parameters: JPEGLosslessEncodingParameters(predictor: 2, restartIntervalRows: 2))
        func failure(_ data: Data) -> String {
            do { _ = try JPEGLosslessDecoder().decode(data: data); return "" } catch DICOMError.invalidDICOMFormat(let reason) { return reason } catch { return "\(error)" }
        }
        // Truncated entropy data (drop the EOI and the last bytes).
        XCTAssertTrue(failure(codestream.prefix(codestream.count - 12)).contains("Unexpected end") || failure(codestream.prefix(codestream.count - 12)).contains("expecting a JPEG restart marker"), failure(codestream.prefix(codestream.count - 12)))
        // A restart marker replaced by a non-restart marker.
        let sos = try XCTUnwrap(codestream.firstRange(of: Data([0xFF, 0xDA])))
        let firstRestart = try XCTUnwrap(codestream[sos.upperBound...].firstRange(of: Data([0xFF, 0xD0])))
        var badMarker = codestream
        badMarker[firstRestart.lowerBound + 1] = 0xC5
        XCTAssertTrue(failure(badMarker).contains("found marker 0xFFC5"), failure(badMarker))
        var swapped = codestream
        swapped[firstRestart.lowerBound + 1] = 0xD3
        XCTAssertTrue(failure(swapped).contains("expected RST0, found RST3"), failure(swapped))
        // Ah must be 0 and Al below the precision.
        var badAh = codestream
        badAh[sos.lowerBound + 9] = 0x10
        XCTAssertTrue(failure(badAh).contains("Ah"), failure(badAh))
        var badAl = codestream
        badAl[sos.lowerBound + 9] = 0x0C
        XCTAssertTrue(failure(badAl).contains("point transform"), failure(badAl))
        // DHT with more than 256 symbols.
        let dht = try XCTUnwrap(codestream.firstRange(of: Data([0xFF, 0xC4])))
        var badDHT = codestream
        for offset in 0..<16 { badDHT[dht.lowerBound + 5 + offset] = 0xFF }
        XCTAssertTrue(failure(badDHT).contains("too many symbols"), failure(badDHT))
        // Entropy data with an undefined table selector.
        var badSelector = codestream
        badSelector[sos.lowerBound + 6] = 0x30
        XCTAssertTrue(failure(badSelector).contains("undefined Huffman table"), failure(badSelector))
        // Precision outside T.81's 2...16.
        let sof = try XCTUnwrap(codestream.firstRange(of: Data([0xFF, 0xC3])))
        for precision: UInt8 in [1, 17] {
            var badPrecision = codestream
            badPrecision[sof.lowerBound + 4] = precision
            XCTAssertTrue(failure(badPrecision).contains("Unsupported SOF3 precision"), failure(badPrecision))
        }
        // Random garbage after SOS never crashes and always fails typed.
        var state: UInt32 = 99
        for _ in 0..<40 {
            var garbage = codestream
            for index in sos.upperBound..<garbage.count {
                state = state &* 1_664_525 &+ 1_013_904_223
                if state % 5 == 0 { garbage[index] = UInt8(truncatingIfNeeded: state >> 16) }
            }
            let result = try? JPEGLosslessDecoder().decode(data: garbage)
            if let result { XCTAssertEqual(result.pixels.count, source.count) }
        }
    }

    // MARK: - Backend, transcoder and pixel reader

    func test_backendEncodesWithOptionsKeepsSignedCodesAndEnforcesSV1() async throws {
        let width = 20, height = 12
        // 12-bit signed: stored two's-complement codes round-trip and come back sign-extended to 16 bits.
        let signed: [Int16] = (0..<(width * height)).map { Int16(($0 * 37) % 4096 - 2048) }
        let storedCodes = signed.map { UInt16(bitPattern: $0) & 0x0FFF }
        let descriptor = Self.descriptor(.jpegLossless, width: width, height: height, bitsStored: 12, signed: true)
        let frame = DicomCodecDecodedFrame(buffer: .owned(Self.littleEndianBytes(storedCodes, bitsAllocated: 16)), width: width, height: height, bitsPerSample: 12, componentCount: 1)
        let backend = DicomJPEGSwiftBackend()
        for intent in [DicomEncodingIntent.reversible, .jpegLossless(options: DicomJPEGLosslessEncodingOptions(predictor: 6, restartIntervalRows: 3))] {
            let codestream = try await backend.encode(DicomFrameEncodeRequest(frame: frame, descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID, intent: intent))
            XCTAssertEqual(try DicomJPEGFrameInspector.inspect(codestream).process, .lossless)
            let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
            XCTAssertEqual(decoded.buffer.data, Self.littleEndianBytes(signed.map { UInt16(bitPattern: $0) }, bitsAllocated: 16), "sign-extended 16-bit output")
            XCTAssertEqual(decoded.bitsPerSample, 12)
        }
        // Point transform is lossy: the low bits are dropped, the intent reports it, the decision names the options.
        let unsigned = Self.samples(width: width, height: height, precision: 12, components: 1)
        let unsignedDescriptor = Self.descriptor(.jpegLossless, width: width, height: height, bitsStored: 12)
        let unsignedFrame = DicomCodecDecodedFrame(buffer: .owned(Self.littleEndianBytes(unsigned, bitsAllocated: 16)), width: width, height: height, bitsPerSample: 12, componentCount: 1)
        let lossy = DicomEncodingIntent.jpegLossless(options: DicomJPEGLosslessEncodingOptions(predictor: 4, pointTransform: 3))
        XCTAssertTrue(lossy.isLossy)
        let lossyStream = try await backend.encode(DicomFrameEncodeRequest(frame: unsignedFrame, descriptor: unsignedDescriptor, targetTransferSyntaxUID: unsignedDescriptor.transferSyntaxUID, intent: lossy))
        let lossyDecoded = try await backend.decode(DicomFrameDecodeRequest(frameData: lossyStream, descriptor: unsignedDescriptor, frameIndex: 0))
        XCTAssertEqual(lossyDecoded.buffer.data, Self.littleEndianBytes(unsigned.map { ($0 >> 3) << 3 }, bitsAllocated: 16))
        let decision = DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .encode, descriptor: unsignedDescriptor, intent: lossy))
        XCTAssertTrue(decision.canExecute, decision.reason ?? "")
        XCTAssertEqual(decision.encodingIntent, "jpeg-lossless(predictor: 4, pointTransform: 3, restartIntervalRows: 0)")
        // SV1 (.70) carries predictor 1 only; other refusals are typed.
        let sv1 = Self.descriptor(.jpegLosslessFirstOrder, width: width, height: height, bitsStored: 12)
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.validateEncoding(descriptor: sv1, targetTransferSyntaxUID: sv1.transferSyntaxUID,
                                                                         intent: .jpegLossless(options: DicomJPEGLosslessEncodingOptions(predictor: 2)))) { error in
            XCTAssertTrue("\(error)".contains("predictor 1 only"), "\(error)")
        }
        XCTAssertNoThrow(try DicomJPEGSwiftBackend.validateEncoding(descriptor: sv1, targetTransferSyntaxUID: sv1.transferSyntaxUID,
                                                                     intent: .jpegLossless(options: DicomJPEGLosslessEncodingOptions(predictor: 1, restartIntervalRows: 2))))
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.validateEncoding(descriptor: unsignedDescriptor, targetTransferSyntaxUID: unsignedDescriptor.transferSyntaxUID,
                                                                         intent: .jpegLossless(options: DicomJPEGLosslessEncodingOptions(pointTransform: 12))))
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.validateEncoding(descriptor: unsignedDescriptor, targetTransferSyntaxUID: unsignedDescriptor.transferSyntaxUID,
                                                                         intent: .jpegLossless(options: DicomJPEGLosslessEncodingOptions(restartIntervalRows: 4000))))
        XCTAssertThrowsError(try DicomJPEGSwiftBackend.validateEncoding(descriptor: unsignedDescriptor, targetTransferSyntaxUID: unsignedDescriptor.transferSyntaxUID, intent: .irreversible(quality: 0.5)))
        // The lossless options are refused by the other families.
        let j2k = Self.descriptor(.jpeg2000Lossless, width: width, height: height, bitsStored: 12)
        XCTAssertFalse(DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .encode, descriptor: j2k, intent: lossy)).canExecute)
        let jls = Self.descriptor(.jpegLSLossless, width: width, height: height, bitsStored: 12)
        XCTAssertFalse(DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .encode, descriptor: jls, intent: lossy)).canExecute)
        // Reduced decode is a DCT feature.
        await XCTAssertThrowsErrorAsync(try await backend.decode(DicomFrameDecodeRequest(frameData: lossyStream, descriptor: unsignedDescriptor, frameIndex: 0,
                                                                                         partialRequest: DicomPartialDecodeRequest(resolutionLevel: 1))))
    }

    func test_transcoderAppliesLosslessOptionsAcrossMultiframeAndRecordsPointTransformLoss() async throws {
        let width = 18, height = 11, frames = 3
        let source = Self.samples(width: width, height: height * frames, precision: 12, components: 1, seed: 5)
        let file = try Self.nativeFile(samples: source, width: width, height: height, bitsStored: 12, frames: frames)
        let engine = DicomCodecWorkflowEngine()
        let options = DicomJPEGLosslessEncodingOptions(predictor: 7, restartIntervalRows: 2)
        let lossless = try await engine.transcode(file, to: .jpegLossless, intent: .jpegLossless(options: options)).data
        let decoder = try DCMDecoder(data: lossless)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegLossless.rawValue)
        XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.23270001", "reversible options keep identity")
        XCTAssertNil(decoder.dataSet.strings(for: .lossyImageCompression).first)
        let reader = try DicomEncapsulatedPixelFrameReader(descriptor: try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor), fileData: lossless)
        XCTAssertEqual(reader.frameCount, frames)
        for index in 0..<frames {
            let codestream = try reader.frame(at: index).data
            let inspection = try DicomJPEGFrameInspector.inspect(codestream)
            XCTAssertEqual(inspection.restartInterval, 2 * width)
            let decoded = try JPEGLosslessDecoder().decode(data: codestream)
            XCTAssertEqual(decoded.pixels, Array(source[(index * width * height)..<((index + 1) * width * height)]), "frame \(index)")
        }
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        XCTAssertEqual(frameReader.frameCount, frames)
        for index in 0..<frames {
            guard case .gray16(let pixels) = try await frameReader.frame(at: index).pixels else { return XCTFail("gray16 expected") }
            XCTAssertEqual(pixels, Array(source[(index * width * height)..<((index + 1) * width * height)]))
        }
        // The pixel reader path (synchronous DCMDecoder, first frame) agrees.
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), Array(source.prefix(width * height)))
        // Round trip back to native is exact for every frame.
        let back = try await engine.transcode(lossless, to: .explicitVRLittleEndian).data
        let backReader = DicomDecodedFrameReader(decoder: try DCMDecoder(data: back))
        for index in 0..<frames {
            guard case .gray16(let pixels) = try await backReader.frame(at: index).pixels else { return XCTFail("gray16 expected") }
            XCTAssertEqual(pixels, Array(source[(index * width * height)..<((index + 1) * width * height)]), "native frame \(index)")
        }
        // A point transform is lossy: new SOP Instance UID, Lossy Image Compression 01 / ISO_10918_1, samples truncated.
        let lossy = try await engine.transcode(file, to: .jpegLossless, intent: .jpegLossless(options: DicomJPEGLosslessEncodingOptions(predictor: 1, pointTransform: 2))).data
        let lossyDecoder = try DCMDecoder(data: lossy)
        XCTAssertNotEqual(lossyDecoder.info(for: .sopInstanceUID), "2.25.23270001")
        XCTAssertEqual(lossyDecoder.dataSet.strings(for: .lossyImageCompression), ["01"])
        XCTAssertEqual(lossyDecoder.dataSet.strings(for: .lossyImageCompressionMethod), ["ISO_10918_1"])
        let lossyReader = DicomDecodedFrameReader(decoder: lossyDecoder)
        for index in 0..<frames {
            guard case .gray16(let pixels) = try await lossyReader.frame(at: index).pixels else { return XCTFail("gray16 expected") }
            XCTAssertEqual(pixels, source[(index * width * height)..<((index + 1) * width * height)].map { ($0 >> 2) << 2 }, "lossy frame \(index)")
        }
        // SV1 destination refuses a predictor other than 1 at planning time.
        XCTAssertThrowsError(try engine.plan(file, to: .jpegLosslessFirstOrder, intent: .jpegLossless(options: DicomJPEGLosslessEncodingOptions(predictor: 3))))
        XCTAssertEqual(try engine.plan(file, to: .jpegLosslessFirstOrder, intent: .jpegLossless(options: DicomJPEGLosslessEncodingOptions(predictor: 1))).kind, .encode)
    }

    func test_pixelReaderSignExtendsTwelveBitSignedLosslessSamples() async throws {
        let width = 10, height = 7
        let signed: [Int16] = (0..<(width * height)).map { Int16(($0 * 53) % 4096 - 2048) }
        let file = try Self.nativeFile(samples: signed.map { UInt16(bitPattern: $0) }, width: width, height: height, bitsStored: 12, signed: true)
        let encoded = try await DicomCodecWorkflowEngine().transcode(file, to: .jpegLosslessFirstOrder).data
        let expectedOffset = signed.map { UInt16(Int($0) - Int(Int16.min)) }
        for environment in [["DICOM_JPEGSWIFT_MODE": "disabled"], [:]] {
            let decoder = try DCMDecoder(data: encoded)
            XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), expectedOffset, "pixel reader path")
            XCTAssertTrue(decoder.signedImage)
            let reader = DicomDecodedFrameReader(decoder: decoder)
            let execution = try await reader.frameExecution(at: 0, environment: environment)
            guard case .gray16(let pixels) = execution.frame.pixels else { return XCTFail("gray16 expected") }
            XCTAssertEqual(pixels, expectedOffset, "frame reader path \(environment)")
        }
        let back = try await DicomCodecWorkflowEngine().transcode(encoded, to: .explicitVRLittleEndian).data
        XCTAssertEqual(try XCTUnwrap(DCMDecoder(data: back).getPixels16()), expectedOffset)
    }

    func test_predictorsFourToSevenCarryCategoriesAbovePrecisionAndExtendedOffsetTablesDecode() async throws {
        // 8-bit, predictor 5: Ra + ((Rb − Rc) >> 1) can exceed 255, so differences reach category 9 (libjpeg-turbo does the same).
        let width = 12, height = 6
        var source = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { source[y * width + x] = (x + y) % 2 == 0 ? 255 : 0 } }
        for predictor in 4...7 {
            let codestream = try JPEGLosslessEncoder.encode(samples: source, width: width, height: height, precision: 8, componentCount: 1,
                                                            parameters: JPEGLosslessEncodingParameters(predictor: predictor))
            XCTAssertEqual(try JPEGLosslessDecoder().decode(data: codestream).pixels, source, "predictor \(predictor)")
        }
        // Part 10 with an Extended Offset Table (empty BOT) over own lossless frames decodes frame by frame.
        let frames = 4
        let multi = Self.samples(width: width, height: height * frames, precision: 12, components: 1, seed: 9)
        let file = try Self.nativeFile(samples: multi, width: width, height: height, bitsStored: 12, frames: frames)
        var dataSet = try DCMDecoder(data: file).dataSet
        let fragments = try (0..<frames).map { index in
            try JPEGLosslessEncoder.encode(samples: Array(multi[(index * width * height)..<((index + 1) * width * height)]), width: width, height: height,
                                           precision: 12, componentCount: 1, parameters: JPEGLosslessEncodingParameters(predictor: 2))
        }
        DicomTranscoder.replaceEncapsulatedPixelData(in: &dataSet, with: try DicomTranscoder.encapsulate(fragments: fragments, forceExtendedOffsets: true))
        let encoded = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .jpegLossless))
        let decoder = try DCMDecoder(data: encoded)
        XCTAssertNotNil(decoder.dataSet.element(for: .extendedOffsetTable))
        let reader = DicomDecodedFrameReader(decoder: decoder)
        XCTAssertEqual(reader.frameCount, frames)
        for index in 0..<frames {
            guard case .gray16(let pixels) = try await reader.frame(at: index).pixels else { return XCTFail("gray16 expected") }
            XCTAssertEqual(pixels, Array(multi[(index * width * height)..<((index + 1) * width * height)]), "EOT frame \(index)")
        }
    }

    // MARK: - Release timing

    func test_releaseTimingOfTheOwnLosslessCodecAgainstTheVendoredDecoder() throws {
        #if DEBUG
        throw XCTSkip("JPEG lossless timing is measured in Release only (swift test -c release -Xswiftc -enable-testing).")
        #else
        let width = 512, height = 512
        let source = Self.samples(width: width, height: height, precision: 16, components: 1, seed: 21)
        func time(_ iterations: Int, _ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { try body() }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000
        }
        let codestream = try JPEGLosslessEncoder.encode(samples: source, width: width, height: height, precision: 16, componentCount: 1)
        _ = try JPEGLosslessDecoder().decode(data: codestream)
        let ownDecode = try time(20) { _ = try JPEGLosslessDecoder().decode(data: codestream) }
        let ownEncode = try time(20) { _ = try JPEGLosslessEncoder.encode(samples: source, width: width, height: height, precision: 16, componentCount: 1) }
        let bytes = [UInt8](codestream)
        _ = try JLIDecoder().decode(from: bytes)
        let jliDecode = try time(20) { _ = try JLIDecoder().decode(from: bytes) }
        let image = try JLIImage(width: width, height: height, pixelFormat: .uint16, colorModel: .grayscale,
                                 data: [UInt8](Self.littleEndianBytes(source, bitsAllocated: 16)), isSigned: false)
        let configuration = JLIEncoderConfiguration(lossless: true, losslessPredictor: 1, losslessPrecision: 16, optimiseHuffman: true, adaptiveQuantization: false, perceptualQuantTables: false)
        let jliEncode = try time(20) { _ = try JLIEncoder().encode(image, configuration: configuration) }
        print("JPEG-LOSSLESS-BENCH 512x512 gray16 sv1: own decode \(String(format: "%.2f", ownDecode)) ms, JLISwift decode \(String(format: "%.2f", jliDecode)) ms, own encode \(String(format: "%.2f", ownEncode)) ms, JLISwift encode \(String(format: "%.2f", jliEncode)) ms, codestream \(codestream.count) bytes")
        #endif
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
