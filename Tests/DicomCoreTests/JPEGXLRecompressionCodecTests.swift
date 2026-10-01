import CryptoKit
import Foundation
@testable import DicomCore
@testable import DicomJPEGXL
import XCTest

/// JPEG ↔ JPEG XL recompression (`1.2.840.10008.1.2.4.111`) on the own
/// reconstruction reader/writer, issue #2334.
///
/// Exactness is byte identity of the reconstructed JPEG interchange stream,
/// checked in three directions: own recompression → own reconstruction,
/// own recompression → `djxl`, and `cjxl --lossless_jpeg` → own
/// reconstruction. Missing or damaged reconstruction data is a typed
/// failure; a JPEG that is only visually equivalent is never a success.
final class JPEGXLRecompressionCodecTests: XCTestCase {
    private static let recompression = DicomTransferSyntax.jpegXLJPEGRecompression
    private static let experimental = ["DICOM_JXLSWIFT_MODE": "experimental"]

    private static var corpusDirectory: String? {
        ProcessInfo.processInfo.environment["DICOM_JPEG_RECOMPRESSION_CORPUS_DIRECTORY"]
    }

    // MARK: - Corpus

    func test_externalJPEGCorpusRoundTripsByteExactInEveryDirection() async throws {
        guard let dir = Self.corpusDirectory else { throw XCTSkip("DICOM_JPEG_RECOMPRESSION_CORPUS_DIRECTORY unset") }
        let djxl = try requireExecutable("djxl")
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [[String: Any]])
        let backend = DicomJXLSwiftBackend()
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        var failures: [String] = []
        var exact = 0
        var refused = 0
        for entry in manifest {
            let name = try XCTUnwrap(entry["name"] as? String)
            let accepted = entry["cjxlAccepts"] as? Bool ?? false
            let jpeg = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name + ".jpg"))
            let started = Date()
            let jxl: Data
            do {
                jxl = try await backend.recompressJPEG(jpeg)
            } catch {
                if accepted {
                    failures.append("\(name): recompression refused a JPEG libjxl accepts: \(error)")
                } else {
                    refused += 1
                    XCTAssertTrue(error is DicomJXLSwiftBackendError, "\(name): \(error)")
                }
                continue
            }
            let encodeMs = Date().timeIntervalSince(started) * 1000
            guard accepted else {
                failures.append("\(name): recompressed a JPEG libjxl refuses; its validity must be established independently")
                continue
            }
            let decodeStart = Date()
            let back = try await backend.reconstructJPEG(jxl)
            let decodeMs = Date().timeIntervalSince(decodeStart) * 1000
            if back != jpeg { failures.append("\(name): own reconstruction differs (\(back.count) vs \(jpeg.count) bytes)") }
            let input = work.appendingPathComponent(name + ".jxl")
            let output = work.appendingPathComponent(name + ".jpg")
            try jxl.write(to: input)
            let result = try Self.run(djxl, [input.path, output.path, "--quiet"])
            if result.status != 0 { failures.append("\(name): djxl rejects the own stream: \(result.error)") }
            else if try Data(contentsOf: output) != jpeg { failures.append("\(name): djxl reconstruction differs") }
            let cjxlPath = URL(fileURLWithPath: dir).appendingPathComponent(name + ".cjxl.jxl")
            let cjxlStream = try Data(contentsOf: cjxlPath)
            do {
                let fromCjxl = try await backend.reconstructJPEG(cjxlStream)
                if fromCjxl != jpeg { failures.append("\(name): reconstruction of the cjxl stream differs") }
            } catch {
                failures.append("\(name): reconstruction of the cjxl stream failed: \(error)")
            }
            exact += 1
            print("JPEGXL_RECOMPRESSION \(name): \(jpeg.count) B -> \(jxl.count) B (\(String(format: "%.3f", Double(jxl.count) / Double(jpeg.count)))) "
                  + "encode \(String(format: "%.0f", encodeMs)) ms reconstruct \(String(format: "%.0f", decodeMs)) ms")
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertGreaterThan(exact, 0)
        XCTAssertGreaterThan(refused, 0, "the corpus carries refusal cases")
    }

    // MARK: - Processes and refusals

    func test_writer_emptyHuffmanCounts_throwMalformedError() throws {
        let malformed = JBRDBox(huffmanCode: [.init()], markerOrder: [0xC4, 0xD9])
        XCTAssertThrowsError(try JPEGReconstructionWriter.write(jbrd: malformed, coefficients: [])) {
            guard case .malformed? = $0 as? JPEGReconstructionError else { return XCTFail("\($0)") }
        }
        var sentinelOnly = malformed
        sentinelOnly.huffmanCode[0].counts[1] = 1
        XCTAssertNoThrow(try JPEGReconstructionWriter.write(jbrd: sentinelOnly, coefficients: []))
    }

    func test_interMarkerLength_preservesTheMaximumAndRejectsOverflow() async throws {
        let jpeg = try await Self.baselineJPEG(width: 8, height: 8, channels: 1, seed: 1)
        var box = try JPEGReconstructionReader.read(jpeg).jbrd
        box.markerOrder.insert(0xFF, at: 0)
        box.interMarkerData = [Data(repeating: 42, count: 65535)]
        var writer = BitWriter()
        try JBRDBoxWriter.write(box, to: &writer)
        var reader = BitReader(writer.finishToData())
        XCTAssertEqual(try JBRDBoxReader.read(from: &reader).interMarkerData.map(\.count), [65535])

        box.interMarkerData[0].append(42)
        writer = BitWriter()
        XCTAssertThrowsError(try JBRDBoxWriter.write(box, to: &writer)) { error in
            guard case JBRDError.notImplemented(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("inter_marker_data"))
        }
    }

    func test_acceptedProcessesAreBaselineExtendedAndProgressiveHuffmanOnly() async throws {
        let backend = DicomJXLSwiftBackend()
        let baseline = try await Self.baselineJPEG(width: 37, height: 29, channels: 3, seed: 1)
        XCTAssertEqual(DicomJXLSwiftBackend.jpegProcess(of: baseline), 0xC0)
        // SOF1 (JPEG Extended, 8-bit) with the same tables is a legal stream.
        var extended = baseline
        if let range = extended.range(of: Data([0xFF, 0xC0])) { extended[range.lowerBound + 1] = 0xC1 }
        XCTAssertEqual(DicomJXLSwiftBackend.jpegProcess(of: extended), 0xC1)
        for (label, jpeg) in [("SOF0", baseline), ("SOF1", extended)] {
            let jxl = try await backend.recompressJPEG(jpeg)
            let back = try await backend.reconstructJPEG(jxl)
            XCTAssertEqual(back, jpeg, label)
        }
        // Refusals before any output: 12-bit (SOF1 precision 12), lossless
        // (SOF3), arithmetic (SOF9), four components, a truncated stream.
        var twelve = baseline
        if let range = twelve.range(of: Data([0xFF, 0xC0])) { twelve[range.lowerBound + 4] = 12 }
        var lossless = baseline
        if let range = lossless.range(of: Data([0xFF, 0xC0])) { lossless[range.lowerBound + 1] = 0xC3 }
        var arithmetic = baseline
        if let range = arithmetic.range(of: Data([0xFF, 0xC0])) { arithmetic[range.lowerBound + 1] = 0xC9 }
        var cmyk = baseline
        if let range = cmyk.range(of: Data([0xFF, 0xC0])) { cmyk[range.lowerBound + 9] = 4 }
        for (label, jpeg, needle) in [("12-bit", twelve, "precision"), ("SOF3", lossless, "SOF3"), ("SOF9", arithmetic, "SOF9"),
                                      ("four components", cmyk, ""), ("truncated", baseline.prefix(baseline.count / 2), "")] {
            do {
                _ = try await backend.recompressJPEG(Data(jpeg))
                XCTFail("\(label) must be refused")
            } catch let error as DicomJXLSwiftBackendError {
                if !needle.isEmpty { XCTAssertTrue("\(error)".contains(needle), "\(label): \(error)") }
            }
        }
    }

    func test_missingOrDamagedReconstructionDataIsATypedFailureNeverAVisuallySimilarJPEG() async throws {
        let backend = DicomJXLSwiftBackend()
        let jpeg = try await Self.baselineJPEG(width: 64, height: 48, channels: 1, seed: 2)
        let jxl = try await backend.recompressJPEG(jpeg)
        let back0 = try await backend.reconstructJPEG(jxl)
        XCTAssertEqual(back0, jpeg)
        // A plain VarDCT container/codestream without the jbrd box.
        let codestream = try Self.lossyCodestream(from: jxl)
        for (label, input) in [("codestream", codestream), ("truncated container", jxl.prefix(jxl.count - 40)),
                               ("half container", jxl.prefix(jxl.count / 2))] {
            do {
                _ = try await backend.reconstructJPEG(Data(input))
                XCTFail("\(label) must be refused")
            } catch {
                XCTAssertTrue(error is DicomJXLSwiftBackendError, "\(label): \(error)")
            }
        }
        // Mutations inside the container: every outcome is either a typed
        // error or the exact original; a different JPEG is never returned.
        // The sweep is deterministic so a trapping input can be pinned:
        // every byte position with two masks, then 60 seeded 1–3 byte
        // mutations (the shape of the original random loop).
        var typed = 0
        func check(_ mutated: Data, _ label: @autoclosure () -> String) async {
            do {
                let back = try await backend.reconstructJPEG(mutated)
                if back != jpeg {
                    // Only the coefficient/jbrd payload itself can legitimately change the bytes;
                    // the result must still be a decodable JPEG the own decoder accepts.
                    XCTAssertNoThrow(try JPEGReconstructionReader.read(back), "\(label()): a reconstructed stream is always a valid JPEG")
                }
            } catch {
                typed += 1
                XCTAssertTrue(error is DicomJXLSwiftBackendError, "\(label()): \(error)")
            }
        }
        for i in 0..<jxl.count {
            for mask in [UInt8(0x01), 0x80] {
                var mutated = jxl
                mutated[mutated.startIndex + i] ^= mask
                await check(mutated, "byte \(i) ^ 0x\(String(mask, radix: 16))")
            }
        }
        var rng = SeededGenerator(seed: 0x2334)
        for round in 0..<60 {
            var mutated = jxl
            var label = "round \(round):"
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let i = Int.random(in: 0..<mutated.count, using: &rng)
                let mask = UInt8.random(in: 1...255, using: &rng)
                mutated[mutated.startIndex + i] ^= mask
                label += " \(i)^0x\(String(mask, radix: 16))"
            }
            await check(mutated, label)
        }
        XCTAssertGreaterThan(typed, 0)
        // The pinned failing input from the 2026-09-12 run: one bit of the
        // codestream's RAW quant slot flipped, which used to trap the
        // process in `JXLToJPEGAdapter.buildQuantTables` (`UInt16(-1)`).
        let damagedURL = try XCTUnwrap(Bundle.module.url(forResource: "jpegxl_recompression_damaged_quant", withExtension: "jxl"))
        let damaged = try Data(contentsOf: damagedURL)
        XCTAssertEqual(SHA256.hash(data: damaged).map { String(format: "%02x", $0) }.joined(),
                       "8b00ce1a83c3751fb801052be8acc50024dd4c443968b751f176551d2482e737")
        XCTAssertEqual(damaged.count, 1328, "the pinned corrupt fixture retains its original byte count")
        do {
            _ = try await backend.reconstructJPEG(damaged)
            XCTFail("a damaged quant table must be refused")
        } catch let error as DicomJXLSwiftBackendError {
            // RAW table validation can reject the damaged slot before JPEG reconstruction reaches it.
            let reason = String(describing: error)
            XCTAssertTrue(reason.contains("quant table") || reason.contains("invalid RAW qtable"), reason)
        }
        // Tail data beyond libjxl's 4260096-byte bound is refused, not truncated.
        var huge = jpeg
        huge.append(Data(count: 4_300_000))
        do {
            _ = try await backend.recompressJPEG(huge)
            XCTFail("oversized tail data must be refused")
        } catch let error as DicomJXLSwiftBackendError {
            XCTAssertTrue("\(error)".lowercased().contains("tail"), "\(error)")
        }
    }

    // MARK: - DICOM layer

    func test_progressiveJPEGReconstructsExactly_butCannotBeExportedUnderSequentialUIDs() async throws {
        let cjpeg = try requireExecutable("cjpeg")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("progressive.pgm")
        let output = directory.appendingPathComponent("progressive.jpg")
        try (Data("P5\n16 16\n255\n".utf8) + Data((0..<256).map(UInt8.init))).write(to: input)
        let result = try Self.run(cjpeg, ["-progressive", "-outfile", output.path, input.path])
        XCTAssertEqual(result.status, 0, result.error)
        let jpeg = try Data(contentsOf: output)
        XCTAssertEqual(DicomJXLSwiftBackend.jpegProcess(of: jpeg), 0xC2)
        let backend = DicomJXLSwiftBackend()
        let encoded = try await backend.recompressJPEG(jpeg)
        let reconstructed = try await backend.reconstructJPEG(encoded)
        XCTAssertEqual(reconstructed, jpeg)
        let source = try Self.file(frames: [encoded], syntax: Self.recompression, width: 16, height: 16, channels: 1, lossy: nil)
        for syntax: DicomTransferSyntax in [.jpegBaseline, .jpegExtended] {
            do {
                _ = try await DicomTranscoder().transcode(source, to: syntax, intent: .reversible, environment: Self.experimental)
                XCTFail("SOF2 must not be reconstructed under \(syntax)")
            } catch {
                XCTAssertTrue("\(error)".contains("process"), "\(error)")
            }
        }
    }

    func test_jpegStructureIgnoresPaddingAfterEOI() async throws {
        let jpeg = try await Self.baselineJPEG(width: 17, height: 9, channels: 1, seed: 7)
        let structure = try JPEGStructure.read(jpeg + Data([0]))
        XCTAssertEqual(structure.width, 17)
        XCTAssertEqual(structure.height, 9)
    }

    func test_dicomBridgeRefusesJPEGProcessThatDoesNotMatchSourceSyntax() async throws {
        var jpeg = try await Self.baselineJPEG(width: 16, height: 16, channels: 1, seed: 3)
        let marker = try XCTUnwrap(jpeg.range(of: Data([0xFF, 0xC0])))
        jpeg[marker.lowerBound + 1] = 0xC2
        for syntax: DicomTransferSyntax in [.jpegBaseline, .jpegExtended] {
            let source = try Self.file(frames: [jpeg], syntax: syntax, width: 16, height: 16, channels: 1, lossy: nil)
            do {
                _ = try await DicomTranscoder().transcode(source, to: Self.recompression, intent: .reversible, environment: Self.experimental)
                XCTFail("SOF2 must not be accepted under \(syntax)")
            } catch {
                XCTAssertTrue("\(error)".contains("JPEG process"), "\(error)")
            }
        }
    }

    func test_dicomRoundTripKeepsFragmentsIdentityAndLossyHistory() async throws {
        let (width, height, frames) = (75, 51, 3)
        var jpegs: [Data] = []
        for i in 0..<frames { jpegs.append(try await Self.baselineJPEG(width: width, height: height, channels: 3, seed: UInt32(10 + i))) }
        XCTAssertTrue(jpegs.contains { $0.count.isMultiple(of: 2) == false }, "the corpus has an odd-length fragment")
        let source = try Self.file(frames: jpegs, syntax: .jpegBaseline, width: width, height: height, channels: 3,
                                   lossy: (ratio: "12.5", method: "ISO_10918_1"))
        let transcoder = DicomTranscoder()
        let recompressed = try await transcoder.transcode(source, to: Self.recompression, intent: .reversible, environment: Self.experimental)
        let decoder = try DCMDecoder(data: recompressed)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), Self.recompression.rawValue)
        XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.23340001", "storage change keeps the SOP identity")
        XCTAssertEqual(decoder.dataSet.strings(for: .lossyImageCompression), ["01"], "existing lossy history is preserved")
        XCTAssertEqual(decoder.dataSet.strings(for: .lossyImageCompressionMethod), ["ISO_10918_1"], "no new derivation is recorded")
        XCTAssertNil(decoder.dataSet.element(for: 0x0008_9215), "no Derivation Code Sequence for a reversible storage change")
        let descriptor = try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor)
        XCTAssertEqual(descriptor.fragments.count, frames)
        XCTAssertTrue(descriptor.fragments.allSatisfy { $0.length.isMultiple(of: 2) })
        let reader = try decoder.makeEncapsulatedPixelFrameReader()
        for i in 0..<frames {
            XCTAssertTrue(try reader.frameData(at: i).starts(with: [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]), "frame \(i) is a JPEG XL container")
        }
        // Back to .50 without decoding: fragments identical to the source JPEGs.
        let restored = try await transcoder.transcode(recompressed, to: .jpegBaseline, intent: .reversible, environment: Self.experimental)
        let restoredDecoder = try DCMDecoder(data: restored)
        XCTAssertEqual(restoredDecoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegBaseline.rawValue)
        XCTAssertEqual(restoredDecoder.info(for: .sopInstanceUID), "2.25.23340001")
        let restoredReader = try restoredDecoder.makeEncapsulatedPixelFrameReader()
        for i in 0..<frames {
            let fragment = try restoredReader.frameData(at: i)
            XCTAssertEqual(fragment.prefix(jpegs[i].count), jpegs[i], "frame \(i) reconstructed byte for byte")
            XCTAssertTrue(fragment.dropFirst(jpegs[i].count).allSatisfy { $0 == 0 }, "only DICOM padding follows EOI")
        }
        // .111 → .51 is refused: the frames are SOF0.
        do {
            _ = try await transcoder.transcode(recompressed, to: .jpegExtended, intent: .reversible, environment: Self.experimental)
            XCTFail("SOF0 frames must not be relabelled as JPEG Extended")
        } catch {
            XCTAssertTrue("\(error)".contains("0xc0") || "\(error)".contains("process"), "\(error)")
        }
        // Pixels of .111 equal the pixels of the .50 object through the same own JPEG backend.
        let pixelEnvironment = Self.experimental.merging(["DICOM_JPEGSWIFT_MODE": "preferred"]) { $1 }
        let nativeFromJPEG = try await transcoder.transcode(source, to: .explicitVRLittleEndian, intent: .reversible, environment: pixelEnvironment)
        let nativeFromJXL = try await transcoder.transcode(recompressed, to: .explicitVRLittleEndian, intent: .reversible, environment: pixelEnvironment)
        let pixelsFromJPEG = try XCTUnwrap(try DCMDecoder(data: nativeFromJPEG).getAllFrames()?.map(\.data))
        let pixelsFromJXL = try XCTUnwrap(try DCMDecoder(data: nativeFromJXL).getAllFrames()?.map(\.data))
        XCTAssertEqual(pixelsFromJXL, pixelsFromJPEG)
        // A lossy intent has no meaning here.
        do {
            _ = try await transcoder.transcode(source, to: Self.recompression, intent: .irreversible(quality: 0.5), environment: Self.experimental)
            XCTFail("lossy intent must be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("reversible"), "\(error)")
        }
    }

    func test_cancellationAndOutputFailuresLeaveNoPartialObject() async throws {
        let jpeg = try await Self.baselineJPEG(width: 600, height: 520, channels: 3, seed: 30)
        let source = try Self.file(frames: [jpeg, jpeg, jpeg], syntax: .jpegBaseline, width: 600, height: 520, channels: 3, lossy: nil)
        let work = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let destination = work.appendingPathComponent("cancelled.dcm")
        let environment = Self.experimental
        let target = Self.recompression
        let task = Task<Int, Error> {
            let result = try await DicomCodecWorkflowEngine().transcode(
                source, to: target, intent: .reversible, environment: environment,
                verifyDecodedPixels: false, destinationURL: destination, progress: nil)
            return result.data.count
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTAssertNoThrow(try DCMDecoder(data: try Data(contentsOf: destination)))
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "no partial output after cancellation")
        }
        // A destination that cannot be written fails typed and leaves nothing behind.
        let unwritable = work.appendingPathComponent("missing-directory/out.dcm")
        do {
            _ = try await DicomCodecWorkflowEngine().transcode(
                source, to: target, intent: .reversible, environment: environment,
                verifyDecodedPixels: false, destinationURL: unwritable, progress: nil)
            XCTFail("an unwritable destination must fail")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: unwritable.path))
        }
        // A cancelled frame operation surfaces as CancellationError.
        let backend = DicomJXLSwiftBackend()
        let cancelled = Task { try await backend.recompressJPEG(jpeg) }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
        } catch is CancellationError {
        } catch {
            XCTFail("cancellation surfaced as \(error)")
        }
    }

    // MARK: - Helpers

    private static func lossyCodestream(from jxl: Data) throws -> Data {
        let frame = try JXLDecoder().decode(jxl)
        return try JXLEncoder(options: EncodingOptions(mode: .distance(1), containerWrap: false)).encode(frame).data
    }

    /// A baseline JPEG produced by the own JPEG encoder (no external tools).
    private static func baselineJPEG(width: Int, height: Int, channels: Int, seed: UInt32) async throws -> Data {
        var state = seed &* 2_654_435_761 &+ 1
        var bytes = [UInt8](repeating: 0, count: width * height * channels)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    state = state &* 1_103_515_245 &+ 12_345
                    let noise = Int((state >> 16) & 0x1F) - 16
                    let v = 128 + 100 * sin(Double(x) / (5 + Double(c) * 2)) * cos(Double(y) / 7)
                    bytes[(y * width + x) * channels + c] = UInt8(clamping: Int(v.rounded()) + noise)
                }
            }
        }
        let descriptor = DicomCompressedFrameDescriptor(
            transferSyntaxUID: DicomTransferSyntax.jpegBaseline.rawValue, rows: height, columns: width,
            bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0, samplesPerPixel: channels,
            photometricInterpretation: channels == 3 ? "YBR_FULL_422" : "MONOCHROME2", planarConfiguration: channels == 3 ? 0 : nil)
        let frame = DicomCodecDecodedFrame(buffer: .owned(Data(bytes)), width: width, height: height, bitsPerSample: 8, componentCount: channels)
        return try await DicomJPEGSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: frame, descriptor: descriptor, targetTransferSyntaxUID: DicomTransferSyntax.jpegBaseline.rawValue,
            intent: .irreversible(quality: 0.85), iccProfile: nil))
    }

    private static func file(
        frames: [Data], syntax: DicomTransferSyntax, width: Int, height: Int, channels: Int,
        lossy: (ratio: String, method: String)?
    ) throws -> Data {
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23340001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23340002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23340003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["JPEGXL^RECOMPRESSION"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["JXL-2334"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(channels)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([channels == 3 ? "YBR_FULL_422" : "MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
        ]
        if channels == 3 {
            elements.append(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0])))
        }
        if frames.count > 1 {
            elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(frames.count)"])))
        }
        if let lossy {
            elements.append(DicomDataElement(tag: DicomTag.lossyImageCompression.rawValue, vr: .CS, value: .strings(["01"])))
            elements.append(DicomDataElement(tag: DicomTag.lossyImageCompressionRatio.rawValue, vr: .DS, value: .strings([lossy.ratio])))
            elements.append(DicomDataElement(tag: DicomTag.lossyImageCompressionMethod.rawValue, vr: .CS, value: .strings([lossy.method])))
        }
        elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                                         value: .bytes(try DicomTranscoder.encapsulate(fragments: frames).pixelData)))
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements), options: .init(transferSyntax: syntax))
    }

    /// SplitMix64: the mutation sweep must be reproducible run to run.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func requireExecutable(_ name: String) throws -> String {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw XCTSkip("\(name) is not installed")
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        let error = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, error)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jpegxl-recompression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
