import Foundation
@testable import DicomCore
@testable import DicomJPEGXL
import XCTest

/// JPEG XL VarDCT (lossy) coding on the vendored `DicomJPEGXL` target, issue #2333.
///
/// The decoder is checked against libjxl 0.12 sample by sample (`djxl` is the
/// oracle; decoder divergence is separated from legitimate lossy error by
/// comparing two decoders of the *same* codestream); the encoder's output must be
/// accepted by `djxl` and its fidelity is measured against `cjxl` at the same
/// distance. Lossy coding is only reachable through an explicit distance.
final class JPEGXLVarDCTCodecTests: XCTestCase {
    func test_decodeRejectsOversizedDescriptorBeforeReadingTheCodestream() async throws {
        let backend = DicomJXLSwiftBackend()
        for (width, height, channels, oversized) in [(16_384, 16_384, 3, true), (16_384, 16_384, 1, false), (8, 8, 3, false)] {
            let descriptor = Self.descriptor(Self.general, width: width, height: height, precision: 8, signed: false, channels: channels)
            do {
                _ = try await backend.decode(.init(frameData: Data(), descriptor: descriptor, frameIndex: 0))
                XCTFail("An empty stream cannot decode")
            } catch DicomJXLSwiftBackendError.unsupportedShape(_, let reason) {
                XCTAssertEqual(reason.contains("decoded frame exceeds the backend byte limit"), oversized, reason)
            }
        }
    }

    private static let general = DicomTransferSyntax.jpegXL
    private static let lossless = DicomTransferSyntax.jpegXLLossless
    private static let experimental = ["DICOM_JXLSWIFT_MODE": "experimental"]

    /// Tolerances per profile for two decoders of one codestream (absolute
    /// sample error against djxl). 8-bit output differs by at most one code
    /// (dither/rounding order), deeper output by at most two codes.
    private static func tolerance(bits: Int) -> (max: Int, mean: Double) {
        bits <= 8 ? (1, 0.01) : (2, 0.05)
    }

    // MARK: - Corpus (libjxl streams decoded by the own core)

    private static var corpusDirectory: String? {
        ProcessInfo.processInfo.environment["DICOM_JPEGXL_LOSSY_CORPUS_DIRECTORY"]
    }

