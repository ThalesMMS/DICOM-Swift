import Foundation
import XCTest
@testable import DicomCore

/// #2335: Deflated Image Frame Compression (`1.2.840.10008.1.2.8.1`) as an own capability, the RLE shape contract
/// and the dataset-deflate symmetry evidence (meta header, expansion limit, cancellation).
final class RLEDeflateCodecTests: XCTestCase {
    private static let deflatedFrames = DicomTransferSyntax.deflatedImageFrameCompression
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rle-deflate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Frame codec

    func test_unpaddedOddDeflateStream_isInspectableButCannotDecode() throws {
        let payload = Data([0x42])
        let stream = try DicomDeflatedDataSetCodec.deflate(payload)
        XCTAssertFalse(stream.count.isMultiple(of: 2))
        XCTAssertFalse(try DicomDeflatedFrameCodec.inspect(stream, expectedByteCount: 1).fragmentLengthIsEven)
        XCTAssertThrowsError(try DicomDeflatedFrameCodec.decodeFrame(stream, expectedByteCount: 1)) { error in
            XCTAssertEqual(error as? DicomDeflatedFrameError, .oddFragmentLength)
        }
        XCTAssertEqual(try DicomDeflatedFrameCodec.decodeFrame(stream + Data([0]), expectedByteCount: 1), payload)
    }

    func test_nonNullDeflatePadding_isRejectedByDecoderAndValidator() throws {
        let source = try fixture(rows: 1, columns: 1, frames: 1, bits: 8, signed: false)
        let raw = try DicomDeflatedDataSetCodec.deflate(source.pixels)
        let invalid = raw + Data([0x7F])
        XCTAssertThrowsError(try DicomDeflatedFrameCodec.decodeFrame(invalid, expectedByteCount: 1))
        XCTAssertThrowsError(try DicomDeflatedFrameCodec.inspect(invalid, expectedByteCount: 1))
        let dataSet = try DCMDecoder(data: source.object).dataSet
        XCTAssertTrue(DicomDeflatedFrameValidator.validate(dataSet, frame: invalid).diagnostics.contains { $0.code == .invalidCodestream })
    }

