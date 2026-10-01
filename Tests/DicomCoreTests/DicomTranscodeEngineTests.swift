import DicomCodecs
import DicomCore
import DicomTestSupport
import Foundation
import XCTest

/// Executable transcode plans, bounded streaming execution, RLE encoding, rewrap and provenance (#2325).
final class DicomTranscodeEngineTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func str(_ tag: DicomTag, _ vr: DicomVR, _ values: [String]) -> DicomDataElement { DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings(values)) }
    private func num(_ tag: DicomTag, _ value: UInt) -> DicomDataElement { DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value])) }

    /// 6×4 frames; 16-bit signed MONOCHROME2 by default, RGB 8-bit or MONOCHROME1 8-bit on request.
    private func source(frames: Int, rgb: Bool = false, monochrome1: Bool = false, syntax: DicomTransferSyntax = .explicitVRLittleEndian) throws -> Data {
        let rows = 4, columns = 6
        var pixels = Data()
        for frame in 0..<frames {
            for pixel in 0..<(rows * columns) {
                if rgb {
                    let red = UInt8((pixel * 3 + frame) & 0xFF)
                    let green = UInt8((pixel * 5) & 0xFF)
                    let blue: UInt8 = pixel < 12 ? 7 : 200
                    pixels.append(contentsOf: [red, green, blue])
                } else if monochrome1 {
                    pixels.append(UInt8((pixel * 11 + frame * 3) & 0xFF))
                } else {
                    let raw: Int = pixel * 97 - 1000 + frame * 13
                    let pattern = UInt16(bitPattern: Int16(truncatingIfNeeded: raw))
                    pixels.append(UInt8(pattern & 0xFF))
                    pixels.append(UInt8(pattern >> 8))
                }
            }
        }
        let dataSet = DicomDataSet(elements: [
            str(.sopClassUID, .UI, ["1.2.840.10008.5.1.4.1.1.7"]), str(.sopInstanceUID, .UI, ["2.25.23409001"]),
            str(.studyInstanceUID, .UI, ["2.25.23409002"]), str(.seriesInstanceUID, .UI, ["2.25.23409003"]),
            str(.patientName, .PN, ["Transcode^Case"]), str(.patientID, .LO, ["T-1"]), str(.modality, .CS, ["OT"]),
            str(.imageType, .CS, ["ORIGINAL", "PRIMARY"]), str(.instanceNumber, .IS, ["1"]), str(.numberOfFrames, .IS, [String(frames)]),
            num(.rows, UInt(rows)), num(.columns, UInt(columns)), num(.samplesPerPixel, rgb ? 3 : 1),
            str(.photometricInterpretation, .CS, [rgb ? "RGB" : (monochrome1 ? "MONOCHROME1" : "MONOCHROME2")]),
            num(.bitsAllocated, rgb || monochrome1 ? 8 : 16), num(.bitsStored, rgb || monochrome1 ? 8 : 16), num(.highBit, rgb || monochrome1 ? 7 : 15),
            num(.pixelRepresentation, rgb || monochrome1 ? 0 : 1)
        ] + (rgb ? [num(.planarConfiguration, 0)] : []) + [
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: rgb || monochrome1 ? .OB : .OW, value: .bytes(pixels))
        ])
        return try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: syntax))
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

    private func pixelRegion(_ data: Data) throws -> Data? {
        let decoder = try DCMDecoder(data: data)
        return DicomPart10PixelDataPreserver.rawEncapsulatedPixelDataRegion(from: decoder)
    }

    // MARK: - RLE

    func test_rle_encoderRoundTripsThroughTheDecoderWithinAnnexGRules() throws {
        var storedBytes: [UInt8] = []
        for index in 0..<(6 * 4 * 2) { storedBytes.append(UInt8((index / 7) & 0xFF)) }
        let stored = Data(storedBytes)
        let frame = try DicomRLECodec.encodeFrame(stored, width: 6, height: 4, samplesPerPixel: 1, bytesPerSample: 2)
        let inspection = try DicomRLECodec.inspect(frame, width: 6, height: 4)
        XCTAssertEqual(inspection.segmentCount, 2)
        XCTAssertFalse(inspection.runsCrossRowBoundaries)
        XCTAssertFalse(inspection.oddSegmentLength)
        let segments = try DicomRLECodec.decodeSegments(frame, width: 6, height: 4)
        let bytes = [UInt8](stored)
        var msb: [UInt8] = [], lsb: [UInt8] = []
        for index in 0..<(bytes.count / 2) { lsb.append(bytes[index * 2]); msb.append(bytes[index * 2 + 1]) }
        XCTAssertEqual(segments[0], msb, "MSB plane first")
        XCTAssertEqual(segments[1], lsb)
        XCTAssertThrowsError(try DicomRLECodec.encodeFrame(stored, width: 6, height: 4, samplesPerPixel: 3, bytesPerSample: 2))
        XCTAssertThrowsError(try DicomRLECodec.encodeFrame(Data([1, 2, 3]), width: 6, height: 4, samplesPerPixel: 1, bytesPerSample: 2))
        // Literal and replicate runs longer than 128 are split, all rows independent.
        var longBytes: [UInt8] = []
        for index in 0..<(300 * 2) { longBytes.append(index < 300 ? 7 : UInt8(index & 0x7F)) }
        let long = Data(longBytes)
        let packed = try DicomRLECodec.encodeFrame(long, width: 300, height: 2, samplesPerPixel: 1, bytesPerSample: 1)
        XCTAssertEqual(try DicomRLECodec.decodeSegments(packed, width: 300, height: 2)[0], [UInt8](long))
    }

    func test_rle_transcodeRoutesPreserveStoredValuesForGrayAndColor() async throws {
        for (label, data) in [("gray16", try source(frames: 3)), ("rgb", try source(frames: 2, rgb: true)), ("mono1", try source(frames: 2, monochrome1: true))] {
            let compressed = try DicomTranscoder().transcode(data, to: .rleLossless)
            let decoder = try DCMDecoder(data: compressed)
            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.rleLossless.rawValue, label)
            XCTAssertEqual(try decodedFrames(compressed), try decodedFrames(data), label)
            XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.23409001", "\(label): reversible keeps identity")
            let asyncCompressed = try await DicomTranscoder().transcode(data, to: .rleLossless, intent: .reversible)
            XCTAssertEqual(try decodedFrames(asyncCompressed), try decodedFrames(data), label)
            let back = try DicomTranscoder().transcode(compressed, to: .explicitVRLittleEndian)
            XCTAssertEqual(try decodedFrames(back), try decodedFrames(data), label)
            let toJLS = try await DicomTranscoder().transcode(compressed, to: .jpegLSLossless, intent: .reversible)
            XCTAssertEqual(try decodedFrames(toJLS), try decodedFrames(data), "\(label): RLE → JPEG-LS through decode and encode")
        }
        XCTAssertThrowsError(try DicomTranscoder().plan(try source(frames: 1), to: .rleLossless, intent: .irreversible(quality: 0.5)))
    }

    // MARK: - Plans

    func test_plan_describesEveryRouteKindAndCost() throws {
        let native = try source(frames: 3)
        let transcoder = DicomTranscoder()
        let rewrite = try transcoder.plan(native, to: .implicitVRLittleEndian)
        XCTAssertEqual(rewrite.kind, .rewriteDataset)
        XCTAssertEqual(rewrite.steps, [.carryDataset])
        XCTAssertFalse(rewrite.isStreamable)
        let deflate = try transcoder.plan(native, to: .deflatedExplicitVRLittleEndian)
        XCTAssertEqual(deflate.steps, [.carryDataset, .deflateDataset])
        let same = try transcoder.plan(native, to: .explicitVRLittleEndian)
        XCTAssertEqual(same.kind, .passThrough)
        let rle = try transcoder.plan(native, to: .rleLossless)
        XCTAssertEqual(rle.kind, .encode)
        XCTAssertEqual(rle.steps, [.carryDataset, .encodeFrames(frames: 3, codec: "rle"), .encapsulate(offsetTables: .basic)])
        XCTAssertTrue(rle.isStreamable)
        XCTAssertEqual(rle.cost.frameCount, 3)
        XCTAssertEqual(rle.cost.decodedFrameBytes, 48)
        XCTAssertEqual(rle.cost.sourceFrameByteCounts, [48, 48, 48])
        XCTAssertEqual(rle.cost.workingSetBytes, 48 * 3)
        XCTAssertEqual(rle.frameFormat?.bitsAllocated, 16)
        XCTAssertEqual(rle.frameFormat?.isEncapsulated, false)
        XCTAssertFalse(rle.assignsNewSOPInstanceUID)
        let compressed = try transcoder.transcode(native, to: .rleLossless)
        let decode = try transcoder.plan(compressed, to: .explicitVRLittleEndian)
        XCTAssertEqual(decode.kind, .decode)
        XCTAssertEqual(decode.steps, [.carryDataset, .decodeFrames(frames: 3, codec: "rle"), .writeNativePixels(frames: 3)])
        XCTAssertEqual(decode.cost.sourceFrameByteCounts.count, 3)
        XCTAssertTrue(decode.cost.sourceFrameByteCounts.allSatisfy { $0 > 64 && $0 < 200 })
        let across = try transcoder.plan(compressed, to: .jpegLSLossless)
        XCTAssertEqual(across.kind, .transcode)
        XCTAssertEqual(across.steps.count, 4)
        let passthrough = try transcoder.plan(compressed, to: .rleLossless)
        XCTAssertEqual(passthrough.kind, .passThrough)
        XCTAssertEqual(passthrough.steps, [.carryDataset, .copyEncapsulatedRegion(frames: 3)])
        let lossy = try transcoder.plan(native, to: .jpegLSNearLossless, intent: .jpegLSNearLossless(near: 2))
        XCTAssertEqual(lossy.kind, .encode)
        XCTAssertTrue(lossy.assignsNewSOPInstanceUID)
        XCTAssertEqual(lossy.steps.suffix(2), [.assignNewSOPInstanceUID, .recordLossHistory(method: "ISO_14495_1")])
        XCTAssertThrowsError(try transcoder.plan(native, to: .jpegLSNearLossless, intent: .reversible), "NEAR without explicit intent")
        XCTAssertThrowsError(try transcoder.plan(native, to: .explicitVRLittleEndian, intent: .irreversible(quality: 0.5)), "loss intent for native output")
        let noPixels = try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: [str(.sopClassUID, .UI, ["1.2.840.10008.5.1.4.1.1.88.11"]), str(.sopInstanceUID, .UI, ["2.25.1"])]))
        XCTAssertEqual(try transcoder.plan(noPixels, to: .implicitVRLittleEndian).cost.frameCount, 0)
    }

    // MARK: - Streaming execution

    func test_execute_rejectsMismatchedSourceBeforePublishing() async throws {
        let transcoder = DicomTranscoder()
        let input = try source(frames: 1)
        let plan = try transcoder.plan(input, to: .rleLossless)
        var geometry = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: input))
        geometry.set(num(.rows, 3))
        geometry.set(num(.columns, 8))
        let mismatches = [
            ("frame count", try source(frames: 2)),
            ("geometry", try DicomDataSetWriter.part10Data(from: geometry)),
            ("transfer syntax", try source(frames: 1, syntax: .implicitVRLittleEndian))
        ]
        let destination = directory.appendingPathComponent("preserved.dcm")
        let original = Data("existing artifact".utf8)
        for (label, data) in mismatches {
            try original.write(to: destination)
            do {
                _ = try await transcoder.execute(plan, source: data, destinationURL: destination)
                XCTFail("Executed a plan with a different \(label)")
            } catch {
                XCTAssertEqual(error as? DicomTranscoder.ExecutionError, .sourcePlanMismatch, label)
            }
            XCTAssertEqual(try Data(contentsOf: destination), original, label)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(".") }, label)
        }
    }

    func test_execute_retainsRawOddCodestreamsAndPadsOnlyFragments() async throws {
        let transcoder = DicomTranscoder()
        let input = try source(frames: 2)
        let plan = try transcoder.plan(input, to: .jpegLSLossless)
        let result = try await transcoder.execute(plan, source: input, retainEncodedFrames: true)
        let encoded = try XCTUnwrap(result.encodedFrames)
        let output = try XCTUnwrap(result.data)
        let decoder = try DCMDecoder(data: output)
        let descriptor = try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor)
        let reader = try DicomEncapsulatedPixelFrameReader(descriptor: descriptor, fileData: output)
        XCTAssertEqual(encoded.codestreams.count, 2)
        XCTAssertEqual(result.frames.map(\.outputBytes), encoded.codestreams.map(\.count))
        for (index, codestream) in encoded.codestreams.enumerated() {
            XCTAssertFalse(codestream.count.isMultiple(of: 2), "Fixture exercises an odd encoded byte count")
            XCTAssertEqual(Array(codestream.suffix(2)), [0xFF, 0xD9], "Retained JPEG-LS ends at EOI")
            var fragment = codestream
            fragment.append(0)
            XCTAssertEqual(try reader.frame(at: index).data, fragment, "Only the DICOM fragment is padded")
        }
        XCTAssertEqual(encoded.encodedByteCount, result.frames.reduce(0) { $0 + $1.outputBytes })
    }

    func test_execute_streamsFrameByFrameAndMatchesTheInMemoryEngine() async throws {
        let transcoder = DicomTranscoder()
        let gray = try source(frames: 3), rgb = try source(frames: 2, rgb: true)
        for (label, data, destination) in [("rle", gray, DicomTransferSyntax.rleLossless), ("rle-rgb", rgb, .rleLossless), ("jls", gray, .jpegLSLossless), ("j2k", gray, .jpeg2000Lossless)] {
            let plan = try transcoder.plan(data, to: destination)
            XCTAssertTrue(plan.isStreamable, label)
            let output = directory.appendingPathComponent("\(label).dcm")
            let box = ProgressBox()
            let result = try await transcoder.execute(plan, source: data, destinationURL: output, retainEncodedFrames: true) { update in
                box.append(update)
            }
            let updates = box.updates
            XCTAssertEqual(result.outputURL, output, label)
            XCTAssertNil(result.data)
            XCTAssertEqual(result.frames.count, plan.cost.frameCount, label)
            XCTAssertEqual(updates.map(\.framesCompleted), Array(1...plan.cost.frameCount), label)
            XCTAssertTrue(updates.map(\.bytesWritten).elementsEqual(updates.map(\.bytesWritten).sorted()), label)
            XCTAssertLessThanOrEqual(result.observed.peakWorkingSetBytes, plan.cost.workingSetBytes + plan.cost.decodedFrameBytes, label)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".") }, label)
            let streamed = try Data(contentsOf: output)
            let inMemory = try await transcoder.execute(plan, source: data)
            XCTAssertEqual(streamed, inMemory.data, "\(label): streaming and memory produce the same bytes")
            XCTAssertEqual(try decodedFrames(streamed), try decodedFrames(data), label)
            XCTAssertEqual(try DCMDecoder(data: streamed).info(for: .transferSyntaxUID), destination.rawValue, label)
            XCTAssertEqual(result.encodedFrames?.codestreams.count, plan.cost.frameCount, label)
            XCTAssertEqual(result.sopInstanceUID, "2.25.23409001", label)
            let legacy = try await transcoder.transcode(data, to: destination, intent: .reversible)
            let legacySet = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: legacy))
            let streamedSet = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: streamed))
            let diff = DicomDataSetDiff.compare(legacySet, streamedSet, options: .init(ignoresFileMeta: false))
            XCTAssertTrue(diff.isEmpty, "\(label): same dataset as the legacy path: \(diff.changes)")
        }
        // Decode streaming: RLE → native, native pixel length written up front.
        let compressed = try transcoder.transcode(gray, to: .rleLossless)
        let decodePlan = try transcoder.plan(compressed, to: .explicitVRLittleEndian)
        let decoded = try await transcoder.execute(decodePlan, source: compressed, destinationURL: directory.appendingPathComponent("native.dcm"))
        let decodedBytes = try Data(contentsOf: decoded.outputURL!)
        XCTAssertEqual(try decodedFrames(decodedBytes), try decodedFrames(gray))
        let legacyDecoded = try transcoder.transcode(compressed, to: .explicitVRLittleEndian)
        XCTAssertEqual(decodedBytes, legacyDecoded)
        // Passthrough streaming copies the encapsulated region byte for byte.
        let passPlan = try transcoder.plan(compressed, to: .rleLossless)
        let passed = try await transcoder.execute(passPlan, source: compressed)
        XCTAssertEqual(try pixelRegion(passed.data!), try pixelRegion(compressed))
        XCTAssertEqual(passed.data, compressed)
        // Compressed → deflate decodes and deflates the dataset.
        let rleToDeflate = try await transcoder.transcode(compressed, to: .deflatedExplicitVRLittleEndian, intent: .reversible)
        XCTAssertEqual(try DCMDecoder(data: rleToDeflate).info(for: .transferSyntaxUID), DicomTransferSyntax.deflatedExplicitVRLittleEndian.rawValue)
        XCTAssertEqual(try decodedFrames(rleToDeflate), try decodedFrames(gray))
        XCTAssertEqual(try transcoder.plan(compressed, to: .deflatedExplicitVRLittleEndian).steps.last, .deflateDataset)
        // Non-streamable routes still publish atomically through the fallback.
        let deflatePlan = try transcoder.plan(gray, to: .deflatedExplicitVRLittleEndian)
        let deflated = try await transcoder.execute(deflatePlan, source: gray, destinationURL: directory.appendingPathComponent("deflate.dcm"))
        let deflatedBytes = try Data(contentsOf: deflated.outputURL!)
        XCTAssertEqual(try DCMDecoder(data: deflatedBytes).info(for: .transferSyntaxUID), DicomTransferSyntax.deflatedExplicitVRLittleEndian.rawValue)
        XCTAssertEqual(try decodedFrames(deflatedBytes), try decodedFrames(gray))
    }

    func test_execute_failuresLeaveNoArtifactAndTruncatedInputIsTyped() async throws {
        let transcoder = DicomTranscoder()
        let gray = try source(frames: 3)
        let plan = try transcoder.plan(gray, to: .rleLossless)
        let missing = directory.appendingPathComponent("missing/out.dcm")
        do { _ = try await transcoder.execute(plan, source: gray, destinationURL: missing); XCTFail("wrote into a missing directory") } catch {
            XCTAssertTrue(error is DicomTranscoder.ExecutionError, "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let output = directory.appendingPathComponent("cancelled.dcm")
        let task = Task { () -> Bool in
            try? await Task.sleep(nanoseconds: 20_000_000)
            do { _ = try await transcoder.execute(plan, source: gray, destinationURL: output); return false } catch is CancellationError { return true } catch { return false }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".") })
        let truncated = Data(gray.prefix(gray.count - 40))
        do {
            let truncatedPlan = try transcoder.plan(truncated, to: .rleLossless)
            _ = try await transcoder.execute(truncatedPlan, source: truncated)
            XCTFail("truncated native pixels encoded")
        } catch {
            XCTAssertTrue(error is DicomTranscoder.TranscodeError || error is DICOMError || error is DicomTranscoder.ExecutionError || error is DicomPart10RewriteError, "\(error)")
        }
        let compressed = try transcoder.transcode(gray, to: .rleLossless)
        let cut = Data(compressed.prefix(compressed.count - 30))
        do { _ = try await transcoder.execute(try transcoder.plan(cut, to: .explicitVRLittleEndian), source: cut); XCTFail("truncated frames decoded") } catch {
            XCTAssertTrue(error is DicomTranscoder.TranscodeError || error is DICOMError || error is DicomTranscoder.ExecutionError, "\(error)")
        }
    }

    // MARK: - Containers, rewrap and reuse

    func test_plan_incompatibleJPEGSyntaxesRequireExplicitReencoding() async throws {
        let transcoder = DicomTranscoder()
        let native = try source(frames: 1, monochrome1: true)
        let baseline = try await transcoder.transcode(native, to: .jpegBaseline, intent: .irreversible(quality: 0.9))
        let lossless = try await transcoder.transcode(native, to: .jpegLSLossless, intent: .reversible)
        for (input, destination, intent) in [
            (baseline, DicomTransferSyntax.jpegExtended, DicomEncodingIntent.irreversible(quality: 0.9)),
            (lossless, .jpegLSNearLossless, .jpegLSNearLossless(near: 2))
        ] {
            XCTAssertThrowsError(try transcoder.plan(input, to: destination, intent: .reversible))
            let plan = try transcoder.plan(input, to: destination, intent: intent)
            XCTAssertEqual(plan.kind, .transcode)
            XCTAssertTrue(plan.assignsNewSOPInstanceUID)
            let result = try await transcoder.execute(plan, source: input)
            let output = try XCTUnwrap(result.data)
            XCTAssertNotEqual(try pixelRegion(output), try pixelRegion(input))
            XCTAssertEqual(try DCMDecoder(data: output).info(for: .transferSyntaxUID), destination.rawValue)
            XCTAssertEqual(try decodedFrames(output).count, 1)
        }
    }

    func test_codestreamContainersAreRefusedAndRewrapReusesEncodedFrames() async throws {
        let jp2 = Data([0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A, 0, 0, 0, 0x14])
        XCTAssertEqual(DicomTranscoder.codestreamViolation(jp2, syntax: .jpeg2000Lossless), "JP2/JPH box container")
        XCTAssertNil(DicomTranscoder.codestreamViolation(Data([0xFF, 0x4F, 0xFF, 0x51, 0, 0]), syntax: .htj2kLossless))
        XCTAssertNotNil(DicomTranscoder.codestreamViolation(Data([0, 0, 0, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]), syntax: .jpegXLLossless))
        XCTAssertNil(DicomTranscoder.codestreamViolation(Data([0xFF, 0xD8, 0xFF, 0xF7]), syntax: .jpegLSLossless))
        XCTAssertTrue(DicomTranscoder.rewrapAllowed(from: .jpeg2000Lossless, to: .jpeg2000))
        XCTAssertFalse(DicomTranscoder.rewrapAllowed(from: .jpeg2000, to: .jpeg2000Lossless))
        XCTAssertTrue(DicomTranscoder.rewrapAllowed(from: .htj2kLossless, to: .htj2k))
        XCTAssertFalse(DicomTranscoder.rewrapAllowed(from: .jpeg2000Lossless, to: .htj2k))
        let transcoder = DicomTranscoder()
        let gray = try source(frames: 2)
        let plan = try transcoder.plan(gray, to: .jpeg2000Lossless)
        let encoded = try await transcoder.execute(plan, source: gray, retainEncodedFrames: true)
        let frames = try XCTUnwrap(encoded.encodedFrames)
        XCTAssertEqual(frames.transferSyntax, .jpeg2000Lossless)
        XCTAssertTrue(frames.codestreams.allSatisfy { $0.prefix(4) == Data([0xFF, 0x4F, 0xFF, 0x51]) })
        // Assemble into the general JPEG 2000 syntax without re-encoding: identical codestreams, new transfer syntax.
        let assembled = try XCTUnwrap(try transcoder.assemble(frames, from: gray, as: .jpeg2000))
        XCTAssertEqual(try DCMDecoder(data: assembled).info(for: .transferSyntaxUID), DicomTransferSyntax.jpeg2000.rawValue)
        let assembledReader = try DicomEncapsulatedPixelFrameReader(descriptor: try XCTUnwrap(DCMDecoder(data: assembled).encapsulatedPixelDataDescriptor), fileData: assembled)
        XCTAssertEqual(try (0..<2).map { try assembledReader.frame(at: $0).data }, frames.codestreams.map { $0.count.isMultiple(of: 2) ? $0 : $0 + Data([0]) })
        XCTAssertEqual(try decodedFrames(assembled), try decodedFrames(gray))
        XCTAssertThrowsError(try transcoder.assemble(frames, from: gray, as: .htj2k))
        XCTAssertThrowsError(try transcoder.assemble(frames, from: try source(frames: 3), as: .jpeg2000))
        // Rewrap plan from the .90 artifact: codestreams copied, not re-encoded.
        let lossless = try XCTUnwrap(encoded.data)
        let rewrap = try transcoder.plan(lossless, to: .jpeg2000)
        XCTAssertEqual(rewrap.kind, .rewrap)
        XCTAssertEqual(rewrap.steps, [.carryDataset, .copyEncapsulatedRegion(frames: 2)])
        let rewrapped = try await transcoder.execute(rewrap, source: lossless)
        XCTAssertEqual(try pixelRegion(rewrapped.data!), try pixelRegion(lossless))
        XCTAssertEqual(try DCMDecoder(data: rewrapped.data!).info(for: .transferSyntaxUID), DicomTransferSyntax.jpeg2000.rawValue)
        XCTAssertNotEqual(try transcoder.plan(assembled, to: .jpeg2000Lossless).kind, .rewrap, "the reverse direction needs inspection, so it decodes and encodes")
        // A malformed JP2 fragment inside Pixel Data is refused before rewrap and passthrough.
        var wrapped = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: lossless))
        wrapped.set(str(.numberOfFrames, .IS, ["1"]))
        wrapped.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(DicomInstanceSplitter.encapsulate(jp2 + Data(repeating: 0, count: 20)))))
        let wrappedFile = try DicomDataSetWriter.part10Data(from: wrapped, options: .init(transferSyntax: .jpeg2000Lossless))
        XCTAssertThrowsError(try transcoder.plan(wrappedFile, to: .jpeg2000)) { XCTAssertTrue($0 is DicomTranscoder.ExecutionError, "\($0)") }
        XCTAssertThrowsError(try transcoder.plan(wrappedFile, to: .jpeg2000Lossless)) { XCTAssertTrue($0 is DicomTranscoder.ExecutionError, "\($0)") }
    }

    // MARK: - Provenance

    func test_lossyRoutesDeriveANewInstanceWithLossHistoryAndSource() async throws {
        let transcoder = DicomTranscoder()
        let gray = try source(frames: 2)
        let plan = try transcoder.plan(gray, to: .jpegLSNearLossless, intent: .jpegLSNearLossless(near: 2))
        let streamedLossy = try await transcoder.execute(plan, source: gray).data!
        let legacyLossy = try await transcoder.transcode(gray, to: .jpegLSNearLossless, intent: .jpegLSNearLossless(near: 2))
        for output in [streamedLossy, legacyLossy] {
            let dataSet = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: output))
            let uid = try XCTUnwrap(dataSet.string(for: .sopInstanceUID))
            XCTAssertNotEqual(uid, "2.25.23409001")
            XCTAssertEqual(try DCMDecoder(data: output).info(for: 0x00020003), uid)
            XCTAssertEqual(dataSet.string(for: .lossyImageCompression), "01")
            XCTAssertEqual(dataSet.strings(for: .lossyImageCompressionMethod), ["ISO_14495_1"])
            let ratio = try XCTUnwrap(dataSet.string(for: .lossyImageCompressionRatio)).trimmingCharacters(in: .whitespaces)
            XCTAssertNotNil(Double(ratio)); XCTAssertGreaterThan(Double(ratio) ?? 0, 0)
            XCTAssertEqual(dataSet.strings(for: .imageType).first, "DERIVED")
            let sourceItem = try XCTUnwrap(dataSet[.sourceImageSequence]?.sequenceItems.first)
            XCTAssertEqual(sourceItem[.referencedSOPInstanceUID]?.stringValue, "2.25.23409001")
            XCTAssertEqual(sourceItem[0x0040A170]?.sequenceItems.first?[0x00080100]?.stringValue, "121320")
            XCTAssertEqual(dataSet[0x00089215]?.sequenceItems.first?[0x00080100]?.stringValue, "113040")
            let before = try decodedFrames(gray), after = try decodedFrames(output)
            for (a, b) in zip(before, after) {
                let x = a.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }, y = b.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
                XCTAssertTrue(zip(x, y).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "NEAR bound")
            }
        }
        // A second lossy step keeps the history of the first.
        let first = try await transcoder.execute(plan, source: gray).data!
        let second = try await transcoder.transcode(first, to: .jpegLSNearLossless, intent: .jpegLSNearLossless(near: 1))
        let twice = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: second))
        XCTAssertEqual(twice.strings(for: .lossyImageCompressionMethod).count, 2)
        XCTAssertEqual(twice[.sourceImageSequence]?.sequenceItems.count, 2)
        XCTAssertEqual(twice.strings(for: .lossyImageCompressionRatio).count, 2)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DicomTranscodeProgress] = []
    var updates: [DicomTranscodeProgress] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ update: DicomTranscodeProgress) { lock.lock(); stored.append(update); lock.unlock() }
}
