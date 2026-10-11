import DicomCodecs
import Foundation
import XCTest
@testable import DicomCore

/// Issue #3035: the own JPEG 2000 / HTJ2K decoder (J2KSwift CPU core) on irreversible colour codestreams written by
/// independent encoders (OpenJPEG `opj_compress`, OpenJPH `ojph_compress`), compared with independent decoders of the
/// same codestream: the OpenJPEG library and `ojph_expand`. Covers the ICT and no colour transform, an RGB label over
/// an ICT codestream, tiles, precincts, layers, progressions and 8/12/16-bit precision; quality-layer, resolution and
/// region decodes; subsampled components and damaged codestreams refused typed. The limits are those of the product's
/// gate (`DICOMSwiftLossyDecodeGate.colourLimit`, AppShell): at most 2 steps and RMSE 0.5 up to 12 bits, 4 and 1.0
/// above. Tools come from the local Homebrew install; without them the tests skip.
final class DicomJ2KIrreversibleColourTests: XCTestCase {
    private static let opjCompress = "/opt/homebrew/bin/opj_compress"
    private static let opjDecompress = "/opt/homebrew/bin/opj_decompress"
    private static let ojphCompress = "/opt/homebrew/bin/ojph_compress"
    private static let ojphExpand = "/opt/homebrew/bin/ojph_expand"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("j2k-colour-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func requireTools() throws {
        try XCTSkipUnless([Self.opjCompress, Self.opjDecompress, Self.ojphCompress, Self.ojphExpand]
            .allSatisfy { FileManager.default.isExecutableFile(atPath: $0) }, "OpenJPEG/OpenJPH command-line tools are not installed")
    }

    struct Profile {
        let name: String
        let htj2k: Bool
        var precision = 8
        var width = 61
        var height = 45
        var options: [String]
        var photometric = "YBR_ICT"
        var syntax: DicomTransferSyntax { htj2k ? .htj2k : .jpeg2000 }
    }

    private static func limit(precision: Int) -> (maximum: Int, rmse: Double) { precision <= 12 ? (2, 0.5) : (4, 1.0) }

    // MARK: - Full decodes

    func test_irreversibleColour_ownDecoderStaysWithinTheLimitOfOpenJPEGAndOpenJPH() async throws {
        try requireTools()
        let ht = ["-reversible", "false", "-qstep", "0.01"]
        let profiles: [Profile] = [
            Profile(name: "opj-ict", htj2k: false, options: ["-I", "-r", "8"]),
            Profile(name: "opj-nomct", htj2k: false, options: ["-I", "-mct", "0", "-r", "8"], photometric: "RGB"),
            Profile(name: "opj-tiles-layers-rpcl", htj2k: false, width: 97, height: 71,
                    options: ["-I", "-t", "32,16", "-r", "40,10,4", "-p", "RPCL", "-c", "[32,32],[16,16]", "-n", "3"]),
            Profile(name: "opj-ict-12", htj2k: false, precision: 12, options: ["-I", "-r", "8"]),
            Profile(name: "opj-ict-16", htj2k: false, precision: 16, options: ["-I", "-r", "8"]),
            Profile(name: "ojph-ict", htj2k: true, options: ht + ["-colour_trans", "true"]),
            Profile(name: "ojph-ict-rgb-label", htj2k: true, options: ht + ["-colour_trans", "true"], photometric: "RGB"),
            Profile(name: "ojph-nomct", htj2k: true, options: ht + ["-colour_trans", "false"], photometric: "RGB"),
            Profile(name: "ojph-tiles", htj2k: true, width: 97, height: 71,
                    options: ht + ["-colour_trans", "true", "-tile_size", "{32,32}", "-num_decomps", "3"]),
            Profile(name: "ojph-ict-12", htj2k: true, precision: 12, options: ["-reversible", "false", "-qstep", "0.005", "-colour_trans", "true"]),
            Profile(name: "ojph-ict-16", htj2k: true, precision: 16, options: ["-reversible", "false", "-qstep", "0.005", "-colour_trans", "true"])
        ]
        for profile in profiles {
            let stream = try encode(Self.samples(profile), profile)
            let own = try await DicomJ2KSwiftBackend().decode(DicomFrameDecodeRequest(frameData: stream, descriptor: Self.descriptor(profile), frameIndex: 0))
            XCTAssertEqual([own.width, own.height, own.componentCount, own.bitsPerSample], [profile.width, profile.height, 3, profile.precision], profile.name)
            let samples = Self.integers(own.buffer.data, precision: profile.precision)
            XCTAssertTrue(samples.allSatisfy { (0..<(1 << profile.precision)).contains($0) }, "\(profile.name): clipped to the precision")
            let limit = Self.limit(precision: profile.precision)
            var references: [(String, [Int])] = []
            if !profile.htj2k || DicomJPEG2000Codec.supportsHTJ2K, DicomJPEG2000Codec.isAvailable {
                let openJPEG = try DicomJPEG2000Codec.decode(stream)
                XCTAssertEqual(openJPEG.bitsPerSample, profile.precision, profile.name)
                references.append(("OpenJPEG", Self.integers(openJPEG.bytes, precision: profile.precision)))
            }
            if profile.htj2k { references.append(("OpenJPH", try reference(stream, profile).samples)) }
            XCTAssertFalse(references.isEmpty, "\(profile.name): no independent decoder ran")
            for (oracle, expected) in references {
                let measured = try XCTUnwrap(Self.difference(samples, expected), "\(profile.name) \(oracle)")
                XCTAssertLessThanOrEqual(measured.maximum, limit.maximum, "\(profile.name) vs \(oracle): \(measured)")
                XCTAssertLessThanOrEqual(measured.rmse, limit.rmse, "\(profile.name) vs \(oracle): \(measured)")
                // A channel swap or a transform applied twice cannot hide inside the limit.
                let rotated = samples.indices.map { samples[$0 - $0 % 3 + ($0 % 3 + 1) % 3] }
                XCTAssertGreaterThan(Self.difference(rotated, expected)?.rmse ?? 0, limit.rmse * 10, "\(profile.name) vs \(oracle)")
            }
        }
    }

