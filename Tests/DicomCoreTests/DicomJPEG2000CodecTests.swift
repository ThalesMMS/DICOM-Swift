import DicomCodecs
import DicomTestSupport
@testable import DicomJPEG2000
import Foundation
import XCTest
@testable import DicomCore

/// Own JPEG 2000 Part 1 codec on the vendored DicomJPEG2000 core (#2329): JP2/JPX/JPH containers separated from the
/// codestream (inspector, backend, validator, transcoder step), independent OpenJPEG-encoded inputs decoded exactly,
/// reduced-resolution decodes checked against `opj_decompress -r`, deterministic parallel decodes, and a release
/// timing comparison with the OpenJPEG runtime.
final class DicomJPEG2000CodecTests: XCTestCase {
    private static let opjCompress = DicomTestRuntimePreflight.executablePath(named: "opj_compress") ?? ""
    private static let opjDecompress = DicomTestRuntimePreflight.executablePath(named: "opj_decompress") ?? ""

    // MARK: - Fixtures

    private static func samples(width: Int, height: Int, precision: Int, components: Int, seed: UInt32 = 9) -> [UInt16] {
        var state = seed
        let limit = 1 << precision
        return (0..<(width * height * components)).map { index in
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Int(state >> 8) % max(1, limit / 8)
            let x = (index / components) % width, y = (index / components) / width
            return UInt16((x * limit / max(1, width) / 2 + y * limit / max(1, height) / 4 + noise + (index % components) * (limit / 16)) % limit)
        }
    }

    private static func littleEndian(_ samples: [UInt16], bitsAllocated: Int) -> Data {
        var data = Data(capacity: samples.count * (bitsAllocated > 8 ? 2 : 1))
        for value in samples {
            data.append(UInt8(value & 0xFF))
            if bitsAllocated > 8 { data.append(UInt8(value >> 8)) }
        }
        return data
    }