    func test_libjxlLossyCorpusDecodesWithinTheProfileTolerances() throws {
        guard let dir = Self.corpusDirectory else { throw XCTSkip("DICOM_JPEGXL_LOSSY_CORPUS_DIRECTORY unset") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jxl") }.sorted()
        XCTAssertGreaterThan(files.count, 0, "empty corpus")
        var failures: [String] = []
        for file in files {
            let name = String(file.dropLast(4))
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(file))
            let ref = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name + ".ref.pnm"))
            do {
                let started = Date()
                let frame = try JXLDecoder().decode(data)
                let ms = Date().timeIntervalSince(started) * 1000
                let (rw, rh, rmax, rbody) = try JPEGXLLibjxlCorpusTests.parsePNM(ref)
                let refBytes = rmax > 255 ? 2 : 1
                let refChannels = rbody.count / (rw * rh * refBytes)
                guard rw == frame.width, rh == frame.height, refChannels == frame.channels else {
                    failures.append("\(name): geometry \(frame.width)x\(frame.height)x\(frame.channels) vs \(rw)x\(rh)x\(refChannels)")
                    continue
                }
                let bits = rmax > 255 ? (rmax > 4095 ? 16 : 12) : 8
                let ownBytes = frame.pixelType.bytesPerSample
                var maxDiff = 0
                var sum = 0
                let count = rw * rh * refChannels
                for i in 0..<count {
                    let refValue = refBytes == 2 ? ((Int(rbody[2 * i]) << 8) | Int(rbody[2 * i + 1])) : Int(rbody[i])
                    let ownValue = ownBytes == 2 ? (Int(frame.data[2 * i]) | (Int(frame.data[2 * i + 1]) << 8)) : Int(frame.data[i])
                    let d = abs(refValue - ownValue)
                    maxDiff = max(maxDiff, d)
                    sum += d
                }
                let mean = Double(sum) / Double(max(1, count))
                let limit = Self.tolerance(bits: bits)
                if maxDiff > limit.max || mean > limit.mean {
                    failures.append("\(name): max \(maxDiff) mean \(String(format: "%.4f", mean)) exceeds \(limit)")
                }
                print("JPEGXL_LOSSY_CORPUS \(name) max \(maxDiff) mean \(String(format: "%.4f", mean)) \(String(format: "%.0f", ms)) ms")
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func test_truncatedAndCorruptedLossyStreamsFailTypedWithoutPartialOutput() throws {
        guard let dir = Self.corpusDirectory else { throw XCTSkip("DICOM_JPEGXL_LOSSY_CORPUS_DIRECTORY unset") }
        let names = ["rgb8_300_d1_e7", "rgb8_300_d1_prog", "rgb8_300_d1_prog_dc2", "rgb8_300_d3_resample2", "rgb8_300_d1_photon",
                     "gray16_256_d1", "rgb8_700_d1_prog_e9", "rgb8_300_d1_modular_lossy"]
        var rng = SystemRandomNumberGenerator()
        var attempts = 0
        for name in names {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name + ".jxl")) else { continue }
            for cut in stride(from: 1, to: data.count, by: max(1, data.count / 24)) {
                attempts += 1
                XCTAssertThrowsError(try JXLDecoder().decode(data.prefix(cut)), "\(name) cut at \(cut)") { error in
                    XCTAssertTrue(error is DecoderError, "\(error)")
                }
            }
            for _ in 0..<30 {
                var corrupted = data
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    let i = Int.random(in: 0..<corrupted.count, using: &rng)
                    corrupted[corrupted.startIndex + i] ^= UInt8.random(in: 1...255, using: &rng)
                }
                attempts += 1
                // A typed error or a decode; never a trap.
                _ = try? JXLDecoder().decode(corrupted)
            }
        }
        XCTAssertGreaterThan(attempts, 0)
    }

    // MARK: - Adapter: libjxl lossy features through the DICOM frame contract

    func test_progressiveUpsampledAndNoisyCjxlStreamsDecodeThroughTheBackendWithinTolerance() async throws {
        let cjxl = try requireExecutable("cjxl")
        let djxl = try requireExecutable("djxl")
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(name: String, width: Int, height: Int, precision: Int, channels: Int, flags: [String])] = [
            ("prog-rgb8", 301, 277, 8, 3, ["-d", "1", "-p"]),
            ("prog-dc2-rgb8", 300, 300, 8, 3, ["-d", "1", "--progressive_dc=2"]),
            ("resample2-gray12", 301, 299, 12, 1, ["-d", "1", "--resampling=2"]),
            ("noise-gray8", 300, 300, 8, 1, ["-d", "1", "--photon_noise_iso=3200"]),
            ("noise-resample-rgb8", 263, 517, 8, 3, ["-d", "2", "--photon_noise_iso=6400", "--resampling=2"]),
            ("modular-xyb-gray16", 200, 150, 16, 1, ["-d", "1", "-m", "1"]),
            ("epf3-e9-gray16", 257, 131, 16, 1, ["-d", "0.5", "--epf=3", "-e", "9"]),
        ]
        let backend = DicomJXLSwiftBackend()
        for c in cases {
            let planes = Self.samples(width: c.width, height: c.height, precision: c.precision, signed: false, seed: 40, channels: c.channels)
            let source = dir.appendingPathComponent(c.name + (c.channels == 3 ? ".ppm" : ".pgm"))
            try Self.pnm(planes, width: c.width, height: c.height, precision: c.precision).write(to: source)
            let jxl = dir.appendingPathComponent(c.name + ".jxl")
            var result = try Self.run(cjxl, [source.path, jxl.path, "--container=0", "--quiet"] + c.flags)
            XCTAssertEqual(result.status, 0, "cjxl \(c.name): \(result.error)")
            let ref = dir.appendingPathComponent(c.name + ".ref.pnm")
            result = try Self.run(djxl, [jxl.path, ref.path, "--quiet", "--bits_per_sample=\(c.precision)"])
            XCTAssertEqual(result.status, 0, "djxl \(c.name): \(result.error)")
            let (rw, rh, _, reference) = try Self.parsePNM(try Data(contentsOf: ref))
            XCTAssertEqual((rw, rh) == (c.width, c.height), true)
            let descriptor = Self.descriptor(Self.general, width: c.width, height: c.height, precision: c.precision, signed: false, channels: c.channels)
            let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: try Data(contentsOf: jxl), descriptor: descriptor, frameIndex: 0))
            let own = Self.planes(from: decoded.buffer.data, bitsAllocated: c.precision > 8 ? 16 : 8, channels: c.channels)
            var maxDiff = 0
            var sum = 0
            for ch in 0..<c.channels {
                for i in 0..<(c.width * c.height) {
                    let d = abs(Int(own[ch][i]) - Int(reference[ch][i]))
                    maxDiff = max(maxDiff, d)
                    sum += d
                }
            }
            let mean = Double(sum) / Double(c.width * c.height * c.channels)
            let limit = Self.tolerance(bits: c.precision)
            XCTAssertLessThanOrEqual(maxDiff, limit.max, "\(c.name): max sample error against djxl")
            XCTAssertLessThanOrEqual(mean, limit.mean, "\(c.name): mean sample error against djxl")
        }
    }

    func test_unsupportedLossyFeaturesAreRefusedTypedNotSilently() async throws {
        // Patches (0x02) and splines (0x10) are announced in the frame flags and
        // refused by name (`FrameFlag`); the gate is exercised by the corpus test
        // through cjxl's `--patches`/`--dots` streams, which decode when cjxl
        // did not emit a dictionary and are refused typed when it did.
        XCTAssertEqual(FrameFlag.patches.rawValue, 0x02)
        XCTAssertEqual(FrameFlag.splines.rawValue, 0x10)
        XCTAssertEqual(FrameFlag.noise.rawValue, 0x01)
        // A VarDCT stream whose TOC points outside the codestream is a typed error.
        let cjxl = try requireExecutable("cjxl")
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let planes = Self.samples(width: 64, height: 48, precision: 8, signed: false, seed: 3, channels: 3)
        let source = dir.appendingPathComponent("s.ppm")
        try Self.pnm(planes, width: 64, height: 48, precision: 8).write(to: source)
        let jxl = dir.appendingPathComponent("s.jxl")
        XCTAssertEqual(try Self.run(cjxl, [source.path, jxl.path, "--container=0", "--quiet", "-d", "1"]).status, 0)
        let data = try Data(contentsOf: jxl)
        XCTAssertThrowsError(try Self.decodeSync(data.prefix(data.count / 2))) { XCTAssertTrue($0 is DecoderError, "\($0)") }
        // A descriptor bomb (declared 8192² for a 64×48 stream) is refused on the header.
        let descriptor = Self.descriptor(Self.general, width: 8192, height: 8192, precision: 8, signed: false, channels: 3)
        do {
            _ = try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(frameData: data, descriptor: descriptor, frameIndex: 0))
            XCTFail("dimension disagreement must be refused")
        } catch let error as DicomJXLSwiftBackendError {
            XCTAssertTrue("\(error)".contains("8192") || "\(error)".contains("match"), "\(error)")
        }
    }

    // MARK: - Encoder: explicit lossy configuration

    func test_lossyCodingRequiresAnExplicitDistanceAndRoutesToVarDCT() throws {
        let gray = Self.descriptor(Self.general, width: 64, height: 32, precision: 8, signed: false)
        XCTAssertEqual(try DicomJXLSwiftBackend.validateEncoding(descriptor: gray, targetTransferSyntaxUID: Self.general.rawValue, intent: .reversible),
                       .modularLossless(effort: 7))
        XCTAssertEqual(try DicomJXLSwiftBackend.validateEncoding(descriptor: gray, targetTransferSyntaxUID: Self.general.rawValue,
                                                                  intent: .jpegXL(options: .init(distance: 0, effort: 3))),
                       .modularLossless(effort: 3))
        let lossy = try DicomJXLSwiftBackend.validateEncoding(descriptor: gray, targetTransferSyntaxUID: Self.general.rawValue,
                                                             intent: .jpegXL(options: .init(distance: 1.5, gaborish: false)))
        guard case .varDCT(let options) = lossy else { return XCTFail("distance 1.5 selects VarDCT") }
        XCTAssertEqual(options.distance, 1.5)
        XCTAssertFalse(options.gaborish)
        XCTAssertFalse(options.containerWrap, "DICOM carries raw codestreams")
        XCTAssertTrue(DicomEncodingIntent.jpegXL(options: .init(distance: 1)).isLossy)
        XCTAssertFalse(DicomEncodingIntent.jpegXL(options: .init(distance: 0)).isLossy)
        // Refusals: distance on the lossless-only syntax, out-of-range distance/effort, oversize frames.
        let losslessDescriptor = Self.descriptor(Self.lossless, width: 64, height: 32, precision: 8, signed: false)
        for (descriptor, uid, intent, needle) in [
            (losslessDescriptor, Self.lossless.rawValue, DicomEncodingIntent.jpegXL(options: .init(distance: 1)), "distance 0"),
            (gray, Self.general.rawValue, .jpegXL(options: .init(distance: 26)), "0...25"),
            (gray, Self.general.rawValue, .jpegXL(options: .init(distance: -1)), "0...25"),
            (gray, Self.general.rawValue, .jpegXL(options: .init(distance: .nan)), "finite"),
            (gray, Self.general.rawValue, .jpegXL(options: .init(distance: 1, effort: 0)), "1...9"),
            (gray, Self.general.rawValue, .jpegXL(options: .init(distance: 1, effort: 10)), "1...9"),
            (Self.descriptor(Self.general, width: 8193, height: 8, precision: 8, signed: false), Self.general.rawValue,
             .jpegXL(options: .init(distance: 1)), "8192"),
            (Self.descriptor(Self.general, width: 64, height: 32, precision: 10, signed: false), Self.general.rawValue,
             .jpegXL(options: .init(distance: 1)), "8/12/16"),
        ] {
            XCTAssertThrowsError(try DicomJXLSwiftBackend.validateEncoding(descriptor: descriptor, targetTransferSyntaxUID: uid, intent: intent), needle) {
                XCTAssertTrue("\($0)".contains(needle), "\($0)")
            }
        }
        // The capability decision carries the intent description.
        let decision = DicomCodecCapabilities.resolve(
            DicomCodecCapabilityRequest(operation: .encode, descriptor: gray, intent: .jpegXL(options: .init(distance: 2))),
            environment: Self.experimental)
        XCTAssertTrue(decision.canExecute, "\(decision.reason ?? "")")
        XCTAssertTrue(decision.encodingIntent.contains("distance: 2.0"), decision.encodingIntent)
    }

    func test_inverseGaborishMirrorsDegenerateFrameEdgesWithoutOutOfBounds() {
        var constant: [Float] = [37]
        Gaborish.applyInverse5x5(to: &constant, width: 1, height: 1)
        XCTAssertEqual(constant[0], 37, accuracy: 0.0001)
        for (width, height) in [(2, 1), (1, 2)] {
            var edge: [Float] = [0, 100]
            Gaborish.applyInverse5x5(to: &edge, width: width, height: height)
            // Independent convolution of the mirrored two-sample signal with the normalized kernel.
            XCTAssertEqual(edge[0], -20.905972, accuracy: 0.0001)
            XCTAssertEqual(edge[1], 120.905972, accuracy: 0.0001)
        }
    }

    func test_defaultMetadataShortcutPreservesNonDefaultColorEncoding() throws {
        let encodings: [ColorEncoding] = [
            .srgb, .grayscaleD65,
            ColorEncoding(useICC: true, colorSpace: .rgb, whitePoint: .d65, primaries: .srgb,
                          transferFunction: .srgb, renderingIntent: .relative),
            ColorEncoding(useICC: false, colorSpace: .rgb, whitePoint: .d65, primaries: .srgb,
                          transferFunction: .linear, renderingIntent: .relative)
        ]
        for (index, encoding) in encodings.enumerated() {
            let metadata = ImageMetadata(
                allDefault: true, orientation: 1, intrinsicSize: nil, preview: nil, animation: nil,
                bitDepth: .standard, modular16BitBufferSufficient: true, extraChannels: [], xybEncoded: true,
                colorEncoding: encoding, intensityTarget: 255, minNits: 0,
                relativeToMaxDisplay: false, linearBelow: 0)
            var writer = BitWriter()
            try metadata.write(to: &writer)
            XCTAssertEqual(writer.bitCount == 1, index == 0)
            var reader = BitReader(writer.finishToData())
            let decoded = try ImageMetadata.read(from: &reader)
            XCTAssertEqual(decoded.allDefault, index == 0)
            XCTAssertEqual(decoded.colorEncoding.colorSpace, encoding.colorSpace)
            XCTAssertEqual(decoded.colorEncoding.useICC, encoding.useICC)
            XCTAssertEqual(decoded.colorEncoding.transferFunction, encoding.transferFunction)
        }
    }

    func test_sizeHeaderUsesTheSquareRatioWithoutWritingRedundantWidth() throws {
        for (width, height, expectedBits) in [(300, 300, 15), (2048, 2048, 19), (1, 1, 15), (17, 9, 26)] {
            let size = SizeHeader(xsize: UInt32(width), ysize: UInt32(height))
            var writer = BitWriter()
            try size.write(to: &writer)
            XCTAssertEqual(writer.bitCount, expectedBits)
            var reader = BitReader(writer.finishToData())
            XCTAssertEqual(try SizeHeader.read(from: &reader), size)
        }
    }

    func test_epfLoopFilterWritesTheDeclaredTablesAndModularSigma() throws {
        for modular in [false, true] {
            var filter = LoopFilter(allDefault: false, gab: true, epfIters: 3)
            if !modular { filter.epfSharpLut = (0..<8).map { Float($0) / 8 } }
            filter.epfChannelScale = [32, 4, 2]
            filter.epfPass1ZeroFlush = 0.25
            filter.epfPass2ZeroFlush = 0.5
            if !modular { filter.epfQuantMul = 0.5 }
            filter.epfPass0SigmaScale = 0.75
            filter.epfPass2SigmaScale = 4
            filter.epfBorderSadMul = 0.5
            if modular { filter.epfSigmaForModular = 2 }
            var writer = BitWriter()
            try filter.write(to: &writer, isModular: modular)
            var reader = BitReader(writer.finishToData())
            XCTAssertEqual(try LoopFilter.read(from: &reader, isModular: modular), filter)
        }
        var writer = BitWriter()
        XCTAssertThrowsError(try LoopFilter(allDefault: false, epfIters: 4).write(to: &writer))
    }

    func test_effectiveVarDCTEffortProducesDeterministicDjxlCompatibleStreams() async throws {
        let djxl = try requireExecutable("djxl")
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let width = 129, height = 97
        let planes = Self.samples(width: width, height: height, precision: 8, signed: false, seed: 73, channels: 3)
        let descriptor = Self.descriptor(Self.general, width: width, height: height, precision: 8, signed: false, channels: 3)
        let backend = DicomJXLSwiftBackend()
        var outputs: [Data] = []
        for effort in [1, 4, 7] {
            let request = DicomFrameEncodeRequest(
                frame: Self.frame(planes, width: width, height: height, precision: 8, bitsAllocated: 8),
                descriptor: descriptor, targetTransferSyntaxUID: Self.general.rawValue,
                intent: .jpegXL(options: .init(distance: 1, effort: effort)), iccProfile: nil)
            let encoded = try await backend.encode(request)
            let repeated = try await backend.encode(request)
            XCTAssertEqual(encoded, repeated, "effort \(effort) must not depend on dictionary hash order")
            outputs.append(encoded)
            let input = dir.appendingPathComponent("effort-\(effort).jxl")
            let output = dir.appendingPathComponent("effort-\(effort).pnm")
            try encoded.write(to: input)
            let result = try Self.run(djxl, [input.path, output.path, "--quiet"])
            XCTAssertEqual(result.status, 0, result.error)
            let (decodedWidth, decodedHeight, _, decoded) = try Self.parsePNM(Data(contentsOf: output))
            XCTAssertEqual(decodedWidth, width)
            XCTAssertEqual(decodedHeight, height)
            XCTAssertGreaterThan(Self.psnr(planes, decoded, maxValue: 255), 25)
        }
        XCTAssertEqual(Set(outputs).count, 3, "effort must change the transform and entropy search")
    }

    func test_varDCTEntropySelectionPreservesAlphaAcrossGlobalAndTiledGroups() throws {
        let djxl = try requireExecutable("djxl")
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (width, height, channels) in [(53, 37, 2), (257, 17, 4)] {
            let colors = Self.samples(width: width, height: height, precision: 8,
                                      signed: false, seed: 81, channels: channels - 1)
            let alpha = (0..<(width * height)).map { Int32(($0 % width * 7 + $0 / width * 3) % 256) }
            var frame = ImageFrame(width: width, height: height, channels: channels,
                                   pixelType: .uint8, colorSpace: channels == 2 ? .grayscale : .sRGB)
            frame.data = Array(Self.stored(colors + [alpha], bitsAllocated: 8))
            let encoded = try VarDCTBitstreamWriter.encode(frame: frame)
            let input = dir.appendingPathComponent("alpha-\(channels).jxl")
            let output = dir.appendingPathComponent("alpha-\(channels).pam")
            try encoded.write(to: input)
            let result = try Self.run(djxl, [input.path, output.path, "--quiet", "--bits_per_sample=8"])
            XCTAssertEqual(result.status, 0, result.error)
            let pam = try Data(contentsOf: output)
            let marker = try XCTUnwrap(pam.range(of: Data("ENDHDR\n".utf8)))
            let reference = Array(pam[marker.upperBound...])
            XCTAssertEqual(reference.count, width * height * channels)
            let decoded = try JXLDecoder().decode(encoded)
            XCTAssertEqual(decoded.channels, channels)
            for i in alpha.indices {
                XCTAssertEqual(reference[i * channels + channels - 1], UInt8(alpha[i]))
                XCTAssertEqual(decoded.data[i * channels + channels - 1], UInt8(alpha[i]))
            }
        }
    }

    func test_ownVarDCTStreamsAreAcceptedByDjxlAndTrackCjxlFidelity() async throws {
        let cjxl = try requireExecutable("cjxl")
        let djxl = try requireExecutable("djxl")
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = DicomJXLSwiftBackend()
        let cases: [(name: String, width: Int, height: Int, precision: Int, signed: Bool, channels: Int, distance: Double)] = [
            ("gray8-d1", 300, 271, 8, false, 1, 1),
            ("gray8-d2", 300, 271, 8, false, 1, 2),
            ("gray16-d1", 257, 200, 16, false, 1, 1),
            ("gray12-d1", 257, 200, 12, false, 1, 1),
            ("gray12s-d1", 129, 97, 12, true, 1, 1),
            ("gray16s-d1", 129, 97, 16, true, 1, 1),
            ("rgb8-d1", 300, 277, 8, false, 3, 1),
            ("rgb8-d4", 300, 277, 8, false, 3, 4),
            ("rgb8-tiny-d1", 53, 37, 8, false, 3, 1),
            ("rgb8-odd-upsample-d15", 53, 37, 8, false, 3, 15),
            ("gray12-odd-upsample-d15", 53, 37, 12, false, 1, 15),
        ]
        for c in cases {
            let planes = Self.samples(width: c.width, height: c.height, precision: c.precision, signed: c.signed, seed: 50, channels: c.channels)
            let bitsAllocated = c.precision > 8 ? 16 : 8
            let descriptor = Self.descriptor(Self.general, width: c.width, height: c.height, precision: c.precision, signed: c.signed, channels: c.channels)
            let started = Date()
            let codestream = try await backend.encode(DicomFrameEncodeRequest(
                frame: Self.frame(planes, width: c.width, height: c.height, precision: c.precision, bitsAllocated: bitsAllocated),
                descriptor: descriptor, targetTransferSyntaxUID: Self.general.rawValue,
                intent: .jpegXL(options: .init(distance: c.distance)), iccProfile: nil))
            let encodeMs = Date().timeIntervalSince(started) * 1000
            XCTAssertEqual(codestream.prefix(2), Data([0xFF, 0x0A]), "\(c.name): raw codestream")
            let inspection = try DicomJXLSwiftBackend.inspectFrame(codestream)
            XCTAssertEqual(inspection.bitsPerSample, c.precision)
            // djxl accepts the stream at the declared bit depth.
            let jxl = dir.appendingPathComponent(c.name + ".own.jxl")
            try codestream.write(to: jxl)
            let ownPnm = dir.appendingPathComponent(c.name + ".own.pnm")
            let result = try Self.run(djxl, [jxl.path, ownPnm.path, "--quiet", "--bits_per_sample=\(c.precision)"])
            XCTAssertEqual(result.status, 0, "djxl rejects the own stream \(c.name): \(result.error)")
            let (_, _, maxval, djxlPlanes) = try Self.parsePNM(try Data(contentsOf: ownPnm))
            XCTAssertEqual(maxval, (1 << c.precision) - 1)
            // The codestream is unsigned; signed sources are level-shifted.
            let unsigned = c.signed ? planes.map { $0.map { $0 + (1 << Int32(c.precision - 1)) } } : planes
            let ownPSNR = Self.psnr(unsigned, djxlPlanes, maxValue: Double(maxval))
            // The own decoder agrees with djxl on the own stream too.
            let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
            // The frame contract carries two's complement for signed samples.
            let ownDecoded = Self.planes(from: decoded.buffer.data, bitsAllocated: bitsAllocated, channels: c.channels)
                .map { c.signed ? $0.map { Int32(Int16(truncatingIfNeeded: $0)) + (1 << Int32(c.precision - 1)) } : $0 }
            var maxDiff = 0
            for ch in 0..<c.channels { for i in 0..<ownDecoded[ch].count { maxDiff = max(maxDiff, abs(Int(ownDecoded[ch][i]) - Int(djxlPlanes[ch][i]))) } }
            XCTAssertLessThanOrEqual(maxDiff, Self.tolerance(bits: c.precision).max, "\(c.name): own decoder vs djxl on the own stream")
            // cjxl at the same distance is the fidelity reference.
            let source = dir.appendingPathComponent(c.name + (c.channels == 3 ? ".ppm" : ".pgm"))
            try Self.pnm(unsigned, width: c.width, height: c.height, precision: c.precision).write(to: source)
            let cjxlOut = dir.appendingPathComponent(c.name + ".cjxl.jxl")
            XCTAssertEqual(try Self.run(cjxl, [source.path, cjxlOut.path, "--container=0", "--quiet", "-d", "\(c.distance)", "-e", "7"]).status, 0)
            let cjxlPnm = dir.appendingPathComponent(c.name + ".cjxl.pnm")
            XCTAssertEqual(try Self.run(djxl, [cjxlOut.path, cjxlPnm.path, "--quiet", "--bits_per_sample=\(c.precision)"]).status, 0)
            let (_, _, _, cjxlPlanes) = try Self.parsePNM(try Data(contentsOf: cjxlPnm))
            let cjxlPSNR = Self.psnr(unsigned, cjxlPlanes, maxValue: Double(maxval))
            let cjxlBytes = try Data(contentsOf: cjxlOut).count
            print("JPEGXL_VARDCT_ENCODE \(c.name): own \(codestream.count) B PSNR \(String(format: "%.2f", ownPSNR)) dB "
                  + "(\(String(format: "%.0f", encodeMs)) ms) | cjxl \(cjxlBytes) B PSNR \(String(format: "%.2f", cjxlPSNR)) dB")
            // Fidelity within 3 dB of cjxl at the same distance; the ratio is recorded, not asserted.
            XCTAssertGreaterThanOrEqual(ownPSNR, cjxlPSNR - 3, "\(c.name): own PSNR \(ownPSNR) vs cjxl \(cjxlPSNR)")
        }
    }

    func test_transcoderWritesLossyDerivationRecordsOnlyForAnExplicitDistance() async throws {
        let (width, height) = (301, 277)
        let source = Self.samples(width: width, height: height, precision: 16, signed: true, seed: 60)[0]
        let native = try Self.file(frames: [Self.stored([source], bitsAllocated: 16)], syntax: .explicitVRLittleEndian,
                                   width: width, height: height, precision: 16, signed: true)
        let transcoder = DicomTranscoder()
        // distance 0 → Modular, reversible, no lossy record.
        let reversible = try await transcoder.transcode(native, to: Self.general, intent: .jpegXL(options: .init(distance: 0, effort: 5)),
                                                        environment: Self.experimental)
        let reversibleDecoder = try DCMDecoder(data: reversible)
        XCTAssertNil(reversibleDecoder.dataSet.element(for: .lossyImageCompression))
        XCTAssertEqual(reversibleDecoder.info(for: .sopInstanceUID), "2.25.23320001", "reversible keeps the SOP Instance UID")
        let restored = try await transcoder.transcode(reversible, to: .explicitVRLittleEndian, intent: .reversible, environment: Self.experimental)
        XCTAssertEqual(try DCMDecoder(data: restored).getAllFrames()?.first?.data, Self.stored([source], bitsAllocated: 16))
        // distance 1 → VarDCT, derived object with the full lossy record.
        let lossy = try await transcoder.transcode(native, to: Self.general, intent: .jpegXL(options: .init(distance: 1)),
                                                   environment: Self.experimental)
        let decoder = try DCMDecoder(data: lossy)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), Self.general.rawValue)
        XCTAssertEqual(decoder.dataSet.strings(for: .lossyImageCompression), ["01"])
        XCTAssertEqual(decoder.dataSet.strings(for: .lossyImageCompressionMethod), ["ISO_18181_1"])
        XCTAssertNotNil(decoder.dataSet.element(for: .lossyImageCompressionRatio))
        XCTAssertNotEqual(decoder.info(for: .sopInstanceUID), "2.25.23320001", "a lossy derivation is a new SOP instance")
        let sourceItems = decoder.dataSet.element(for: .sourceImageSequence)?.sequenceItems ?? []
        XCTAssertEqual(sourceItems.first?.dataSet.strings(for: .referencedSOPInstanceUID), ["2.25.23320001"])
        let derivations = decoder.dataSet.element(for: 0x0008_9215)?.sequenceItems ?? []
        XCTAssertEqual(derivations.first?.dataSet.strings(for: 0x0008_0100), ["113040"], "Derivation Code Sequence: Lossy Compression")
        XCTAssertEqual(decoder.intValue(for: .bitsStored), 16)
        XCTAssertEqual(decoder.intValue(for: .pixelRepresentation), 1, "signed samples are not truncated to fit the codec")
        let frameData = try decoder.makeEncapsulatedPixelFrameReader().frameData(at: 0)
        let structure = JXLDecoder().inspectFrameStructure(frameData)
        XCTAssertEqual(structure.encoding, .varDCT)
        // Reopened natively the samples are close to the source (lossy), never the codestream's unsigned representation.
        let reopened = try await transcoder.transcode(lossy, to: .explicitVRLittleEndian, intent: .reversible, environment: Self.experimental)
        let back = try XCTUnwrap(try DCMDecoder(data: reopened).getAllFrames()?.first?.data)
        let backPlanes = Self.planes(from: back, bitsAllocated: 16, channels: 1)[0].map { Int32(Int16(truncatingIfNeeded: $0)) }
        XCTAssertGreaterThan(Self.psnr([source.map { $0 + 32768 }], [backPlanes.map { $0 + 32768 }], maxValue: 65535), 35)
        // Reversible intent never picks the lossy route, whatever the destination.
        XCTAssertEqual(try DicomTranscoder().plan(native, to: Self.general, intent: .reversible, environment: Self.experimental).intent.isLossy, false)
    }

    func test_lossyDescriptor_acceptsEmptyICCAndRefusesNonemptyICC() throws {
        let native = try Self.file(frames: [Data(repeating: 12, count: 64)], syntax: .explicitVRLittleEndian,
            width: 8, height: 8, precision: 8, signed: false)
        for profile in [Data(), Data([1])] {
            var dataSet = try DCMDecoder(data: native).dataSet
            dataSet.set(.init(tag: DicomTag.iccProfile.rawValue, vr: .OB, value: .bytes(profile)))
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let decoder = try DCMDecoder(data: bytes)
            let prepare = {
                try DicomTranscoder().prepareJPEGXLDescriptor(decoder: decoder, destination: Self.general,
                    intent: .jpegXL(options: .init(distance: 1)), environment: Self.experimental)
            }
            if profile.isEmpty { XCTAssertNoThrow(try prepare()) } else { XCTAssertThrowsError(try prepare()) }
        }
    }

    func test_cancellationLeavesNoPartialOutput() async throws {
        let (width, height) = (600, 520)
        let source = Self.samples(width: width, height: height, precision: 8, signed: false, seed: 70, channels: 3)
        let native = try Self.file(frames: [Self.stored(source, bitsAllocated: 8)], syntax: .explicitVRLittleEndian,
                                   width: width, height: height, precision: 8, signed: false, channels: 3)
        let destination = try temporaryDirectory().appendingPathComponent("cancelled.dcm")
        let general = Self.general
        let environment = Self.experimental
        let task = Task<Data, Error> {
            let result = try await DicomCodecWorkflowEngine().transcode(
                native, to: general, intent: .jpegXL(options: .init(distance: 1)), environment: environment,
                verifyDecodedPixels: false, destinationURL: destination, progress: nil)
            return result.data
        }
        task.cancel()
        do {
            _ = try await task.value
            // Completing before the cancellation was observed is acceptable only with a complete file.
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertNoThrow(try DCMDecoder(data: try Data(contentsOf: destination)))
        } catch {
            XCTAssertTrue(error is CancellationError || "\(error)".lowercased().contains("cancel"), "\(error)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "no partial output after cancellation")
        }
        // A cancelled frame decode surfaces as CancellationError.
        let descriptor = Self.descriptor(Self.general, width: 64, height: 48, precision: 8, signed: false, channels: 3)
        let codestream = try await DicomJXLSwiftBackend().encode(DicomFrameEncodeRequest(
            frame: Self.frame(Self.samples(width: 64, height: 48, precision: 8, signed: false, seed: 1, channels: 3), width: 64, height: 48, precision: 8, bitsAllocated: 8),
            descriptor: descriptor, targetTransferSyntaxUID: Self.general.rawValue, intent: .jpegXL(options: .init(distance: 1)), iccProfile: nil))
        let decodeTask = Task { try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0)) }
        decodeTask.cancel()
        do {
            _ = try await decodeTask.value
        } catch is CancellationError {
        } catch {
            XCTFail("cancellation surfaced as \(error)")
        }
    }

    // MARK: - Helpers

    private static func decodeSync(_ data: Data) throws -> ImageFrame {
        try JXLDecoder().decode(data)
    }

    private static func samples(width: Int, height: Int, precision: Int, signed: Bool, seed: UInt32, channels: Int = 1) -> [[Int32]] {
        var state = seed &* 2_654_435_761 &+ 1
        func noise() -> Int32 {
            state = state &* 1_103_515_245 &+ 12_345
            return Int32((state >> 16) & 0x1F) - 16
        }
        let low: Int32 = signed ? -(1 << Int32(precision - 1)) : 0
        let high: Int32 = signed ? (1 << Int32(precision - 1)) - 1 : (1 << Int32(precision)) - 1
        let span = Double(high) - Double(low)
        return (0..<channels).map { c in
            var out = [Int32](repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let phase = Double(c) * 0.7
                    let v = Double(low) + span * (0.5 + 0.4 * sin(Double(x) / (5 + Double(width) / 40) + phase) * cos(Double(y) / (4 + Double(height) / 33)))
                    let n = precision > 6 ? noise() * Int32(max(1, precision - 7)) : 0
                    out[y * width + x] = min(max(Int32(v.rounded()) &+ n, low), high)
                }
            }
            return out
        }
    }

    private static func stored(_ planes: [[Int32]], bitsAllocated: Int) -> Data {
        let count = planes[0].count
        var data = Data(capacity: count * planes.count * (bitsAllocated / 8))
        for i in 0..<count {
            for plane in planes {
                let v = plane[i]
                if bitsAllocated == 8 {
                    data.append(UInt8(truncatingIfNeeded: v))
                } else {
                    let u = UInt16(truncatingIfNeeded: v)
                    data.append(UInt8(u & 0xFF)); data.append(UInt8(u >> 8))
                }
            }
        }
        return data
    }

    private static func planes(from data: Data, bitsAllocated: Int, channels: Int) -> [[Int32]] {
        let bytes = [UInt8](data)
        let count = bytes.count / (channels * (bitsAllocated / 8))
        return (0..<channels).map { c in
            (0..<count).map { i in
                if bitsAllocated == 8 { return Int32(bytes[i * channels + c]) }
                let o = (i * channels + c) * 2
                return Int32(bytes[o]) | Int32(bytes[o + 1]) << 8
            }
        }
    }

    private static func psnr(_ a: [[Int32]], _ b: [[Int32]], maxValue: Double) -> Double {
        var sum = 0.0
        var n = 0
        for (pa, pb) in zip(a, b) {
            for (x, y) in zip(pa, pb) {
                let d = Double(x) - Double(y)
                sum += d * d
                n += 1
            }
        }
        let mse = sum / Double(max(1, n))
        return mse == 0 ? 99 : 10 * log10(maxValue * maxValue / mse)
    }

    private static func descriptor(
        _ syntax: DicomTransferSyntax, width: Int, height: Int, precision: Int, signed: Bool, channels: Int = 1
    ) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(
            transferSyntaxUID: syntax.rawValue, rows: height, columns: width,
            bitsAllocated: precision > 8 ? 16 : 8,
            bitsStored: precision, highBit: precision - 1, pixelRepresentation: signed ? 1 : 0,
            samplesPerPixel: channels,
            photometricInterpretation: channels == 3 ? "RGB" : "MONOCHROME2",
            planarConfiguration: channels == 3 ? 0 : nil
        )
    }

    private static func frame(_ planes: [[Int32]], width: Int, height: Int, precision: Int, bitsAllocated: Int) -> DicomCodecDecodedFrame {
        DicomCodecDecodedFrame(
            buffer: .owned(stored(planes, bitsAllocated: bitsAllocated)), width: width, height: height,
            bitsPerSample: precision, componentCount: planes.count
        )
    }

    private static func file(
        frames: [Data], syntax: DicomTransferSyntax, width: Int, height: Int, precision: Int, signed: Bool, channels: Int = 1
    ) throws -> Data {
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23320001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23320002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23320003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["JPEGXL^VARDCT"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["JXL-2333"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(channels)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([channels == 3 ? "RGB" : "MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([precision > 8 ? 16 : 8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([signed ? 1 : 0]))
        ]
        if channels == 3 {
            elements.append(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0])))
        }
        if frames.count > 1 {
            elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(frames.count)"])))
        }
        if syntax == .explicitVRLittleEndian {
            elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: precision > 8 ? .OW : .OB,
                                             value: .bytes(frames.reduce(into: Data()) { $0.append($1) })))
        } else {
            elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                                             value: .bytes(try DicomTranscoder.encapsulate(fragments: frames).pixelData)))
        }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements), options: .init(transferSyntax: syntax))
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jpegxl-vardct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func pnm(_ planes: [[Int32]], width: Int, height: Int, precision: Int) -> Data {
        let channels = planes.count
        var out = Data("\(channels == 3 ? "P6" : "P5")\n\(width) \(height)\n\((1 << precision) - 1)\n".utf8)
        for i in 0..<(width * height) {
            for c in 0..<channels {
                let v = planes[c][i]
                if precision > 8 { out.append(UInt8((v >> 8) & 0xFF)) }
                out.append(UInt8(v & 0xFF))
            }
        }
        return out
    }

    private static func parsePNM(_ d: Data) throws -> (width: Int, height: Int, maxval: Int, planes: [[Int32]]) {
        let (w, h, maxval, body) = try JPEGXLLibjxlCorpusTests.parsePNM(d)
        let bytes = maxval > 255 ? 2 : 1
        let channels = body.count / (w * h * bytes)
        let planes: [[Int32]] = (0..<channels).map { c in
            (0..<(w * h)).map { i in
                let o = (i * channels + c) * bytes
                return bytes == 2 ? Int32(body[o]) << 8 | Int32(body[o + 1]) : Int32(body[o])
            }
        }
        return (w, h, maxval, planes)
    }
}