    /// The frame reader selects the own backend and reports the precision of the samples, RGB16 above 8 bits.
    func test_frameReader_decodesIrreversibleColourThroughTheOwnBackendWithItsPrecision() async throws {
        try requireTools()
        for profile in [Profile(name: "reader-8", htj2k: false, options: ["-I", "-r", "8"]),
                        Profile(name: "reader-12", htj2k: true, precision: 12, options: ["-reversible", "false", "-qstep", "0.005", "-colour_trans", "true"])] {
            let stream = try encode(Self.samples(profile), profile)
            let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: try Self.part10(profile, fragments: [stream])))
            let execution = try await reader.frameExecution(at: 0, environment: [:])
            XCTAssertEqual(execution.backendIdentifier, DicomCodecBackendIdentifier.j2kSwiftCPU.rawValue, profile.name)
            XCTAssertEqual([execution.frame.metadata.bitsAllocated, execution.frame.metadata.bitsStored, execution.frame.metadata.highBit],
                           [profile.precision > 8 ? 16 : 8, profile.precision, profile.precision - 1], profile.name)
            switch execution.frame.pixels {
            case .rgb8 where profile.precision == 8, .rgb16 where profile.precision > 8: break
            default: XCTFail("\(profile.name): \(execution.frame.pixels)")
            }
        }
    }

    // MARK: - Partial decodes

    /// Quality layers and resolution reductions against the same layer/level of OpenJPEG and OpenJPH; regions are the
    /// crop of the full decode.
    func test_partialDecodes_matchTheSameLayerLevelAndRegionOfTheReference() async throws {
        try requireTools()
        let profiles = [
            Profile(name: "partial-opj", htj2k: false, width: 200, height: 150, options: ["-I", "-r", "40,10,3", "-t", "64,64", "-n", "4"]),
            Profile(name: "partial-ojph", htj2k: true, width: 200, height: 150,
                    options: ["-reversible", "false", "-qstep", "0.01", "-colour_trans", "true", "-num_decomps", "4"])
        ]
        for profile in profiles {
            let stream = try encode(Self.samples(profile), profile)
            let descriptor = Self.descriptor(profile)
            let backend = DicomJ2KSwiftBackend()
            let full = Self.integers(try await backend.decode(DicomFrameDecodeRequest(frameData: stream, descriptor: descriptor, frameIndex: 0)).buffer.data,
                                     precision: 8)
            // The backend names the resolution kept (decomposition levels minus the reduction), as the frame reader asks.
            let levels = try DicomJ2KCodestreamInspector.inspect(stream).decompositionLevels
            for level in [1, 2] {
                let own = try await backend.decode(DicomFrameDecodeRequest(frameData: stream, descriptor: descriptor, frameIndex: 0,
                                                                           partialRequest: .init(resolutionLevel: levels - level)))
                let expected = try reference(stream, profile, reduction: level)
                XCTAssertEqual([own.width, own.height], [expected.width, expected.height], "\(profile.name) level \(level)")
                let measured = try XCTUnwrap(Self.difference(Self.integers(own.buffer.data, precision: 8), expected.samples))
                XCTAssertLessThanOrEqual(measured.maximum, 2, "\(profile.name) level \(level): \(measured)")
                XCTAssertLessThanOrEqual(measured.rmse, 0.5, "\(profile.name) level \(level): \(measured)")
            }
            let region = DicomPartialDecodeRequest.Region(x: 37, y: 21, width: 90, height: 70)
            let cropped = try await backend.decode(DicomFrameDecodeRequest(frameData: stream, descriptor: descriptor, frameIndex: 0,
                                                                           partialRequest: .init(region: region)))
            var crop: [Int] = []
            for y in region.y..<(region.y + region.height) {
                for x in region.x..<(region.x + region.width) { for c in 0..<3 { crop.append(full[(y * profile.width + x) * 3 + c]) } }
            }
            XCTAssertEqual(Self.integers(cropped.buffer.data, precision: 8), crop, "\(profile.name): region")
            guard !profile.htj2k else { continue }
            // The first quality layer against `opj_decompress -l 1`.
            let layer = try await backend.decode(DicomFrameDecodeRequest(frameData: stream, descriptor: descriptor, frameIndex: 0,
                                                                         partialRequest: .init(maximumQualityLayer: 0)))
            let expected = try reference(stream, profile, extra: ["-l", "1"])
            let measured = try XCTUnwrap(Self.difference(Self.integers(layer.buffer.data, precision: 8), expected.samples))
            XCTAssertLessThanOrEqual(measured.maximum, 2, "\(profile.name) layer 1: \(measured)")
            XCTAssertLessThanOrEqual(measured.rmse, 0.5, "\(profile.name) layer 1: \(measured)")
        }
    }

    // MARK: - Refusals

    /// Subsampled chroma (ISO 15444-1 SIZ XRsiz/YRsiz) has no representation in the interleaved RGB frame contract.
    func test_subsampledChroma_isRefusedTypedByTheOwnBackend() async throws {
        try requireTools()
        for htj2k in [false, true] {
            let profile = Profile(name: "sub-\(htj2k)", htj2k: htj2k, options: htj2k ? ["-reversible", "false", "-qstep", "0.01"] : ["-I", "-r", "8"])
            let stream = try encodeSubsampled(Self.samples(profile), profile)
            do {
                _ = try await DicomJ2KSwiftBackend().decode(DicomFrameDecodeRequest(frameData: stream, descriptor: Self.descriptor(profile), frameIndex: 0))
                XCTFail("\(profile.name): subsampled components were decoded")
            } catch let error as DicomJ2KSwiftBackendError {
                guard case .unsupportedShape(_, let reason) = error else { return XCTFail("\(profile.name): \(error)") }
                XCTAssertTrue(reason.contains("subsampled"), reason)
            }
        }
    }

    /// Damaged colour codestreams fail with an error (bit errors inside packets and a missing EOC may decode a bounded
    /// frame) and never crash. The SIZ hardening of #3018 is not repeated here.
    func test_damagedColourCodestreams_failTypedWithoutCrash() async throws {
        try requireTools()
        let profile = Profile(name: "damaged", htj2k: false, width: 64, height: 48, options: ["-I", "-r", "8"])
        let stream = try encode(Self.samples(profile), profile)
        let sod = try XCTUnwrap(stream.range(of: Data([0xFF, 0x93]))).lowerBound
        let cod = try XCTUnwrap(stream.range(of: Data([0xFF, 0x52]))).lowerBound
        let qcd = try XCTUnwrap(stream.range(of: Data([0xFF, 0x5C]))).lowerBound
        func patched(_ offset: Int, _ value: UInt8) -> Data { var copy = stream; copy[offset] = value; return copy }
        var junk = Data(stream.prefix(sod + 2)); junk.append(Data(repeating: 0xFF, count: 400))
        let cases: [(String, Data)] = [
            ("truncated-packets", Data(stream.prefix(sod + (stream.count - sod) / 2))),
            ("truncated-main-header", Data(stream.prefix(sod - 10))),
            ("marker-filled-packets", junk),
            ("cod-mct-7", patched(cod + 8, 7)),
            ("cod-transform-9", patched(cod + 13, 9)),
            ("qcd-style-reserved", patched(qcd + 4, 0x1F))
        ]
        for (name, data) in cases {
            do {
                _ = try await DicomJ2KSwiftBackend().decode(DicomFrameDecodeRequest(frameData: data, descriptor: Self.descriptor(profile), frameIndex: 0))
                XCTFail("\(name): decoded")
            } catch {
                XCTAssertFalse(error is CancellationError, name)
            }
        }
        // Tolerated as OpenJPEG tolerates them: bit errors inside the packets, a missing EOC marker. Either a typed error
        // or exactly one bounded frame.
        var flipped = stream
        for offset in stride(from: sod + 4, to: stream.count - 2, by: 7) { flipped[offset] ^= 0x5A }
        for data in [flipped, Data(stream.dropLast(2))] {
            if let frame = try? await DicomJ2KSwiftBackend().decode(DicomFrameDecodeRequest(frameData: data, descriptor: Self.descriptor(profile),
                                                                                              frameIndex: 0)) {
                XCTAssertEqual(frame.buffer.data.count, 64 * 48 * 3)
            }
        }
    }

    // MARK: - Cost (opt-in)

    /// `DICOM_J2K_COLOUR_COST=1` (run with `-c release`): decode time of the own backend and of the OpenJPEG library on
    /// the same 512 × 512 irreversible colour codestreams.
    func test_costReport() async throws {
        guard ProcessInfo.processInfo.environment["DICOM_J2K_COLOUR_COST"] == "1" else { throw XCTSkip("DICOM_J2K_COLOUR_COST is not set") }
        try requireTools()
        try XCTSkipUnless(DicomJPEG2000Codec.isAvailable && DicomJPEG2000Codec.supportsHTJ2K, "OpenJPEG 2.5 is not loaded")
        let profiles = [
            Profile(name: "cost-opj-8", htj2k: false, width: 512, height: 512, options: ["-I", "-r", "10"]),
            Profile(name: "cost-opj-12", htj2k: false, precision: 12, width: 512, height: 512, options: ["-I", "-r", "10"]),
            Profile(name: "cost-ojph-8", htj2k: true, width: 512, height: 512, options: ["-reversible", "false", "-qstep", "0.01", "-colour_trans", "true"])
        ]
        let repeats = 8
        for profile in profiles {
            let stream = try encode(Self.samples(profile), profile)
            let descriptor = Self.descriptor(profile)
            _ = try await DicomJ2KSwiftBackend().decode(DicomFrameDecodeRequest(frameData: stream, descriptor: descriptor, frameIndex: 0))
            var baseline = Self.physicalFootprint(), peak = baseline
            var start = Date()
            for _ in 0..<repeats {
                _ = try await DicomJ2KSwiftBackend().decode(DicomFrameDecodeRequest(frameData: stream, descriptor: descriptor, frameIndex: 0))
                peak = max(peak, Self.physicalFootprint())
            }
            let own = Date().timeIntervalSince(start) * 1000 / Double(repeats)
            let ownGrowth = Double(peak - baseline) / 1_048_576
            baseline = Self.physicalFootprint(); peak = baseline
            start = Date()
            for _ in 0..<repeats { _ = try DicomJPEG2000Codec.decode(stream); peak = max(peak, Self.physicalFootprint()) }
            let openJPEG = Date().timeIntervalSince(start) * 1000 / Double(repeats)
            print("J2K_COLOUR_CODEC_COST \(profile.name): own \(String(format: "%.2f", own)) ms (footprint growth \(String(format: "%.1f", ownGrowth)) MiB), "
                  + "OpenJPEG \(String(format: "%.2f", openJPEG)) ms (\(String(format: "%.1f", Double(peak - baseline) / 1_048_576)) MiB), \(stream.count) bytes")
        }
    }

    // MARK: - Fixtures

    /// Ramps with noise, saturated primaries and secondaries, black and white patches; the components always differ.
    static func samples(_ profile: Profile) -> [Int] {
        let maximum = (1 << profile.precision) - 1
        var state: UInt32 = 3035
        let patches: [[Int]] = [[maximum, 0, 0], [0, maximum, 0], [0, 0, maximum], [maximum, maximum, 0],
                                [0, maximum, maximum], [maximum, 0, maximum], [0, 0, 0], [maximum, maximum, maximum]]
        var output = [Int](repeating: 0, count: profile.width * profile.height * 3)
        for y in 0..<profile.height {
            for x in 0..<profile.width {
                let pixel = y * profile.width + x
                if y < 8, x / 6 < patches.count {
                    for c in 0..<3 { output[pixel * 3 + c] = patches[x / 6][c] }
                    continue
                }
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = Int(state >> 24) % max(1, (maximum + 1) / 32)
                output[pixel * 3] = x * maximum / max(1, profile.width - 1)
                output[pixel * 3 + 1] = (y * maximum / max(1, profile.height - 1) + noise) % (maximum + 1)
                output[pixel * 3 + 2] = ((x + y) * maximum / max(1, profile.width + profile.height - 2) / 2 + maximum / 3 + noise) % (maximum + 1)
            }
        }
        return output
    }

    static func descriptor(_ profile: Profile) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(transferSyntaxUID: profile.syntax.rawValue, rows: profile.height, columns: profile.width,
                                       bitsAllocated: profile.precision > 8 ? 16 : 8, bitsStored: profile.precision, highBit: profile.precision - 1,
                                       pixelRepresentation: 0, samplesPerPixel: 3, photometricInterpretation: profile.photometric,
                                       planarConfiguration: 0)
    }

    static func part10(_ profile: Profile, fragments: [Data]) throws -> Data {
        func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement { .init(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)])) }
        func str(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement { .init(tag: tag.rawValue, vr: vr, value: .strings([value])) }
        let elements: [DicomDataElement] = [
            str(.sopClassUID, .UI, "1.2.840.10008.5.1.4.1.1.7"), str(.sopInstanceUID, .UI, "2.25.30350001"),
            str(.studyInstanceUID, .UI, "2.25.30350002"), str(.seriesInstanceUID, .UI, "2.25.30350003"), str(.modality, .CS, "OT"),
            us(.rows, profile.height), us(.columns, profile.width), us(.samplesPerPixel, 3), str(.photometricInterpretation, .CS, profile.photometric),
            us(.planarConfiguration, 0), us(.bitsAllocated, profile.precision > 8 ? 16 : 8), us(.bitsStored, profile.precision),
            us(.highBit, profile.precision - 1), us(.pixelRepresentation, 0),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(try DicomTranscoder.encapsulate(fragments: fragments).pixelData))
        ]
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements), options: .init(transferSyntax: profile.syntax))
    }

    private func encode(_ samples: [Int], _ profile: Profile) throws -> Data {
        let base = directory.appendingPathComponent("\(profile.name)-\(UUID().uuidString.prefix(6))")
        let ppm = base.appendingPathExtension("ppm"), output = base.appendingPathExtension("j2c")
        var data = Data("P6\n\(profile.width) \(profile.height)\n\((1 << profile.precision) - 1)\n".utf8)
        for value in samples {
            if profile.precision > 8 { data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xFF)) } else { data.append(UInt8(value)) }
        }
        try data.write(to: ppm)
        try Self.run(profile.htj2k ? Self.ojphCompress : Self.opjCompress, ["-i", ppm.path, "-o", output.path] + profile.options)
        return try Data(contentsOf: output)
    }

    /// Chroma averaged over 2 × 1 cells, planar, through the tools' raw/YUV readers.
    private func encodeSubsampled(_ samples: [Int], _ profile: Profile) throws -> Data {
        let base = directory.appendingPathComponent("\(profile.name)-\(UUID().uuidString.prefix(6))")
        let raw = base.appendingPathExtension(profile.htj2k ? "yuv" : "rawl"), output = base.appendingPathExtension("j2c")
        var data = Data()
        for component in 0..<3 {
            let step = component == 0 ? 1 : 2
            for y in 0..<profile.height {
                for x in stride(from: 0, to: profile.width, by: step) {
                    let right = min(profile.width - 1, x + step - 1)
                    data.append(UInt8((samples[(y * profile.width + x) * 3 + component] + samples[(y * profile.width + right) * 3 + component] + 1) / 2))
                }
            }
        }
        try data.write(to: raw)
        if profile.htj2k {
            try Self.run(Self.ojphCompress, ["-i", raw.path, "-o", output.path, "-dims", "{\(profile.width),\(profile.height)}", "-num_comps", "3",
                                             "-downsamp", "{1,1},{2,1},{2,1}", "-bit_depth", "8,8,8", "-signed", "false,false,false"] + profile.options)
        } else {
            try Self.run(Self.opjCompress, ["-i", raw.path, "-o", output.path, "-F", "\(profile.width),\(profile.height),3,8,u@1x1:2x1:2x1"] + profile.options)
        }
        return try Data(contentsOf: output)
    }

    /// `opj_decompress` or `ojph_expand` (PPM out), optionally reduced or limited to some layers.
    private func reference(_ codestream: Data, _ profile: Profile, reduction: Int = 0, extra: [String] = []) throws
        -> (width: Int, height: Int, samples: [Int]) {
        let base = directory.appendingPathComponent("\(profile.name)-ref-\(UUID().uuidString.prefix(6))")
        let input = base.appendingPathExtension("j2c"), output = base.appendingPathExtension("ppm")
        try codestream.write(to: input)
        var arguments = ["-i", input.path, "-o", output.path] + extra
        if reduction > 0 { arguments += profile.htj2k ? ["-skip_res", "\(reduction),\(reduction)"] : ["-r", "\(reduction)"] }
        try Self.run(profile.htj2k ? Self.ojphExpand : Self.opjDecompress, arguments)
        let bytes = [UInt8](try Data(contentsOf: output))
        var cursor = 0
        func token() -> Int {
            while cursor < bytes.count, [0x20, 0x0A, 0x0D, 0x09, UInt8(ascii: "#")].contains(bytes[cursor]) {
                if bytes[cursor] == UInt8(ascii: "#") { while cursor < bytes.count, bytes[cursor] != 0x0A { cursor += 1 } } else { cursor += 1 }
            }
            let start = cursor
            while cursor < bytes.count, ![0x20, 0x0A, 0x0D, 0x09].contains(bytes[cursor]) { cursor += 1 }
            return Int(String(decoding: bytes[start..<cursor], as: UTF8.self)) ?? 0
        }
        cursor = 2
        let width = token(), height = token(), maximum = token()
        cursor += 1
        let count = width * height * 3
        let samples: [Int] = maximum > 255
            ? (0..<count).map { Int(bytes[cursor + $0 * 2]) << 8 | Int(bytes[cursor + $0 * 2 + 1]) }
            : (0..<count).map { Int(bytes[cursor + $0]) }
        return (width, height, samples)
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DicomJ2KIrreversibleColourTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(executable) failed: \(text.prefix(300))"])
        }
        return text
    }

    static func physicalFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func integers(_ data: Data, precision: Int) -> [Int] {
        let bytes = [UInt8](data)
        guard precision > 8 else { return bytes.map(Int.init) }
        return stride(from: 0, to: bytes.count - 1, by: 2).map { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 }
    }

    static func difference(_ candidate: [Int], _ reference: [Int]) -> (maximum: Int, rmse: Double)? {
        guard candidate.count == reference.count, !candidate.isEmpty else { return nil }
        var maximum = 0, sum = 0.0
        for (a, b) in zip(candidate, reference) { let d = abs(a - b); maximum = max(maximum, d); sum += Double(d * d) }
        return (maximum, (sum / Double(candidate.count)).squareRoot())
    }
}