    private static func descriptor(_ syntax: DicomTransferSyntax = .jpeg2000Lossless, width: Int, height: Int, bitsStored: Int,
                                   samples: Int = 1, photometric: String? = nil, signed: Bool = false) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(transferSyntaxUID: syntax.rawValue, rows: height, columns: width, bitsAllocated: bitsStored > 8 ? 16 : 8,
                                       bitsStored: bitsStored, highBit: bitsStored - 1, pixelRepresentation: signed ? 1 : 0, samplesPerPixel: samples,
                                       photometricInterpretation: photometric ?? (samples == 3 ? "YBR_RCT" : "MONOCHROME2"),
                                       planarConfiguration: samples == 3 ? 0 : nil)
    }

    private static func encapsulatedFile(codestream: Data, syntax: DicomTransferSyntax, width: Int, height: Int, bitsStored: Int,
                                         samples: Int = 1, photometric: String = "MONOCHROME2", frames: [Data]? = nil) throws -> Data {
        let fragments = frames ?? [codestream]
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23290001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23290002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23290003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(samples)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([photometric])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([bitsStored > 8 ? 16 : 8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(bitsStored - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(try DicomTranscoder.encapsulate(fragments: fragments).pixelData))
        ]
        if fragments.count > 1 { elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(fragments.count)"]))) }
        if samples == 3 { elements.append(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0]))) }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements), options: .init(transferSyntax: syntax))
    }

    private static func ownCodestream(_ samples: [UInt16], descriptor: DicomCompressedFrameDescriptor) async throws -> Data {
        let frame = DicomCodecDecodedFrame(buffer: .owned(littleEndian(samples, bitsAllocated: descriptor.bitsAllocated)), width: descriptor.columns,
                                           height: descriptor.rows, bitsPerSample: descriptor.bitsStored, componentCount: descriptor.samplesPerPixel)
        return try await DicomJ2KSwiftBackend().encode(DicomFrameEncodeRequest(frame: frame, descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID))
    }

    /// A minimal JP2/JPX/JPH file around a codestream: signature box, `ftyp` with the brand, and the `jp2c` box.
    private static func wrap(_ codestream: Data, brand: String, extendedLength: Bool = false) -> Data {
        func box(_ type: String, _ payload: Data) -> Data {
            var out = Data()
            if extendedLength, type == "jp2c" {
                out.append(contentsOf: [0, 0, 0, 1]); out.append(Data(type.utf8))
                var length = UInt64(16 + payload.count).bigEndian
                out.append(Data(bytes: &length, count: 8))
            } else {
                var length = UInt32(8 + payload.count).bigEndian
                out.append(Data(bytes: &length, count: 4)); out.append(Data(type.utf8))
            }
            out.append(payload)
            return out
        }
        var file = Data([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A])
        file.append(box("ftyp", Data(brand.utf8) + Data([0, 0, 0, 0]) + Data(brand.utf8)))
        file.append(box("jp2h", Data([0, 0, 0, 0])))
        file.append(box("jp2c", codestream))
        return file
    }

    private static func opjAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: opjCompress) && FileManager.default.isExecutableFile(atPath: opjDecompress)
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func opjEncode(_ samples: [UInt16], width: Int, height: Int, precision: Int, components: Int, flags: [String], directory: URL, name: String) throws -> Data {
        // opj_compress reads little-endian planes from `.rawl`.
        var planar: [UInt16] = []
        planar.reserveCapacity(samples.count)
        for component in 0..<components { for pixel in 0..<(width * height) { planar.append(samples[pixel * components + component]) } }
        let raw = directory.appendingPathComponent("\(name).rawl")
        try littleEndian(planar, bitsAllocated: precision > 8 ? 16 : 8).write(to: raw)
        let out = directory.appendingPathComponent("\(name).j2k")
        let result = try run(opjCompress, ["-i", raw.path, "-o", out.path, "-F", "\(width),\(height),\(components),\(precision),u", "-n", "3"] + flags)
        // Small tiled fixtures need an explicit resolution count; a failed oracle is not unavailable.
        guard result.status == 0 else {
            throw NSError(domain: "OpenJPEGEncodeOracle", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "\(name): \(result.output)"])
        }
        return try Data(contentsOf: out)
    }

    private static func opjDecode(_ codestream: Data, width: Int, height: Int, precision: Int, components: Int, reduce: Int, directory: URL, name: String) throws -> [UInt16] {
        let input = directory.appendingPathComponent("\(name)-in.j2k")
        try codestream.write(to: input)
        let out = directory.appendingPathComponent("\(name)-r\(reduce).rawl")
        let result = try run(opjDecompress, ["-i", input.path, "-o", out.path] + (reduce > 0 ? ["-r", "\(reduce)"] : []))
        guard result.status == 0 else {
            throw NSError(domain: "OpenJPEGDecodeOracle", code: Int(result.status),
                          userInfo: [NSLocalizedDescriptionKey: "\(name): \(result.output)"])
        }
        let bytes = try Data(contentsOf: out)
        let planes: [UInt16] = precision > 8
            ? bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)).map { UInt16(littleEndian: $0) } }
            : bytes.map { UInt16($0) }
        let factor = 1 << reduce
        let outWidth = (width + factor - 1) / factor, outHeight = (height + factor - 1) / factor
        guard components == 3 else { return planes }
        var interleaved = [UInt16](repeating: 0, count: outWidth * outHeight * 3)
        for component in 0..<3 { for pixel in 0..<(outWidth * outHeight) { interleaved[pixel * 3 + component] = planes[component * outWidth * outHeight + pixel] } }
        return interleaved
    }

    // MARK: - Containers

    func test_containersAreUnwrappedByInspectorBackendValidatorAndTranscoderWithoutReencoding() async throws {
        let width = 23, height = 17
        let source = Self.samples(width: width, height: height, precision: 12, components: 1)
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 12)
        let codestream = try await Self.ownCodestream(source, descriptor: descriptor)
        XCTAssertNil(try DicomJ2KCodestreamInspector.inspect(codestream).container)
        for (brand, kind, extended) in [("jp2 ", DicomJ2KCodestreamInspector.Container.jp2, false), ("jpx ", .jpx, true), ("jph ", .jph, false)] {
            let wrapped = Self.wrap(codestream, brand: brand, extendedLength: extended)
            let unwrapped = try DicomJ2KCodestreamInspector.unwrap(wrapped)
            XCTAssertEqual(unwrapped.container, kind)
            XCTAssertEqual(unwrapped.codestream, codestream, "\(brand) codestream restored byte for byte")
            let inspection = try DicomJ2KCodestreamInspector.inspect(wrapped)
            XCTAssertEqual(inspection.container, kind)
            XCTAssertEqual(inspection.width, width)
            // The own backend decodes the wrapped frame to the same samples.
            let decoded = try await DicomJ2KSwiftBackend().decode(DicomFrameDecodeRequest(frameData: wrapped, descriptor: descriptor, frameIndex: 0))
            XCTAssertEqual(decoded.buffer.data, Self.littleEndian(source, bitsAllocated: 16), "\(brand) decode")
        }
        // Malformed wrappers fail typed.
        XCTAssertThrowsError(try DicomJ2KCodestreamInspector.unwrap(Self.wrap(codestream, brand: "jp2 ").prefix(40)))
        var truncatedBox = Self.wrap(codestream, brand: "jp2 ")
        truncatedBox[truncatedBox.count - 200] = 0xFF
        XCTAssertEqual(try DicomJ2KCodestreamInspector.unwrap(truncatedBox).container, .jp2, "payload corruption is the codestream's problem, not the box structure's")
        // The validator reports the wrapper as a profile mismatch; the transcoder separates it without re-encoding.
        let wrappedFile = try Self.encapsulatedFile(codestream: Self.wrap(codestream, brand: "jp2 "), syntax: .jpeg2000Lossless, width: width, height: height, bitsStored: 12)
        let validation = try DicomInstanceValidator.validate(wrappedFile)
        XCTAssertTrue(validation.diagnostics.contains { $0.code == DicomValidationReport.Code.codestreamProfileMismatch }, "\(validation.diagnostics.map { $0.code })")
        let transcoder = DicomTranscoder()
        let plan = try transcoder.plan(wrappedFile, to: .jpeg2000Lossless)
        XCTAssertEqual(plan.kind, .rewrap)
        XCTAssertTrue(plan.steps.contains(.unwrapContainers(frames: 1)), "\(plan.steps)")
        XCTAssertFalse(plan.steps.contains { if case .decodeFrames = $0 { return true }; return false }, "no re-encode")
        let execution = try await transcoder.execute(plan, source: wrappedFile)
        let output = try XCTUnwrap(execution.data)
        let decoder = try DCMDecoder(data: output)
        let reader = try DicomEncapsulatedPixelFrameReader(descriptor: try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor), fileData: output)
        let written = try reader.frame(at: 0).data
        XCTAssertEqual(written.prefix(codestream.count), codestream, "raw codestream written")
        XCTAssertLessThanOrEqual(written.count - codestream.count, 1, "at most the even-length padding byte follows")
        XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.23290001")
        XCTAssertTrue(try DicomInstanceValidator.validate(output).diagnostics.allSatisfy { $0.code != DicomValidationReport.Code.codestreamProfileMismatch })
        // Rewrapping to the superset syntax also unwraps; a raw source keeps the plain copy.
        XCTAssertTrue(try transcoder.plan(wrappedFile, to: .jpeg2000).steps.contains(.unwrapContainers(frames: 1)))
        let rawFile = try Self.encapsulatedFile(codestream: codestream, syntax: .jpeg2000Lossless, width: width, height: height, bitsStored: 12)
        XCTAssertEqual(try transcoder.plan(rawFile, to: .jpeg2000Lossless).steps, [.carryDataset, .copyEncapsulatedRegion(frames: 1)])
    }

    func test_laterWrappedFrameIsUnwrappedAfterARawFirstFrame() async throws {
        let width = 11, height = 7
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 8)
        let first = try await Self.ownCodestream(Self.samples(width: width, height: height, precision: 8, components: 1),
                                                descriptor: descriptor)
        let second = try await Self.ownCodestream(Self.samples(width: width, height: height, precision: 8, components: 1, seed: 11),
                                                 descriptor: descriptor)
        for brand in ["jp2 ", "jpx ", "jph "] {
            let source = try Self.encapsulatedFile(codestream: first, syntax: .jpeg2000Lossless,
                                                   width: width, height: height, bitsStored: 8,
                                                   frames: [first, Self.wrap(second, brand: brand)])
            for destination: DicomTransferSyntax in [.jpeg2000Lossless, .jpeg2000] {
                let transcoder = DicomTranscoder()
                let plan = try transcoder.plan(source, to: destination)
                XCTAssertTrue(plan.steps.contains(.unwrapContainers(frames: 2)))
                let result = try await transcoder.execute(plan, source: source)
                let data = try XCTUnwrap(result.data)
                let decoder = try DCMDecoder(data: data)
                let reader = try DicomEncapsulatedPixelFrameReader(
                    descriptor: try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor), fileData: data)
                for (index, expected) in [first, second].enumerated() {
                    let written = try reader.frame(at: index).data
                    XCTAssertNil(try DicomJ2KCodestreamInspector.unwrap(written).container)
                    XCTAssertEqual(written.prefix(expected.count), expected)
                    XCTAssertLessThanOrEqual(written.count - expected.count, 1)
                }
            }
        }
    }

    func test_planning_rejectsMalformedLaterContainersWithTheFrameIndex() async throws {
        let width = 11, height = 7
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 8)
        let raw = try await Self.ownCodestream(Self.samples(width: width, height: height, precision: 8, components: 1),
                                              descriptor: descriptor)
        for brand in ["jp2 ", "jpx ", "jph "] {
            let wrapped = Self.wrap(raw, brand: brand)
            let malformed = Data(wrapped.prefix(40))
            XCTAssertThrowsError(try DicomJ2KCodestreamInspector.unwrap(malformed))
            for frames in [[raw, malformed], [wrapped, malformed], [raw, wrapped, malformed]] {
                let source = try Self.encapsulatedFile(codestream: raw, syntax: .jpeg2000Lossless,
                                                       width: width, height: height, bitsStored: 8, frames: frames)
                for destination: DicomTransferSyntax in [.jpeg2000Lossless, .jpeg2000] {
                    XCTAssertThrowsError(try DicomTranscoder().plan(source, to: destination)) { error in
                        guard let error = error as? DicomTranscoder.ExecutionError,
                              case .codestreamContainerNotAllowed(let index, let detail) = error else {
                            return XCTFail("Expected indexed container rejection, got \(error)")
                        }
                        XCTAssertEqual(index, frames.count - 1)
                        XCTAssertFalse(detail.isEmpty)
                    }
                }
            }
        }
    }

    // MARK: - Independent inputs

    func test_openJPEGEncodedInputsDecodeExactlyAcrossTilesPrecinctsProgressionsAndReductions() async throws {
        guard Self.opjAvailable() else { throw XCTSkip("OpenJPEG CLI tools are unavailable in PATH and standard install locations") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("j2k-opj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 71, height = 45
        let cases: [(name: String, precision: Int, components: Int, flags: [String])] = [
            ("gray8", 8, 1, []),
            ("gray12-tiles", 12, 1, ["-t", "32,32"]),
            ("gray16-precincts", 16, 1, ["-c", "[32,32],[16,16]", "-b", "16,16", "-p", "RPCL", "-SOP", "-EPH"]),
            ("gray12-cprl", 12, 1, ["-p", "CPRL", "-n", "4"]),
            ("gray12-pcrl-tileparts", 12, 1, ["-p", "PCRL", "-t", "40,24", "-TP", "R", "-n", "4"]),
            ("rgb8-mct", 8, 3, ["-mct", "1", "-p", "RLCP"]),
        ]
        let backend = DicomJ2KSwiftBackend()
        for testCase in cases {
            let source = Self.samples(width: width, height: height, precision: testCase.precision, components: testCase.components, seed: 3)
            let codestream = try Self.opjEncode(source, width: width, height: height, precision: testCase.precision, components: testCase.components,
                                                flags: testCase.flags, directory: directory, name: testCase.name)
            let inspection = try DicomJ2KCodestreamInspector.inspect(codestream)
            XCTAssertNil(inspection.container)
            let descriptor = Self.descriptor(width: width, height: height, bitsStored: testCase.precision, samples: testCase.components,
                                             photometric: testCase.components == 3 ? "YBR_RCT" : "MONOCHROME2")
            let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
            XCTAssertEqual(decoded.buffer.data, Self.littleEndian(source, bitsAllocated: testCase.precision > 8 ? 16 : 8), "\(testCase.name): exact against the source")
            // Reduced decodes match opj_decompress -r geometry and samples.
            for reduce in 1...min(2, inspection.decompositionLevels) {
                let reference = try Self.opjDecode(codestream, width: width, height: height, precision: testCase.precision, components: testCase.components,
                                                   reduce: reduce, directory: directory, name: testCase.name)
                let reduced = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0,
                                                                                partialRequest: DicomPartialDecodeRequest(resolutionLevel: inspection.decompositionLevels - reduce)))
                let factor = 1 << reduce
                XCTAssertEqual(reduced.width, (width + factor - 1) / factor)
                XCTAssertEqual(reduced.height, (height + factor - 1) / factor)
                XCTAssertEqual(reduced.buffer.data, Self.littleEndian(reference, bitsAllocated: testCase.precision > 8 ? 16 : 8), "\(testCase.name) reduce \(reduce)")
            }
        }
    }

    /// Every code-block style bit OpenJPEG writes (`-M`: 1 BYPASS, 2 RESET, 4 RESTART, 8 VSC, 16 ERTERM/PTERM,
    /// 32 SEGMARK, 37 = BYPASS+RESTART+SEGMARK), in 8 and 16 bits, single and multi-layer, decodes exactly (#2898).
    func test_openJPEGCodeBlockStylesDecodeExactlyAcrossDepthsAndLayers() async throws {
        guard Self.opjAvailable() else { throw XCTSkip("OpenJPEG CLI tools are unavailable in PATH and standard install locations") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("j2k-modes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 97, height = 70
        let backend = DicomJ2KSwiftBackend()
        for precision in [8, 16] {
            let source = Self.samples(width: width, height: height, precision: precision, components: 1, seed: 5)
            let expected = Self.littleEndian(source, bitsAllocated: precision > 8 ? 16 : 8)
            let descriptor = Self.descriptor(width: width, height: height, bitsStored: precision)
            for mode in [1, 2, 4, 8, 16, 32, 37, 63] {
                for layers in [[String](), ["-r", "40,10,1"]] {
                    let name = "m\(mode)-p\(precision)-l\(layers.isEmpty ? 1 : 3)"
                    let codestream = try Self.opjEncode(source, width: width, height: height, precision: precision, components: 1,
                                                        flags: ["-M", "\(mode)", "-b", "16,16"] + layers, directory: directory, name: name)
                    XCTAssertEqual(try Self.opjDecode(codestream, width: width, height: height, precision: precision, components: 1,
                                                      reduce: 0, directory: directory, name: name), source, "\(name): OpenJPEG oracle")
                    let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
                    XCTAssertEqual(decoded.buffer.data, expected, "\(name): exact against the source and OpenJPEG")
                }
            }
        }
    }

    /// Inverted or truncated EBCOT entropy bytes become an error, not an image (#2899); the valid stream still decodes.
    func test_corruptedEntropyData_isRefusedInsteadOfDecoded() async throws {
        guard Self.opjAvailable() else { throw XCTSkip("OpenJPEG CLI tools are unavailable in PATH and standard install locations") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("j2k-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 96, height = 80
        let source = Self.samples(width: width, height: height, precision: 16, components: 1, seed: 29)
        let codestream = try Self.opjEncode(source, width: width, height: height, precision: 16, components: 1,
                                            flags: [], directory: directory, name: "corrupt")
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 16)
        let backend = DicomJ2KSwiftBackend()
        let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
        XCTAssertEqual(decoded.buffer.data, Self.littleEndian(source, bitsAllocated: 16))
        let bytes = [UInt8](codestream)
        XCTAssertEqual(Array(bytes.suffix(2)), [0xFF, 0xD9])
        let withoutEOC = try await backend.decode(DicomFrameDecodeRequest(
            frameData: Data(bytes.dropLast(2)), descriptor: descriptor, frameIndex: 0))
        XCTAssertEqual(withoutEOC.buffer.data, decoded.buffer.data, "a codestream without EOC is not corruption")
        let body = try XCTUnwrap((0..<(bytes.count - 1)).first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0x93 }) + 2
        let end = bytes.count - 2
        var entropyRefusals = 0
        for fraction in [0.35, 0.5, 0.65, 0.8] {
            var inverted = bytes
            let start = body + Int(Double(end - body) * fraction)
            for index in start..<min(end, start + 24) { inverted[index] ^= 0xFF }
            do {
                let image = try await backend.decode(DicomFrameDecodeRequest(frameData: Data(inverted), descriptor: descriptor, frameIndex: 0))
                XCTFail("inverted bytes at \(fraction) decoded to \(image.buffer.data.count) bytes")
            } catch J2KError.corruptedEntropyData {
                entropyRefusals += 1
            } catch {}
        }
        XCTAssertGreaterThan(entropyRefusals, 0, "the entropy accounting, not only the packet parser, refuses")
        let truncated = Data(bytes[..<(body + (end - body) * 3 / 4)] + [0xFF, 0xD9])
        do {
            _ = try await backend.decode(DicomFrameDecodeRequest(frameData: truncated, descriptor: descriptor, frameIndex: 0))
            XCTFail("a truncated codestream decoded")
        } catch {}
    }

    /// The decoder writes 16-bit samples in the requested byte order and tags them, so the DICOM backend needs no swap
    /// pass (#2902); the power-of-two downscale reads and writes in the component's order.
    func test_sampleByteOrder_isWrittenAndTaggedAsRequested() async throws {
        let width = 72, height = 40
        let source = Self.samples(width: width, height: height, precision: 16, components: 1, seed: 31)
        for signed in [false, true] {
            let codestream = try await Self.ownCodestream(
                source, descriptor: Self.descriptor(width: width, height: height, bitsStored: 16, signed: signed))
            let bigImage = try await J2KDecoder().decode(codestream)
            let littleImage = try await J2KDecoder(sampleByteOrder: .littleEndian).decode(codestream)
            let big = try XCTUnwrap(bigImage.components.first)
            let little = try XCTUnwrap(littleImage.components.first)
            XCTAssertEqual(big.sampleByteOrder, .bigEndian)
            XCTAssertEqual(little.sampleByteOrder, .littleEndian)
            XCTAssertEqual(little.data, Self.littleEndian(source, bitsAllocated: 16), "signed \(signed)")
            var swapped = big.data
            for index in stride(from: 0, to: swapped.count, by: 2) { swapped.swapAt(index, index + 1) }
            XCTAssertEqual(swapped, little.data, "signed \(signed)")

            let image = J2KImage(width: width, height: height, components: [little])
            let halved = try XCTUnwrap(try J2KDecoder.downscaleByPowerOf2(
                image: image, targetWidth: width / 2, targetHeight: height / 2, factor: 2).components.first)
            XCTAssertEqual(halved.sampleByteOrder, .littleEndian)
            let expected = (0..<(width / 2 * height / 2)).map { index -> UInt16 in
                let x = index % (width / 2) * 2, y = index / (width / 2) * 2
                let sum = [(0, 0), (1, 0), (0, 1), (1, 1)].reduce(0) { $0 + Int(source[(y + $1.1) * width + x + $1.0]) }
                return UInt16(sum / 4)
            }
            XCTAssertEqual(halved.data, Self.littleEndian(expected, bitsAllocated: 16), "signed \(signed)")
        }
    }

    /// A nominal tile larger than the image is clipped to the reference grid (T.800 Eq. B-7), also with non-zero image
    /// and tile offsets (#2900).
    func test_nominalTileLargerThanImage_decodesLikeOpenJPEG() async throws {
        guard Self.opjAvailable() else { throw XCTSkip("OpenJPEG CLI tools are unavailable in PATH and standard install locations") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("j2k-tile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 64, height = 48
        let backend = DicomJ2KSwiftBackend()
        for (name, flags) in [("tile128", ["-t", "128,128"]),
                              ("tile128-offsets", ["-t", "128,128", "-d", "7,5", "-T", "3,2"]),
                              ("tile40-offsets", ["-t", "40,40", "-d", "7,5", "-T", "3,2"])] {
            let source = Self.samples(width: width, height: height, precision: 12, components: 1, seed: 21)
            let codestream = try Self.opjEncode(source, width: width, height: height, precision: 12, components: 1,
                                                flags: flags, directory: directory, name: name)
            let reference = try Self.opjDecode(codestream, width: width, height: height, precision: 12, components: 1,
                                               reduce: 0, directory: directory, name: name)
            XCTAssertEqual(reference, source, "\(name): OpenJPEG oracle")
            let decoded = try await backend.decode(DicomFrameDecodeRequest(
                frameData: codestream, descriptor: Self.descriptor(width: width, height: height, bitsStored: 12), frameIndex: 0))
            XCTAssertEqual(decoded.buffer.data, Self.littleEndian(reference, bitsAllocated: 16), name)
        }
    }

    /// A SIZ that disagrees with the dataset, or whose sample count would overflow, is refused typed before the
    /// decoder allocates (#2901).
    func test_incoherentSIZ_isRefusedBeforeDecoding() async throws {
        let width = 23, height = 17
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 12)
        let codestream = try await Self.ownCodestream(Self.samples(width: width, height: height, precision: 12, components: 1),
                                                      descriptor: descriptor)
        func patched(_ values: [(offset: Int, value: UInt32)]) -> Data {
            var data = codestream
            for (offset, value) in values {
                for byte in 0..<4 { data[data.startIndex + offset + byte] = UInt8(truncatingIfNeeded: value >> (24 - 8 * byte)) }
            }
            return data
        }
        let backend = DicomJ2KSwiftBackend()
        func error(_ frame: Data, _ descriptor: DicomCompressedFrameDescriptor, partial: Bool = false) async -> Error? {
            let request = DicomFrameDecodeRequest(frameData: frame, descriptor: descriptor, frameIndex: 0,
                                                  partialRequest: partial ? DicomPartialDecodeRequest(resolutionLevel: 0) : nil)
            do { _ = try await backend.decode(request); return nil } catch { return error }
        }
        // Xsiz (offset 8) that differs from Columns, with its one tile (XTsiz, offset 24) widened alike.
        let wider = await error(patched([(8, UInt32(width + 1)), (24, UInt32(width + 1))]), descriptor)
        guard case .metadataMismatch(_, let reason)? = wider as? DicomJ2KSwiftBackendError else { return XCTFail("\(String(describing: wider))") }
        XCTAssertTrue(reason.contains("SIZ declares 24x17"), reason)
        // 2^32 − 1 square with one tile: a mismatch for a full decode, a typed size refusal (no trap) otherwise.
        let huge = patched([(8, .max), (12, .max), (24, .max), (28, .max)])
        guard case .metadataMismatch? = await error(huge, descriptor) as? DicomJ2KSwiftBackendError else { return XCTFail() }
        guard case .unsupportedShape(_, let sizeReason)? = await error(huge, descriptor, partial: true) as? DicomJ2KSwiftBackendError
        else { return XCTFail() }
        XCTAssertTrue(sizeReason.contains("samples"), sizeReason)
        // A dataset that really declares 65535 × 65535 agrees with its SIZ and is still over the sample budget.
        let maximal = patched([(8, 65_535), (12, 65_535), (24, 65_535), (28, 65_535)])
        let maximalDescriptor = Self.descriptor(width: 65_535, height: 65_535, bitsStored: 12)
        guard case .unsupportedShape? = await error(maximal, maximalDescriptor) as? DicomJ2KSwiftBackendError else { return XCTFail() }
        // The untouched codestream still decodes.
        let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
        XCTAssertEqual(decoded.width, width)
    }

    // MARK: - Deterministic parallel decode

    func test_parallelCodeBlockDecodeIsDeterministicAndHonoursCancellation() async throws {
        let width = 257, height = 131
        let source = Self.samples(width: width, height: height, precision: 16, components: 1, seed: 17)
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 16)
        let codestream = try await Self.ownCodestream(source, descriptor: descriptor)
        let backend = DicomJ2KSwiftBackend()
        var outputs: Set<Data> = []
        for _ in 0..<6 {
            outputs.insert(try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0)).buffer.data)
        }
        XCTAssertEqual(outputs.count, 1, "code-block buckets are indexed deterministically")
        XCTAssertEqual(outputs.first, Self.littleEndian(source, bitsAllocated: 16))
        let task = Task { try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0)) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled decode must throw CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("cancellation surfaced as \(error)")
        }
    }

    // MARK: - Release timing

    func test_releaseTimingOfTheOwnCodecAgainstOpenJPEG() async throws {
        #if DEBUG
        throw XCTSkip("JPEG 2000 timing is measured in Release only (swift test -c release -Xswiftc -enable-testing).")
        #else
        let width = 512, height = 512
        let source = Self.samples(width: width, height: height, precision: 16, components: 1, seed: 41)
        let descriptor = Self.descriptor(width: width, height: height, bitsStored: 16)
        let codestream = try await Self.ownCodestream(source, descriptor: descriptor)
        let backend = DicomJ2KSwiftBackend()
        _ = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
        var start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<10 { _ = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0)) }
        let ownDecode = Double(DispatchTime.now().uptimeNanoseconds - start) / 10 / 1_000_000
        start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 { _ = try await Self.ownCodestream(source, descriptor: descriptor) }
        let ownEncode = Double(DispatchTime.now().uptimeNanoseconds - start) / 5 / 1_000_000
        var openJPEGDecode = Double.nan
        if DicomJPEG2000Codec.isAvailable {
            _ = try DicomJPEG2000Codec.decode(codestream)
            start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<10 { _ = try DicomJPEG2000Codec.decode(codestream) }
            openJPEGDecode = Double(DispatchTime.now().uptimeNanoseconds - start) / 10 / 1_000_000
        }
        print("JPEG2000-BENCH 512x512 gray16 5/3 lossless: own decode \(String(format: "%.2f", ownDecode)) ms, OpenJPEG decode \(String(format: "%.2f", openJPEGDecode)) ms, own encode \(String(format: "%.2f", ownEncode)) ms, codestream \(codestream.count) bytes")
        if let corpus = ProcessInfo.processInfo.environment["DICOM_J2K_TIMING_CORPUS"] {
            // Local corpus (paths only; no pixel or identity is printed): first eight .91/.90 frames, own vs OpenJPEG.
            let files = try FileManager.default.contentsOfDirectory(atPath: corpus).sorted().prefix(64).map { URL(fileURLWithPath: corpus).appendingPathComponent($0) }
            var measured = 0
            for url in files where measured < 8 {
                guard let data = try? Data(contentsOf: url), let decoder = try? DCMDecoder(data: data),
                      let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID), [.jpeg2000, .jpeg2000Lossless].contains(syntax) else { continue }
                let own = DicomDecodedFrameReader(decoder: decoder)
                let ownStart = DispatchTime.now().uptimeNanoseconds
                _ = try await own.frameExecution(at: 0, environment: ["DICOM_J2KSWIFT_MODE": "forced-for-tests"])
                let ownMs = Double(DispatchTime.now().uptimeNanoseconds - ownStart) / 1_000_000
                let legacyStart = DispatchTime.now().uptimeNanoseconds
                _ = try? await DicomDecodedFrameReader(decoder: try DCMDecoder(data: data)).frameExecution(at: 0, environment: ["DICOM_J2KSWIFT_MODE": "disabled"])
                let legacyMs = Double(DispatchTime.now().uptimeNanoseconds - legacyStart) / 1_000_000
                print("JPEG2000-CORPUS \(decoder.width)x\(decoder.height) \(decoder.bitDepth)-bit \(syntax.rawValue): own \(String(format: "%.2f", ownMs)) ms, established \(String(format: "%.2f", legacyMs)) ms")
                measured += 1
            }
        }
        #endif
    }

    // MARK: - Vendored codec regressions

    func test_adsMarker_nonzeroDataIndexRoundTripsAndTruncationThrows() throws {
        let marker = J2KADSMarker(index: 0, decompositionOrder: .mallat,
                                  nodes: [.init(horizontalDecompose: true, verticalDecompose: true, kernelIndex: 0)],
                                  maxLevels: 1)
        let wrapped = Data([0, 0, 0]) + marker.encode()
        XCTAssertEqual(try J2KADSMarker.decode(from: wrapped[3...]), marker)
        XCTAssertThrowsError(try J2KADSMarker.decode(from: wrapped[3..<wrapped.count - 1]))
    }

    func test_adaptiveBlockSize_explicitByteOrdersProduceEqualMetrics() {
        let values = (0..<64).map { UInt16(($0 * 997) % 65536) }
        func image(bigEndian: Bool, tiled: Bool) -> J2KImage {
            let data = Data(values.flatMap { value in
                bigEndian ? [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)] :
                    [UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]
            })
            return J2KImage(width: 8, height: 8,
                            components: [.init(index: 0, bitDepth: 16, width: 8, height: 8, data: data,
                                               sampleByteOrder: bigEndian ? .bigEndian : .littleEndian)],
                            tileWidth: tiled ? 4 : 0, tileHeight: tiled ? 4 : 0)
        }
        let selector = J2KAdaptiveBlockSizeSelector()
        for tiled in [false, true] {
            for tile in 0..<(tiled ? 4 : 1) {
                XCTAssertEqual(selector.analyzeTile(from: image(bigEndian: true, tiled: tiled), tileIndex: tile),
                               selector.analyzeTile(from: image(bigEndian: false, tiled: tiled), tileIndex: tile))
            }
        }
    }

    func test_inverse53_invalidBandOrientationThrowsAndSingletonSurvives() throws {
        let transform = J2KDWT1DOptimizer()
        for boundary: J2KDWT1D.BoundaryExtension in [.symmetric, .periodic] {
            XCTAssertThrowsError(try transform.inverseTransform53Optimized(
                lowpass: [1], highpass: [1, 2], boundaryExtension: boundary))
        }
        XCTAssertEqual(try transform.inverseTransform53Optimized(
            lowpass: [5], highpass: [], boundaryExtension: .symmetric), [5])
    }

    func test_inverse53_oddOriginRejectsInvalidBandsAndPreservesValidSignals() throws {
        let transform = J2KDWT1DOptimizer()
        for (low, high) in [(2, 1), (1, 3), (1, 0), (0, 2), (0, 0)] {
            XCTAssertThrowsError(try transform.inverseTransform53Optimized(
                lowpass: Array(repeating: 0, count: low), highpass: Array(repeating: 0, count: high),
                boundaryExtension: .symmetric, uOrigin: 1))
        }
        XCTAssertThrowsError(try transform.inverseTransform53Optimized(
            lowpass: [1, 2], highpass: [], boundaryExtension: .symmetric))
        XCTAssertEqual(try transform.inverseTransform53Optimized(
            lowpass: [], highpass: [10], boundaryExtension: .symmetric, uOrigin: 1), [5])
        XCTAssertEqual(try transform.inverseTransform53Optimized(
            lowpass: [3], highpass: [2], boundaryExtension: .symmetric, uOrigin: 1), [4, 2])
        XCTAssertEqual(try transform.inverseTransform53Optimized(
            lowpass: [3], highpass: [2, 4], boundaryExtension: .symmetric, uOrigin: 1), [3, 1, 5])
    }

    func test_encodingConfiguration_codestreamChangesCompareUnequal() {
        let original = J2KEncodingConfiguration()
        let changes: [(inout J2KEncodingConfiguration) -> Void] = [
            { $0.useHTJ2K.toggle() }, { $0.useReversibleFilter.toggle() }, { $0.writeTLMMarker.toggle() },
            { $0.enableParallelCodeBlocks.toggle() }, { $0.enableFastMEL.toggle() },
            { $0.enableVLCOptimization.toggle() }, { $0.enableMagSgnPacking.toggle() },
            { $0.mctConfiguration = .init(preferReversible: true) },
            { $0.blockSizeMode = .adaptive(aggressiveness: .balanced) },
            { $0.tileBlockSizeOverrides = [0: (32, 32)] }
        ]
        for change in changes {
            var modified = original
            change(&modified)
            XCTAssertNotEqual(original, modified)
            XCTAssertEqual(modified, modified)
        }
    }

    func test_mctConfiguration_matricesAndDependencyWeightsParticipateInEquality() throws {
        let identity = try J2KMCTMatrix(size: 2, coefficients: [1, 0, 0, 1], precision: .integer)
        let other = try J2KMCTMatrix(size: 2, coefficients: [1, 1, 0, 1], precision: .integer)
        XCTAssertNotEqual(J2KMCTEncodingConfiguration(mode: .arrayBased(identity)),
                          J2KMCTEncodingConfiguration(mode: .arrayBased(other)))
        XCTAssertNotEqual(J2KMCTEncodingConfiguration(perTileMCT: [0: identity]),
                          J2KMCTEncodingConfiguration(perTileMCT: [0: other]))
        let chain = try J2KDependencyChain(componentCount: 2, dependencies: [
            .init(outputComponent: 1, dependencies: [(0, 0.5)])
        ])
        let otherChain = try J2KDependencyChain(componentCount: 2, dependencies: [
            .init(outputComponent: 1, dependencies: [(0, 1.0)])
        ])
        let configuration = J2KMCTEncodingConfiguration(mode: .dependency(.init(transform: .chain(chain))))
        XCTAssertEqual(configuration, configuration)
        XCTAssertNotEqual(configuration, .init(mode: .dependency(.init(transform: .chain(otherChain)))))
    }

    func test_tilePlanner_smallImagesAreCoveredByPositiveInBoundsTiles() {
        for width in 1...7 {
            for height in 1...7 {
                for mode: J2KHTTileMode in [.single, .tiles2x2, .tiles4x4, .strips4, .auto] {
                    let layout = J2KEncodeTilePlanner.plan(imageWidth: width, imageHeight: height,
                                                          decompositionLevels: 0, mode: mode)
                    var area = 0
                    for tile in 0..<layout.tileCount {
                        let rect = layout.rect(forTile: tile)
                        XCTAssertGreaterThan(rect.w, 0)
                        XCTAssertGreaterThan(rect.h, 0)
                        XCTAssertLessThanOrEqual(rect.x + rect.w, width)
                        XCTAssertLessThanOrEqual(rect.y + rect.h, height)
                        area += rect.w * rect.h
                    }
                    XCTAssertEqual(area, width * height)
                }
            }
        }
    }

    func test_roi_largerCoefficientGridScalesOnlyMaskOverlap() {
        let processor = J2KExtendedROIProcessor(imageWidth: 4, imageHeight: 4, regions: [
            .init(baseRegion: .rectangle(x: 0, y: 0, width: 4, height: 4), scalingFactor: 2)
        ])
        let coefficients: [[Int32]] = [[1, 1, 1], [1, 1, 1], [1, 1, 1]]
        let expected: [[Int32]] = [[2, 2, 1], [2, 2, 1], [1, 1, 1]]
        XCTAssertEqual(processor.applyScalingBasedROI(coefficients: coefficients, subband: .ll,
                                                      decompositionLevel: 0, totalLevels: 1), expected)
        XCTAssertEqual(processor.applyBitplaneROI(coefficients: coefficients, bitplane: 0, subband: .ll,
                                                 decompositionLevel: 0, totalLevels: 1), expected)
    }

    func test_part2Transform_mismatchedDepthsThrowsBeforeMutatingComponents() {
        var components: [[Double]] = [[1], [2]]
        XCTAssertThrowsError(try J2KPart2ComponentTransforms().applyInverse(
            to: &components, codedDepths: [(8, false)]))
        XCTAssertEqual(components, [[1], [2]])
    }

    func test_qualityMetrics_twoByteSamplesRequireResolvedByteOrder() {
        let metrics = J2KQualityMetrics()
        for depth in [9, 12, 16] {
            let image = J2KImage(width: 4, height: 4, components: [
                .init(index: 0, bitDepth: depth, width: 4, height: 4, data: Data(repeating: 1, count: 32))
            ])
            XCTAssertThrowsError(try metrics.psnr(original: image, compressed: image))
            XCTAssertThrowsError(try metrics.ssim(original: image, compressed: image))
            XCTAssertThrowsError(try metrics.msssim(original: image, compressed: image, scales: 3))
        }
    }

    func test_qualityMetrics_MSSSIMAppliesLuminanceOnlyAtTheFinalScale() throws {
        func image(_ value: UInt8) -> J2KImage {
            J2KImage(width: 32, height: 32, components: [
                .init(index: 0, bitDepth: 8, width: 32, height: 32, data: Data(repeating: value, count: 1024))
            ])
        }
        let original = image(64), changed = image(128)
        let metrics = J2KQualityMetrics()
        // Wang et al. (2003), Eq. 7: constant planes have c_j = s_j = 1 at every scale.
        let c1 = 0.01 * 0.01 * 255 * 255
        let luminance = (2.0 * 64 * 128 + c1) / (64 * 64 + 128 * 128 + c1)
        XCTAssertEqual(try metrics.ssim(original: original, compressed: changed).value, luminance, accuracy: 0.000001)
        for (scales, finalWeight) in [(3, 0.3001), (5, 0.1333)] {
            XCTAssertEqual(try metrics.msssim(original: original, compressed: changed, scales: scales).value,
                           pow(luminance, finalWeight), accuracy: 0.000001)
        }
    }

    func test_qualityMetrics_subsampledComponentsUseTheirOwnGeometry() throws {
        func image(chromaWidth: Int = 8, chromaHeight: Int = 8) -> J2KImage {
            J2KImage(width: 16, height: 16, components: [
                .init(index: 0, bitDepth: 8, width: 16, height: 16, data: Data(repeating: 64, count: 256)),
                .init(index: 1, bitDepth: 8, width: chromaWidth, height: chromaHeight,
                      subsamplingX: 16 / chromaWidth, subsamplingY: 16 / chromaHeight,
                      data: Data(repeating: 128, count: chromaWidth * chromaHeight))
            ])
        }
        let metrics = J2KQualityMetrics()
        let original = image()
        XCTAssertEqual(try metrics.psnr(original: original, compressed: original).value, .infinity)
        XCTAssertEqual(try metrics.ssim(original: original, compressed: original).value, 1, accuracy: 0.000001)
        XCTAssertEqual(try metrics.msssim(original: original, compressed: original, scales: 3).value, 1, accuracy: 0.000001)
        let differentShape = image(chromaWidth: 16, chromaHeight: 4)
        XCTAssertThrowsError(try metrics.psnr(original: original, compressed: differentShape))
        XCTAssertThrowsError(try metrics.ssim(original: original, compressed: differentShape))
        XCTAssertThrowsError(try metrics.msssim(original: original, compressed: differentShape, scales: 3))
    }

    func test_qualityMetrics_rawSamplesHonorDepthSignednessAndByteOrder() throws {
        let side = 8
        let metrics = J2KQualityMetrics()
        for depth in [8, 12, 16, 32, 38] {
            for signed in [false, true] {
                let samples = (0..<side * side).map { Int64($0.isMultiple(of: 2) ? (signed ? -2 : 1) : 2) }
                func image(_ values: [Int64], order: J2KComponent.ByteOrder) -> J2KImage {
                    let byteCount = (depth + 7) / 8
                    var data = Data()
                    for value in values {
                        let raw = UInt64(bitPattern: value)
                        for byte in 0..<byteCount {
                            let shift = (order == .littleEndian ? byte : byteCount - byte - 1) * 8
                            data.append(UInt8(truncatingIfNeeded: raw >> shift))
                        }
                    }
                    return J2KImage(width: side, height: side, components: [
                        .init(index: 0, bitDepth: depth, signed: signed, width: side, height: side,
                              data: data, sampleByteOrder: order)
                    ])
                }
                let original = image(samples, order: .littleEndian)
                let equivalent = image(samples, order: .bigEndian)
                XCTAssertEqual(try metrics.psnr(original: original, compressed: equivalent).value, .infinity)
                XCTAssertEqual(try metrics.ssim(original: original, compressed: equivalent).value, 1, accuracy: 0.000001)
                XCTAssertEqual(try metrics.msssim(original: original, compressed: equivalent, scales: 3).value,
                               1, accuracy: 0.000001)
                var changed = samples
                changed[changed.count - 1] += 1
                let peak = Double((1 << depth) - 1)
                for order: J2KComponent.ByteOrder in [.littleEndian, .bigEndian] {
                    let measured = try metrics.psnr(original: original, compressed: image(changed, order: order)).value
                    XCTAssertEqual(measured, 10 * log10(peak * peak * Double(samples.count)), accuracy: 0.000001)
                }
            }
        }
    }

    func test_qualityMetrics_anticorrelatedImagesHaveFiniteBoundedMSSSIM() throws {
        let samples = (0..<64).map { UInt8($0.isMultiple(of: 2) ? 0 : 255) }
        func image(_ values: [UInt8]) -> J2KImage {
            J2KImage(width: 8, height: 8, components: [
                .init(index: 0, bitDepth: 8, width: 8, height: 8, data: Data(values))
            ])
        }
        let original = image(samples), inverted = image(samples.map { 255 - $0 })
        let metrics = J2KQualityMetrics()
        XCTAssertLessThan(try metrics.ssim(original: original, compressed: inverted).value, 0)
        for scales in 1...3 {
            let value = try metrics.msssim(original: original, compressed: inverted, scales: scales).value
            XCTAssertTrue(value.isFinite)
            XCTAssertTrue((0...1).contains(value))
        }
    }

    func test_qualityMetrics_identicalSmallImagesHavePerfectSimilarity() throws {
        let metrics = J2KQualityMetrics()
        for side in [4, 8, 16] {
            let data = Data((0..<side * side).map { UInt8(truncatingIfNeeded: $0 * 7) })
            let image = J2KImage(width: side, height: side, components: [
                .init(index: 0, bitDepth: 8, width: side, height: side, data: data)
            ])
            XCTAssertEqual(try metrics.ssim(original: image, compressed: image).value, 1, accuracy: 0.000001)
            XCTAssertEqual(try metrics.msssim(original: image, compressed: image, scales: 3).value,
                           1, accuracy: 0.000001)
        }
    }

    func test_qualityMetrics_trailingRowAndColumnAffectSimilarity() throws {
        let side = 9
        let source = [UInt8](repeating: 100, count: side * side)
        func image(_ samples: [UInt8]) -> J2KImage {
            J2KImage(width: side, height: side, components: [
                .init(index: 0, bitDepth: 8, width: side, height: side, data: Data(samples))
            ])
        }
        for trailingRow in [true, false] {
            var changed = source
            for offset in 0..<side {
                changed[trailingRow ? (side - 1) * side + offset : offset * side + side - 1] = 200
            }
            XCTAssertLessThan(try J2KQualityMetrics().ssim(original: image(source), compressed: image(changed)).value,
                              0.99, "A difference in the trailing \(trailingRow ? "row" : "column") must be measured")
        }
    }

    func test_tier2Timings_disabledRecordsAreIgnoredAndEnabledRecordsAccumulate() {
        let wasEnabled = J2KTier2Timings.isEnabled
        defer { J2KTier2Timings.isEnabled = wasEnabled; J2KTier2Timings.reset() }
        J2KTier2Timings.reset()
        J2KTier2Timings.isEnabled = false
        J2KTier2Timings.recordWritePacketCall(includedBlocks: 3)
        J2KTier2Timings.recordTagTreeBuild(1)
        XCTAssertEqual(J2KTier2Timings.snapshot().writePacketCount, 0)
        XCTAssertEqual(J2KTier2Timings.snapshot().total, 0)
        J2KTier2Timings.isEnabled = true
        J2KTier2Timings.recordWritePacketCall(includedBlocks: 3)
        J2KTier2Timings.recordTagTreeBuild(1)
        XCTAssertEqual(J2KTier2Timings.snapshot().writePacketCount, 1)
        XCTAssertEqual(J2KTier2Timings.snapshot().includedBlockCount, 3)
        XCTAssertEqual(J2KTier2Timings.snapshot().total, 1)
    }
}