    func test_deflatedFrameSplitAcrossFragments_isInvalidWithoutExtendedOffsets() throws {
        let source = try fixture(frames: 1)
        let fragment = try DicomDeflatedFrameCodec.encodeFrame(source.pixels)
        let cut = max(2, fragment.count / 4 * 2)
        var dataSet = try DCMDecoder(data: source.object).dataSet
        var encapsulation = try DicomTranscoder.encapsulate(fragments: [Data(fragment.prefix(cut)), Data(fragment.dropFirst(cut))])
        // Two fragment items, one frame; remove both Basic Offset Table offsets.
        encapsulation.pixelData.replaceSubrange(4..<16, with: [UInt8](repeating: 0, count: 4))
        DicomTranscoder.replaceEncapsulatedPixelData(in: &dataSet, with: encapsulation)
        let object = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: Self.deflatedFrames))
        let reader = try DCMDecoder(data: object).makeEncapsulatedPixelFrameReader()
        XCTAssertEqual(reader.frameCount, 1)
        XCTAssertEqual(reader.descriptor.frameFragmentIndexes[0].count, 2)
        let report = try DicomInstanceValidator.validate(object)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .invalidDataSetStructure && $0.path.contains(.frame(0)) })
        XCTAssertThrowsError(try DicomTranscoder().transcode(object, to: .explicitVRLittleEndian))
    }

    func test_frameCodec_padsOddStreamsBoundsOutputAndFailsTyped() throws {
        var frameBytes: [UInt8] = []
        for index in 0..<1000 { frameBytes.append(UInt8((index * 7 + index / 13) & 0xFF)) }
        var frame = Data(frameBytes)
        frame.append(Data(repeating: 0x2A, count: 700))
        let encoded = try DicomDeflatedFrameCodec.encodeFrame(frame)
        XCTAssertTrue(encoded.count.isMultiple(of: 2))
        XCTAssertLessThan(encoded.count, frame.count, "real compression, not a byte copy")
        XCTAssertEqual(try DicomDeflatedFrameCodec.decodeFrame(encoded, expectedByteCount: frame.count), frame)
        let inspection = try DicomDeflatedFrameCodec.inspect(encoded, expectedByteCount: frame.count)
        XCTAssertEqual(inspection.inflatedByteCount, frame.count)
        XCTAssertLessThanOrEqual(inspection.trailingByteCount, 1)
        XCTAssertEqual(inspection.streamByteCount + inspection.trailingByteCount, encoded.count)
        XCTAssertTrue(inspection.fragmentLengthIsEven)
        // Every payload size yields an even fragment, and padding is at most one NULL byte.
        var sawPadding = false
        for size in 1...64 {
            let payload = Data((0..<size).map { UInt8($0 * 37 & 0xFF) })
            let fragment = try DicomDeflatedFrameCodec.encodeFrame(payload)
            XCTAssertTrue(fragment.count.isMultiple(of: 2), "size \(size)")
            let report = try DicomDeflatedFrameCodec.inspect(fragment, expectedByteCount: size)
            sawPadding = sawPadding || report.trailingByteCount == 1
            if report.trailingByteCount == 1 { XCTAssertEqual(fragment.last, 0, "size \(size): the pad is a NULL byte") }
            XCTAssertEqual(try DicomDeflatedFrameCodec.decodeFrame(fragment, expectedByteCount: size), payload)
        }
        XCTAssertTrue(sawPadding, "at least one odd stream exercised the pad")

        func failure(_ fragment: Data, expected: Int) -> DicomDeflatedFrameError? {
            do { _ = try DicomDeflatedFrameCodec.decodeFrame(fragment, expectedByteCount: expected); return nil }
            catch let error as DicomDeflatedFrameError { return error }
            catch { return nil }
        }
        // Output is bounded by the declared frame length before any byte is kept.
        XCTAssertEqual(failure(encoded, expected: frame.count - 1), .outputExceedsFrame(expected: frame.count - 1))
        XCTAssertEqual(failure(encoded, expected: frame.count + 1), .lengthMismatch(expected: frame.count + 1, actual: frame.count))
        XCTAssertEqual(failure(encoded + Data([0, 0]), expected: frame.count), .trailingBytes(count: 2 + inspection.trailingByteCount))
        guard case .inflateFailed = failure(encoded.prefix(encoded.count / 2), expected: frame.count) else { return XCTFail("truncated stream") }
        guard case .inflateFailed = failure(Data([0xFF, 0xFF, 0xFF, 0xFF]), expected: frame.count) else { return XCTFail("garbage stream") }
        XCTAssertEqual(failure(Data(), expected: frame.count), .emptyFragment)
        XCTAssertEqual(failure(Data([0x03]), expected: frame.count), .emptyFragment)
        XCTAssertEqual(failure(encoded, expected: 0), .invalidFrameShape)
        XCTAssertEqual(DicomDeflatedFrameCodec.frameByteCount(rows: 3, columns: 3, samplesPerPixel: 1, bitsAllocated: 1), 2)
        XCTAssertEqual(DicomDeflatedFrameCodec.frameByteCount(rows: 8, columns: 9, samplesPerPixel: 1, bitsAllocated: 1), 9)
        XCTAssertEqual(DicomDeflatedFrameCodec.frameByteCount(rows: 2, columns: 2, samplesPerPixel: 3, bitsAllocated: 16), 24)
        XCTAssertNil(DicomDeflatedFrameCodec.frameByteCount(rows: Int.max, columns: 2, samplesPerPixel: 1, bitsAllocated: 8))
    }

    // MARK: - Transcoder routes

    func test_fileExecution_preservesPackedOneBitFramesAndBigEndianSamples() async throws {
        let transcoder = DicomTranscoder()
        let fixtures = [
            try fixture(rows: 3, columns: 3, frames: 9, bits: 1, signed: false),
            try fixture(rows: 1, columns: 1, frames: 11, bits: 1, signed: false),
            try fixture(frames: 2, syntax: .explicitVRBigEndian)
        ]
        for (index, source) in fixtures.enumerated() {
            let compressedURL = directory.appendingPathComponent("stream-\(index).dcm")
            let plan = try transcoder.plan(source.object, to: Self.deflatedFrames)
            _ = try await transcoder.execute(plan, source: source.object, destinationURL: compressedURL)
            let compressed = try Data(contentsOf: compressedURL)
            let nativeURL = directory.appendingPathComponent("native-\(index).dcm")
            let decodePlan = try transcoder.plan(compressed, to: .explicitVRLittleEndian)
            _ = try await transcoder.execute(decodePlan, source: compressed, destinationURL: nativeURL)
            let native = try Data(contentsOf: nativeURL)
            if source.bits == 1 {
                XCTAssertEqual(try nativePixelBytes(native), source.pixels)
            } else {
                XCTAssertEqual(try decodedFrames(native), try decodedFrames(source.object))
            }
        }
    }

    func test_nativeSourcesDeflateTheirOwnFrameBytesAtAnyBitsAllocated() async throws {
        let transcoder = DicomTranscoder()
        let cases: [(String, Fixture)] = [
            ("gray16-signed", try fixture(frames: 3)),
            ("rgb8", try fixture(frames: 2, samples: 3, bits: 8, signed: false, photometric: "RGB", planar: 0)),
            ("rgb8-planar1", try fixture(frames: 2, samples: 3, bits: 8, signed: false, photometric: "RGB", planar: 1)),
            ("mono1-8", try fixture(frames: 2, bits: 8, signed: false, photometric: "MONOCHROME1")),
            ("bilevel", try fixture(rows: 8, columns: 9, frames: 2, bits: 1, signed: false)),
            ("bilevel-shared-bytes", try fixture(rows: 3, columns: 3, frames: 9, bits: 1, signed: false)),
            ("bilevel-single-pixel", try fixture(rows: 1, columns: 1, frames: 11, bits: 1, signed: false)),
            ("gray32", try fixture(frames: 2, bits: 32, signed: false)),
            ("rgb16", try fixture(frames: 1, samples: 3, bits: 16, signed: false, photometric: "RGB", planar: 0)),
            ("odd-frame-bytes", try fixture(rows: 3, columns: 5, frames: 3, bits: 8, signed: false))
        ]
        for (label, fixture) in cases {
            let out = try transcoder.transcode(fixture.object, to: Self.deflatedFrames)
            let decoder = try DCMDecoder(data: out)
            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), Self.deflatedFrames.rawValue, label)
            XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.23350001", "\(label): reversible keeps identity")
            XCTAssertEqual(decoder.info(for: .photometricInterpretation), fixture.photometric, "\(label): attributes untouched")
            XCTAssertEqual(decoder.intValue(for: .planarConfiguration), fixture.planar, label)
            XCTAssertEqual(decoder.intValue(for: .bitsAllocated), fixture.bits, label)
            let reader = try decoder.makeEncapsulatedPixelFrameReader()
            XCTAssertEqual(reader.frameCount, fixture.frames, label)
            for index in 0..<fixture.frames {
                let fragment = try reader.frameData(at: index)
                XCTAssertTrue(fragment.count.isMultiple(of: 2), "\(label): fragment \(index) is even")
                XCTAssertEqual(try DicomDeflatedDataSetCodec.inflate(fragment), fixture.frame(index), "\(label): frame \(index) inflates to the native bytes")
            }
            let asyncOut = try await transcoder.transcode(fixture.object, to: Self.deflatedFrames, intent: .reversible)
            XCTAssertEqual(asyncOut, out, "\(label): async and sync produce the same object")
            for destination in [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian, .deflatedExplicitVRLittleEndian] {
                let back = try await transcoder.transcode(out, to: destination, intent: .reversible)
                if destination != .deflatedExplicitVRLittleEndian {
                    XCTAssertEqual(back, try transcoder.transcode(out, to: destination), "\(label) → \(destination): sync equals async")
                }
                let backDecoder = try DCMDecoder(data: back)
                XCTAssertEqual(backDecoder.info(for: .transferSyntaxUID), destination.rawValue, label)
                XCTAssertEqual(try nativePixelBytes(back), fixture.pixels, "\(label) → \(destination): exact native bytes")
                XCTAssertEqual(backDecoder.info(for: .photometricInterpretation), fixture.photometric, label)
                XCTAssertEqual(backDecoder.intValue(for: .planarConfiguration), fixture.planar, label)
            }
            if [8, 16].contains(fixture.bits), fixture.samples == 1 || fixture.bits == 8 {
                XCTAssertEqual(try decodedFrames(out), try decodedFrames(fixture.object), "\(label): typed frames match the native decode")
            } else {
                XCTAssertThrowsError(try decodedFrames(out), "\(label): shapes outside the typed pipeline fail typed")
                XCTAssertThrowsError(try decodedFrames(fixture.object), label)
            }
        }
        // Big-endian 16-bit sources go through the decoded path, so the frames come out little endian.
        let bigEndian = try fixture(frames: 2, syntax: .explicitVRBigEndian)
        let fromBigEndian = try transcoder.transcode(bigEndian.object, to: Self.deflatedFrames)
        XCTAssertEqual(try decodedFrames(fromBigEndian), try decodedFrames(bigEndian.object))
        let firstFragment = try DCMDecoder(data: fromBigEndian).makeEncapsulatedPixelFrameReader().frameData(at: 0)
        XCTAssertEqual(try DicomDeflatedDataSetCodec.inflate(firstFragment), bigEndian.frame(0).byteSwapped16())
    }

    func test_compressedSourcesDecodeThenDeflateAndReachOtherCodecs() async throws {
        let transcoder = DicomTranscoder()
        for (label, fixture) in [("gray16", try fixture(frames: 3)), ("rgb", try fixture(frames: 2, samples: 3, bits: 8, signed: false, photometric: "RGB", planar: 1))] {
            let rle = try transcoder.transcode(fixture.object, to: .rleLossless)
            // Compressed → compressed is an async route, as for every other codec pair.
            let deflated = try await transcoder.transcode(rle, to: Self.deflatedFrames, intent: .reversible)
            let decoder = try DCMDecoder(data: deflated)
            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), Self.deflatedFrames.rawValue, label)
            if fixture.samples == 3 {
                XCTAssertEqual(decoder.info(for: .photometricInterpretation), "RGB", label)
                XCTAssertEqual(decoder.intValue(for: .planarConfiguration), 0, "\(label): decoded colour frames are interleaved")
            }
            let reader = try decoder.makeEncapsulatedPixelFrameReader()
            let expected = try decodedFrames(fixture.object)
            for index in 0..<fixture.frames {
                // Decoded frames are re-serialised as stored bytes: signed samples keep their two's complement,
                // planar colour becomes interleaved.
                let stored = fixture.planar == 1 ? fixture.interleavedFrame(index) : fixture.frame(index)
                XCTAssertEqual(try DicomDeflatedDataSetCodec.inflate(try reader.frameData(at: index)), stored, "\(label): frame \(index)")
            }
            XCTAssertEqual(try decodedFrames(deflated), expected, label)
            let toRLE = try await transcoder.transcode(deflated, to: .rleLossless, intent: .reversible)
            XCTAssertEqual(try decodedFrames(toRLE), expected, "\(label): .8.1 → RLE")
            let toJLS = try await transcoder.transcode(deflated, to: .jpegLSLossless, intent: .reversible)
            XCTAssertEqual(try decodedFrames(toJLS), expected, "\(label): .8.1 → JPEG-LS")
        }
        XCTAssertThrowsError(try transcoder.plan(try fixture(frames: 1).object, to: Self.deflatedFrames, intent: .irreversible(quality: 0.5)))
        // A decoded source outside the typed pipeline is refused with the shape reason.
        let rle32 = try fixture(frames: 1, bits: 32, signed: false)
        XCTAssertThrowsError(try transcoder.plan(rle32.object, to: .rleLossless)) { error in
            guard case DicomTranscoder.TranscodeError.unsupportedPixelShape = error else { return XCTFail("\(error)") }
        }
    }

    func test_plansAndStreamingExecutionMatchTheInMemoryEngine() async throws {
        let transcoder = DicomTranscoder()
        let gray = try fixture(frames: 3), bilevel = try fixture(rows: 8, columns: 9, frames: 2, bits: 1, signed: false)
        let encodePlan = try transcoder.plan(gray.object, to: Self.deflatedFrames)
        XCTAssertEqual(encodePlan.kind, .encode)
        XCTAssertEqual(encodePlan.steps, [.carryDataset, .encodeFrames(frames: 3, codec: "deflated-frames"), .encapsulate(offsetTables: .basic)])
        XCTAssertTrue(encodePlan.isStreamable)
        XCTAssertFalse(encodePlan.assignsNewSOPInstanceUID)
        for (label, fixture) in [("gray16", gray), ("bilevel", bilevel)] {
            let plan = try transcoder.plan(fixture.object, to: Self.deflatedFrames)
            let output = directory.appendingPathComponent("\(label).dcm")
            let streamed = try await transcoder.execute(plan, source: fixture.object, destinationURL: output)
            XCTAssertEqual(streamed.frames.count, fixture.frames, label)
            let streamedBytes = try Data(contentsOf: output)
            let inMemory = try transcoder.transcode(fixture.object, to: Self.deflatedFrames)
            XCTAssertEqual(streamedBytes, inMemory, "\(label): streaming equals memory")
            let decodePlan = try transcoder.plan(streamedBytes, to: .explicitVRLittleEndian)
            XCTAssertEqual(decodePlan.kind, .decode, label)
            XCTAssertEqual(decodePlan.steps, [.carryDataset, .decodeFrames(frames: fixture.frames, codec: "deflated-frames"), .writeNativePixels(frames: fixture.frames)], label)
            let back = directory.appendingPathComponent("\(label)-native.dcm")
            _ = try await transcoder.execute(decodePlan, source: streamedBytes, destinationURL: back)
            let backBytes = try Data(contentsOf: back)
            let backInMemory = try transcoder.transcode(streamedBytes, to: .explicitVRLittleEndian)
            XCTAssertEqual(backBytes, backInMemory, "\(label): streamed decode equals memory")
            XCTAssertEqual(try nativePixelBytes(backBytes), fixture.pixels, label)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".") })
    }

    func test_malformedFragmentsFailTypedWithoutPartialOutput() async throws {
        let transcoder = DicomTranscoder()
        let fixture = try fixture(frames: 2)
        let valid = try transcoder.transcode(fixture.object, to: Self.deflatedFrames)
        let validReport = try DicomInstanceValidator.validate(valid)
        XCTAssertFalse(validReport.diagnostics.contains { $0.severity == .error && [.codestream, .pixelsAndGeometry].contains($0.layer) },
                       "\(validReport.diagnostics)")
        let fragments = try (0..<2).map { try DCMDecoder(data: valid).makeEncapsulatedPixelFrameReader().frameData(at: $0) }
        let mutations: [(String, [Data], DicomValidationReport.Code)] = [
            ("truncated", [fragments[0], fragments[1].prefix(fragments[1].count / 2)], .invalidCodestream),
            ("garbage", [Data([0xFF, 0xFF, 0xFF, 0xFF]), fragments[1]], .invalidCodestream),
            ("short-frame", [fragments[0], try DicomDeflatedFrameCodec.encodeFrame(fixture.frame(1).dropLast(2))], .pixelMetadataContradiction),
            ("long-frame", [try DicomDeflatedFrameCodec.encodeFrame(fixture.frame(0) + Data([1, 2])), fragments[1]], .pixelMetadataContradiction),
            ("trailing-garbage", [fragments[0], fragments[1] + Data([7, 7, 7, 7])], .invalidCodestream)
        ]
        for (label, mutated, code) in mutations {
            let object = try encapsulatedObject(fragments: mutated, template: valid)
            let broken = mutated[0] == fragments[0] ? 1 : 0
            let reader = DicomDecodedFrameReader(decoder: try DCMDecoder(data: object))
            XCTAssertThrowsError(try Self.frame(reader, broken), label) { error in
                guard case DicomDecodedFrameReader.ReadError.decodeFailed = error else { return XCTFail("\(label): \(error)") }
            }
            XCTAssertNoThrow(try Self.frame(reader, 1 - broken), "\(label): the intact frame still decodes")
            XCTAssertThrowsError(try transcoder.transcode(object, to: .explicitVRLittleEndian), label) { error in
                guard case DicomTranscoder.TranscodeError.decodeFailed = error else { return XCTFail("\(label): \(error)") }
            }
            let output = directory.appendingPathComponent("\(label).dcm")
            do {
                _ = try await transcoder.execute(try transcoder.plan(object, to: .explicitVRLittleEndian), source: object, destinationURL: output)
                XCTFail("\(label): streamed decode must fail")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(label): no partial output")
            }
            let report = try DicomInstanceValidator.validate(object)
            XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path.contains(.frame(broken)) },
                          "\(label): expected \(code) at frame \(broken) in \(report.diagnostics)")
        }
        // Direct validator: an odd fragment length is the missing pad, trailing bytes beyond the pad are a codestream error.
        let dataSet = try DCMDecoder(data: valid).dataSet
        let inspection = try DicomDeflatedFrameCodec.inspect(fragments[0], expectedByteCount: fixture.frame(0).count)
        let odd = inspection.trailingByteCount == 1 ? fragments[0].dropLast() : fragments[0] + Data([0])
        XCTAssertTrue(DicomDeflatedFrameValidator.validate(dataSet, frame: Data(odd)).diagnostics.contains { $0.code == .codestreamSegmentPaddingMissing })
        XCTAssertFalse(DicomDeflatedFrameValidator.validate(dataSet, frame: fragments[0]).diagnostics.contains { $0.severity == .error })
        XCTAssertTrue(DicomDeflatedFrameValidator.validate(dataSet, frame: fragments[0], transferSyntax: .rleLossless)
            .diagnostics.contains { $0.code == .codestreamRuleUnavailable })
        XCTAssertTrue(DicomDeflatedFrameValidator.validate(dataSet, frame: fragments[0], maximumEncodedBytes: 4)
            .diagnostics.contains { $0.code == .evaluationLimitReached })
    }

    func test_cancellationLeavesNoPartialObjectAndDatasetDeflateLoadIsCancellable() async throws {
        let fixture = try fixture(rows: 512, columns: 512, frames: 4)
        let destination = directory.appendingPathComponent("cancelled.dcm")
        let source = fixture.object
        let target = Self.deflatedFrames
        let task = Task<Int, Error> {
            let result = try await DicomCodecWorkflowEngine().transcode(
                source, to: target, intent: .reversible, verifyDecodedPixels: false, destinationURL: destination, progress: nil)
            return result.data.count
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTAssertNoThrow(try DCMDecoder(data: try Data(contentsOf: destination)))
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "no partial output after cancellation")
        }
        let deflatedFile = directory.appendingPathComponent("dataset-deflate.dcm")
        try await DicomTranscoder().transcode(source, to: .deflatedExplicitVRLittleEndian, intent: .reversible).write(to: deflatedFile)
        let load = Task<Int, Error> { try await DCMDecoder.load(from: deflatedFile).nImages }
        load.cancel()
        do {
            _ = try await load.value
            XCTFail("a cancelled load must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    // MARK: - Registry, capabilities, negotiation

    func test_registryCapabilitiesAndNegotiationDescribeTheNewSyntax() throws {
        let entry = try XCTUnwrap(DicomTransferSyntaxRegistry.standard.entry(for: Self.deflatedFrames))
        XCTAssertEqual(entry.codec, .deflatedFrames)
        XCTAssertTrue(entry.isCompressed && entry.isEncapsulated && entry.isLossless)
        XCTAssertEqual(entry.decoderSupport, .supported)
        XCTAssertEqual(entry.encoderSupport, .supported)
        XCTAssertEqual(DicomTransferSyntaxRegistry.standard.compressedPixelSupport(for: Self.deflatedFrames)?.status, .decoded)
        XCTAssertEqual(DicomCodecFamily.family(for: Self.deflatedFrames), .deflatedFrames)
        XCTAssertTrue(Self.deflatedFrames.isCompressed)
        XCTAssertFalse(Self.deflatedFrames.usesDataSetDeflate, "frame deflate is not dataset deflate")
        let descriptor = DicomCompressedFrameDescriptor(
            transferSyntaxUID: Self.deflatedFrames.rawValue, rows: 4, columns: 6, bitsAllocated: 16, bitsStored: 16, highBit: 15,
            pixelRepresentation: 1, samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
        for operation in [DicomCodecOperation.decode, .encode] {
            let decision = DicomCodecCapabilities.resolve(.init(operation: operation, descriptor: descriptor, intent: .reversible))
            XCTAssertTrue(decision.canExecute, "\(operation): \(decision.reason ?? "")")
            XCTAssertEqual(decision.backendIdentifier, "native-deflated-frames")
        }
        XCTAssertFalse(DicomCodecCapabilities.resolve(.init(operation: .encode, descriptor: descriptor, intent: .irreversible(quality: 0.5))).canExecute)
        let selection = try DicomWebMediaTypeNegotiator.rawFrameSelection(
            accept: "multipart/related; type=\"application/x-deflate\"; transfer-syntax=\(Self.deflatedFrames.rawValue)",
            transferSyntax: Self.deflatedFrames, isCompressed: true)
        XCTAssertEqual(selection.mediaType, "application/x-deflate")
        XCTAssertEqual(selection.transferSyntaxUID, Self.deflatedFrames.rawValue)
        XCTAssertThrowsError(try DicomWebMediaTypeNegotiator.rawFrameSelection(
            accept: "multipart/related; type=\"image/dicom-rle\"", transferSyntax: Self.deflatedFrames, isCompressed: true))
    }

    // MARK: - RLE shape contract

    func test_rleShapeContractIsTypedAndDecodeMatchesNativeForEveryAcceptedPhotometric() throws {
        let transcoder = DicomTranscoder()
        for (label, fixture) in [("rgb16", try fixture(frames: 1, samples: 3, bits: 16, signed: false, photometric: "RGB", planar: 0)),
                                 ("gray32", try fixture(frames: 1, bits: 32, signed: false)),
                                 ("bilevel", try fixture(rows: 8, columns: 8, frames: 1, bits: 1, signed: false))] {
            XCTAssertThrowsError(try transcoder.plan(fixture.object, to: .rleLossless), label) { error in
                guard case DicomTranscoder.TranscodeError.unsupportedPixelShape = error else { return XCTFail("\(label): \(error)") }
            }
        }
        let frame = try DicomRLECodec.encodeFrame(Data(repeating: 3, count: 4 * 6 * 3 * 2), width: 6, height: 4, samplesPerPixel: 3, bytesPerSample: 2)
        XCTAssertEqual(try DicomRLECodec.inspect(frame, width: 6, height: 4).segmentCount, 6, "the codec itself packs 16-bit colour")
        XCTAssertThrowsError(try DicomRLECodec.encodeFrame(Data(count: 4 * 6 * 4 * 4), width: 6, height: 4, samplesPerPixel: 4, bytesPerSample: 4)) { error in
            XCTAssertEqual(error as? DicomRLECodec.EncodeFailure, .tooManySegments(16))
        }
        for (bits, samples) in [(32, 1), (16, 3), (1, 1), (8, 4)] {
            XCTAssertThrowsError(try DicomRLELosslessDecoder.decode(frame: frame, width: 6, height: 4, bitsAllocated: bits, samplesPerPixel: samples,
                                                                    pixelRepresentation: 0, photometricInterpretation: "RGB"), "\(bits)/\(samples)") { error in
                guard case DICOMError.invalidPixelData = error else { return XCTFail("\(error)") }
            }
        }
        // Whatever the typed pipeline yields for a native object, the RLE object with the same samples yields too.
        for (label, fixture) in [("ybr-full", try fixture(frames: 2, samples: 3, bits: 8, signed: false, photometric: "YBR_FULL", planar: 0)),
                                 ("palette", try fixture(frames: 2, bits: 8, signed: false, photometric: "PALETTE COLOR")),
                                 ("gray8-signed", try fixture(frames: 2, bits: 8, signed: true)),
                                 ("mono1-16", try fixture(frames: 2, photometric: "MONOCHROME1"))] {
            let fragments = try (0..<fixture.frames).map {
                try DicomRLECodec.encodeFrame(fixture.frame($0), width: fixture.columns, height: fixture.rows,
                                              samplesPerPixel: fixture.samples, bytesPerSample: fixture.bits / 8)
            }
            var dataSet = try DCMDecoder(data: fixture.object).dataSet
            DicomTranscoder.replaceEncapsulatedPixelData(in: &dataSet, with: try DicomTranscoder.encapsulate(fragments: fragments))
            let rle = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .rleLossless))
            XCTAssertEqual(try decodedFrames(rle), try decodedFrames(fixture.object), label)
            let report = try DicomInstanceValidator.validate(rle)
            XCTAssertFalse(report.diagnostics.contains { $0.severity == .error && $0.layer == .codestream }, "\(label): \(report.diagnostics)")
        }
    }

    func test_deflatedYBRFull422_preservesNativeBytesAndDecodesRGB8() async throws {
        let packed8 = Data([0, 255, 128, 128, 76, 150, 85, 255, 16, 200, 128, 128, 100, 180, 255, 64])
        let transcoder = DicomTranscoder()
        for bits in [8, 16] {
            let template = try fixture(rows: 1, columns: 4, frames: 2, samples: 3, bits: bits, signed: false,
                                       photometric: "YBR_FULL_422", planar: 0)
            let packed = bits == 8 ? packed8 : Data(packed8.flatMap { [$0, UInt8(0)] })
            var dataSet = try DCMDecoder(data: template.object).dataSet
            dataSet.set(.init(tag: DicomTag.pixelData.rawValue, vr: bits == 8 ? .OB : .OW, value: .bytes(packed)))
            let source = try DicomDataSetWriter.part10Data(from: dataSet)
            let encoded = try transcoder.transcode(source, to: Self.deflatedFrames)
            let encodedAsync = try await transcoder.transcode(source, to: Self.deflatedFrames, intent: .reversible)
            for object in [encoded, encodedAsync] {
                let decoder = try DCMDecoder(data: object)
                let reader = try decoder.makeEncapsulatedPixelFrameReader()
                let frameBytes = 8 * bits / 8
                for index in 0..<2 {
                    XCTAssertEqual(try DicomDeflatedFrameCodec.decodeFrame(try reader.frameData(at: index), expectedByteCount: frameBytes),
                                   packed.subdata(in: index * frameBytes..<(index + 1) * frameBytes))
                }
                let restored = try transcoder.transcode(object, to: .explicitVRLittleEndian)
                XCTAssertEqual(try nativePixelBytes(restored), packed)
                XCTAssertEqual(try DCMDecoder(data: restored).photometricInterpretation, "YBR_FULL_422")
                let report = try DicomInstanceValidator.validate(object)
                XCTAssertFalse(report.diagnostics.contains { $0.code == .invalidCodestream || $0.code == .pixelMetadataContradiction }, "\(report.diagnostics)")
                if bits == 8 {
                    let reference = try DCMDecoder(data: source)
                    let expected = try (0..<2).map { try reference.displayRGBPixelBuffer(frame: $0).rgbData }
                    XCTAssertEqual(try decodedFrames(object), expected)
                    XCTAssertEqual(Array(expected[0].prefix(6)), [0, 0, 0, 255, 255, 255])
                }
            }
        }
        XCTAssertNil(DicomDeflatedFrameCodec.frameByteCount(rows: 1, columns: 3, samplesPerPixel: 3,
                                                           bitsAllocated: 8, photometricInterpretation: "YBR_FULL_422"))
    }

    // MARK: - Dataset deflate

    func test_datasetDeflateKeepsTheMetaHeaderEnforcesTheLimitAndStaysSeparateFromFrameDeflate() async throws {
        let transcoder = DicomTranscoder()
        let fixture = try fixture(frames: 3)
        let deflated = try await transcoder.transcode(fixture.object, to: .deflatedExplicitVRLittleEndian, intent: .reversible)
        let meta = try DicomPart10FileMetaParser.parse(deflated)
        XCTAssertEqual(meta.transferSyntaxUID, DicomTransferSyntax.deflatedExplicitVRLittleEndian.rawValue, "the meta header stays explicit VR")
        XCTAssertEqual(meta.mediaStorageSOPInstanceUID, "2.25.23350001")
        XCTAssertNil(deflated.range(of: Data("MONOCHROME2".utf8)), "the dataset body is deflated")
        let inflated = try DicomDeflatedDataSetCodec.inflatedPart10DataIfNeeded(deflated)
        XCTAssertEqual(inflated.prefix(meta.dataSetOffset), deflated.prefix(meta.dataSetOffset))
        XCTAssertNotNil(inflated.range(of: Data("MONOCHROME2".utf8)))
        XCTAssertThrowsError(try DicomDeflatedDataSetCodec.inflatedPart10DataIfNeeded(deflated, inflatedSizeLimit: 64)) { error in
            guard case DicomDeflatedDataSetError.dataSetTooLarge = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try nativePixelBytes(deflated), fixture.pixels)
        XCTAssertEqual(try decodedFrames(deflated), try decodedFrames(fixture.object))
        for payload in [Data(), Data([0x42]), Data((0..<300_000).map { UInt8(($0 * 31) & 0xFF) })] {
            let stream = try DicomDeflatedDataSetCodec.deflate(payload)
            let (back, consumed) = try DicomDeflatedDataSetCodec.inflateReportingConsumedBytes(stream)
            XCTAssertEqual(back, payload)
            XCTAssertEqual(consumed, stream.count)
        }
        // Both deflate mechanisms compose without being confused for one another.
        let frames = try await transcoder.transcode(deflated, to: Self.deflatedFrames, intent: .reversible)
        XCTAssertEqual(try DCMDecoder(data: frames).info(for: .transferSyntaxUID), Self.deflatedFrames.rawValue)
        XCTAssertEqual(try DicomDeflatedDataSetCodec.inflate(try DCMDecoder(data: frames).makeEncapsulatedPixelFrameReader().frameData(at: 2)), fixture.frame(2))
        let both = try await transcoder.transcode(frames, to: .deflatedExplicitVRLittleEndian, intent: .reversible)
        XCTAssertEqual(try DicomPart10FileMetaParser.parse(both).transferSyntaxUID, DicomTransferSyntax.deflatedExplicitVRLittleEndian.rawValue)
        XCTAssertEqual(try nativePixelBytes(both), fixture.pixels)
        XCTAssertEqual(try transcoder.plan(frames, to: .deflatedExplicitVRLittleEndian).steps,
                       [.carryDataset, .decodeFrames(frames: 3, codec: "deflated-frames"), .writeNativePixels(frames: 3), .deflateDataset])
    }

    // MARK: - Fixtures

    private struct Fixture {
        let object: Data
        let pixels: Data
        let rows: Int, columns: Int, frames: Int, samples: Int, bits: Int
        let photometric: String
        let planar: Int?
        var frameBytes: Int { (rows * columns * samples * bits + 7) / 8 }
        func frame(_ index: Int) -> Data {
            guard bits == 1 else { return pixels.subdata(in: index * frameBytes..<(index + 1) * frameBytes) }
            var frame = Data(count: frameBytes)
            for pixel in 0..<(rows * columns * samples) {
                let sourceBit = index * rows * columns * samples + pixel
                let value = (pixels[sourceBit / 8] >> (sourceBit % 8)) & 1
                frame[pixel / 8] |= value << (pixel % 8)
            }
            return frame
        }
        /// Planar configuration 1 frame re-ordered as interleaved samples (8-bit only).
        func interleavedFrame(_ index: Int) -> Data {
            let plane = frame(index), pixelsPerFrame = rows * columns
            var out = Data(count: plane.count)
            for pixel in 0..<pixelsPerFrame { for sample in 0..<samples { out[pixel * samples + sample] = plane[sample * pixelsPerFrame + pixel] } }
            return out
        }
    }

    private func str(_ tag: DicomTag, _ vr: DicomVR, _ values: [String]) -> DicomDataElement { DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings(values)) }
    private func num(_ tag: DicomTag, _ value: UInt) -> DicomDataElement { DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value])) }

    private func fixture(rows: Int = 4, columns: Int = 6, frames: Int, samples: Int = 1, bits: Int = 16, signed: Bool = true,
                         photometric: String = "MONOCHROME2", planar: Int? = nil,
                         syntax: DicomTransferSyntax = .explicitVRLittleEndian) throws -> Fixture {
        precondition((rows * columns * samples * bits).isMultiple(of: 8) || bits == 1)
        var pixels = Data()
        let bytesPerSample = max(1, bits / 8)
        if bits == 1 { pixels = Data(count: (rows * columns * frames + 7) / 8) }
        for frame in 0..<frames {
            if bits == 1 {
                for pixel in 0..<(rows * columns) {
                    let bit = frame * rows * columns + pixel
                    if (pixel / 3 + frame) % 2 == 0 { pixels[bit / 8] |= 1 << (bit % 8) }
                }
                continue
            }
            let planes = planar == 1 ? samples : 1
            for plane in 0..<planes {
                for pixel in 0..<(rows * columns) {
                    for sample in 0..<(planar == 1 ? 1 : samples) {
                        let component = planar == 1 ? plane : sample
                        let raw: Int = pixel < 3 ? -5 : pixel * 97 + component * 1000 - 1000 + frame * 13
                        let value = signed ? raw : abs(raw)
                        for byte in 0..<bytesPerSample { pixels.append(UInt8(truncatingIfNeeded: value >> (8 * byte))) }
                    }
                }
            }
        }
        let bitsStored = bits, highBit = bits - 1
        let dataSet = DicomDataSet(elements: [
            str(.sopClassUID, .UI, ["1.2.840.10008.5.1.4.1.1.7"]), str(.sopInstanceUID, .UI, ["2.25.23350001"]),
            str(.studyInstanceUID, .UI, ["2.25.23350002"]), str(.seriesInstanceUID, .UI, ["2.25.23350003"]),
            str(.patientName, .PN, ["Deflate^Case"]), str(.patientID, .LO, ["D-1"]), str(.modality, .CS, ["OT"]),
            str(.imageType, .CS, ["ORIGINAL", "PRIMARY"]), str(.instanceNumber, .IS, ["1"]), str(.numberOfFrames, .IS, [String(frames)]),
            num(.rows, UInt(rows)), num(.columns, UInt(columns)), num(.samplesPerPixel, UInt(samples)),
            str(.photometricInterpretation, .CS, [photometric]),
            num(.bitsAllocated, UInt(bits)), num(.bitsStored, UInt(bitsStored)), num(.highBit, UInt(highBit)),
            num(.pixelRepresentation, signed ? 1 : 0)
        ] + (planar.map { [num(.planarConfiguration, UInt($0))] } ?? []) + [
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: bits > 8 ? .OW : .OB,
                             value: .bytes(pixels.count.isMultiple(of: 2) ? pixels : pixels + Data([0])))
        ])
        let object = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: syntax))
        return Fixture(object: object, pixels: pixels, rows: rows, columns: columns, frames: frames, samples: samples, bits: bits,
                       photometric: photometric, planar: planar)
    }

    private func encapsulatedObject(fragments: [Data], template: Data) throws -> Data {
        var dataSet = try DCMDecoder(data: template).dataSet
        DicomTranscoder.replaceEncapsulatedPixelData(in: &dataSet, with: try DicomTranscoder.encapsulate(fragments: fragments))
        return try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: Self.deflatedFrames))
    }

    /// Synchronous frame read from an async test body (the async overload would otherwise be chosen).
    private static func frame(_ reader: DicomDecodedFrameReader, _ index: Int) throws -> DicomDecodedFrame {
        try reader.frame(at: index)
    }

    private func decodedFrames(_ data: Data) throws -> [Data] {
        let decoder = try DCMDecoder(data: data)
        let reader = DicomDecodedFrameReader(decoder: decoder)
        return try (0..<max(1, reader.frameCount)).map { index -> Data in
            switch try reader.frame(at: index).pixels {
            case .gray16(let values): return values.withUnsafeBufferPointer { Data(buffer: $0) }
            case .gray8(let values): return Data(values)
            case .rgb8(let values): return Data(values)
            }
        }
    }

    /// The native Pixel Data bytes of every frame (without the trailing pad).
    private func nativePixelBytes(_ data: Data) throws -> Data {
        let decoder = try DCMDecoder(data: data)
        let descriptor = try XCTUnwrap(decoder.pixelDataDescriptor)
        let range = try XCTUnwrap(descriptor.byteRange(forFrames: 0..<descriptor.numberOfFrames))
        return decoder.dicomDataSnapshot().subdata(in: range)
    }
}

private extension Data {
    func byteSwapped16() -> Data {
        var swapped = self
        var index = swapped.startIndex
        while index + 1 < swapped.endIndex { swapped.swapAt(index, index + 1); index += 2 }
        return swapped
    }
}
