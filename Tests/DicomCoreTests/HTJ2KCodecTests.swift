import DicomCodecs
import DicomJPEG2000
import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

/// Own HTJ2K (ISO/IEC 15444-15) codec on the vendored DicomJPEG2000 core (#2330): the three DICOM syntaxes
/// `.201/.202/.203` with their distinct constraints (PS3.5 8.2.14 and 10.18.1), own encodes decoded exactly by
/// OpenJPH (`ojph_expand`) and OpenJPEG (`opj_decompress`), independent OpenJPH-encoded inputs across coding options,
/// capability/syntax agreement, PS3.5 encapsulation, reduced/region decodes against `ojph_expand -skip_res`,
/// deterministic parallel decodes with cancellation, malformed streams and a release timing comparison.
final class HTJ2KCodecTests: XCTestCase {
    private static let ojphCompress = "/opt/homebrew/bin/ojph_compress"
    private static let ojphExpand = "/opt/homebrew/bin/ojph_expand"
    private static let opjDecompress = "/opt/homebrew/bin/opj_decompress"
    private static let htSyntaxes: [DicomTransferSyntax] = [.htj2kLossless, .htj2kLosslessRPCL, .htj2k]

    // MARK: - Fixtures

    /// Deterministic samples: ramps plus noise; signed values are centred on zero; `extreme` alternates the range ends.
    private static func samples(width: Int, height: Int, precision: Int, components: Int = 1, signed: Bool = false,
                                seed: UInt32 = 2330, extreme: Bool = false) -> [Int] {
        var state = seed
        let limit = 1 << precision
        return (0..<(width * height * components)).map { index in
            state = state &* 1_664_525 &+ 1_013_904_223
            let pixel = index / components, component = index % components
            let x = pixel % width, y = pixel / width
            let value: Int
            if extreme {
                value = ((x / 3 + y / 5 + component) % 2 == 0) ? 0 : limit - 1
            } else {
                let noise = Int(state >> 8) % max(1, limit / 8)
                value = (x * limit / max(1, width) / 2 + y * limit / max(1, height) / 4 + noise + component * (limit / 16)) % limit
            }
            return signed ? value - limit / 2 : value
        }
    }

    /// Stored-pixel bytes in the DICOM layout (little-endian, two's complement for signed 16-bit containers).
    private static func stored(_ samples: [Int], precision: Int) -> Data {
        var data = Data(capacity: samples.count * (precision > 8 ? 2 : 1))
        for value in samples {
            if precision > 8 {
                let word = UInt16(bitPattern: Int16(truncatingIfNeeded: value))
                data.append(UInt8(word & 0xFF)); data.append(UInt8(word >> 8))
            } else {
                data.append(UInt8(truncatingIfNeeded: value))
            }
        }
        return data
    }

    /// Samples as decoded through the frame reader (16-bit signed values are offset to unsigned).
    private static func readerContract(_ samples: [Int], precision: Int, signed: Bool) -> [Int] {
        guard signed, precision > 8 else { return samples }
        return samples.map { $0 + 32768 }
    }

    private static func descriptor(_ syntax: DicomTransferSyntax, width: Int, height: Int, precision: Int, components: Int = 1,
                                   signed: Bool = false, photometric: String? = nil) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(transferSyntaxUID: syntax.rawValue, rows: height, columns: width, bitsAllocated: precision > 8 ? 16 : 8,
                                       bitsStored: precision, highBit: precision - 1, pixelRepresentation: signed ? 1 : 0, samplesPerPixel: components,
                                       photometricInterpretation: photometric ?? (components == 3 ? "YBR_RCT" : "MONOCHROME2"),
                                       planarConfiguration: components == 3 ? 0 : nil)
    }

    private static func ownEncode(_ samples: [Int], descriptor: DicomCompressedFrameDescriptor, intent: DicomEncodingIntent = .reversible,
                                  tileSize: (width: Int, height: Int)? = nil) async throws -> Data {
        let frame = DicomCodecDecodedFrame(buffer: .owned(stored(samples, precision: descriptor.bitsStored)), width: descriptor.columns,
                                           height: descriptor.rows, bitsPerSample: descriptor.bitsStored, componentCount: descriptor.samplesPerPixel)
        return try await DicomJ2KSwiftBackend().encode(DicomFrameEncodeRequest(frame: frame, descriptor: descriptor,
                                                                               targetTransferSyntaxUID: descriptor.transferSyntaxUID,
                                                                               intent: intent, tileSize: tileSize))
    }

    private static func ownDecode(_ codestream: Data, descriptor: DicomCompressedFrameDescriptor,
                                  partial: DicomPartialDecodeRequest? = nil) async throws -> DicomCodecDecodedFrame {
        try await DicomJ2KSwiftBackend().decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0, partialRequest: partial))
    }

    private static func decodedSamples(_ frame: DicomCodecDecodedFrame) -> [Int] {
        let bytes = [UInt8](frame.buffer.data)
        guard frame.bitsPerSample > 8 else { return bytes.map(Int.init) }
        return stride(from: 0, to: bytes.count, by: 2).map { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 }
    }

    private static func mainHeaderMarkers(_ codestream: Data) -> [UInt8: Data] {
        var markers: [UInt8: Data] = [:]
        var cursor = 2
        while cursor + 4 <= codestream.count, codestream[cursor] == 0xFF, codestream[cursor + 1] != 0x90 {
            let length = Int(codestream[cursor + 2]) << 8 | Int(codestream[cursor + 3])
            markers[codestream[cursor + 1]] = codestream.subdata(in: (cursor + 4)..<min(codestream.count, cursor + 2 + length))
            cursor += 2 + length
        }
        return markers
    }

    private static func encapsulatedFile(fragments: [Data], syntax: DicomTransferSyntax, width: Int, height: Int, precision: Int,
                                         components: Int = 1, signed: Bool = false, photometric: String = "MONOCHROME2") throws -> Data {
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23300001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23300002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23300003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["HTJ2K^CODEC"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["HTJ2K-2330"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(components)])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([photometric])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([precision > 8 ? 16 : 8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([signed ? 1 : 0]))
        ]
        if fragments.count > 1 { elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(fragments.count)"]))) }
        if components == 3 { elements.append(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0]))) }
        if syntax == .explicitVRLittleEndian {
            elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: precision > 8 ? .OW : .OB,
                                             value: .bytes(fragments.reduce(into: Data()) { $0.append($1) })))
        } else {
            elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                                             value: .bytes(try DicomTranscoder.encapsulate(fragments: fragments).pixelData)))
        }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements), options: .init(transferSyntax: syntax))
    }

    // MARK: - External tools

    private static func toolsAvailable() -> Bool {
        [ojphCompress, ojphExpand, opjDecompress].allSatisfy { FileManager.default.isExecutableFile(atPath: $0) }
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

    /// PGM/PPM (binary, big-endian 16-bit, comments allowed) as written by `ojph_expand` and `opj_decompress`.
    private static func readPNM(_ url: URL) throws -> (width: Int, height: Int, components: Int, samples: [Int]) {
        let bytes = [UInt8](try Data(contentsOf: url))
        var cursor = 0
        func token() -> String {
            while cursor < bytes.count {
                if bytes[cursor] == UInt8(ascii: "#") { while cursor < bytes.count, bytes[cursor] != 0x0A { cursor += 1 } }
                else if bytes[cursor] == 0x20 || bytes[cursor] == 0x0A || bytes[cursor] == 0x0D || bytes[cursor] == 0x09 { cursor += 1 }
                else { break }
            }
            let start = cursor
            while cursor < bytes.count, !(bytes[cursor] == 0x20 || bytes[cursor] == 0x0A || bytes[cursor] == 0x0D || bytes[cursor] == 0x09) { cursor += 1 }
            return String(decoding: bytes[start..<cursor], as: UTF8.self)
        }
        let magic = token(); let width = Int(token()) ?? 0; let height = Int(token()) ?? 0; let maximum = Int(token()) ?? 0
        cursor += 1
        let components = magic == "P6" ? 3 : 1
        let count = width * height * components
        var samples = [Int](); samples.reserveCapacity(count)
        if maximum > 255 {
            for index in 0..<count { samples.append(Int(bytes[cursor + index * 2]) << 8 | Int(bytes[cursor + index * 2 + 1])) }
        } else {
            for index in 0..<count { samples.append(Int(bytes[cursor + index])) }
        }
        return (width, height, components, samples)
    }

    private static func writePNM(_ samples: [Int], width: Int, height: Int, precision: Int, components: Int, to url: URL) throws {
        var data = Data("\(components == 3 ? "P6" : "P5")\n\(width) \(height)\n\((1 << precision) - 1)\n".utf8)
        for value in samples {
            if precision > 8 { data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xFF)) } else { data.append(UInt8(value)) }
        }
        try data.write(to: url)
    }

    /// Encodes with `ojph_compress`; unsigned samples go through PGM/PPM, signed samples through the raw reader, which
    /// takes the unsigned representation (sample + 2^(precision-1)) and applies the level shift itself.
    private static func ojphEncode(_ samples: [Int], width: Int, height: Int, precision: Int, components: Int, signed: Bool,
                                   flags: [String], directory: URL, name: String) throws -> Data {
        let out = directory.appendingPathComponent("\(name).j2c")
        var arguments = ["-o", out.path] + flags
        if signed {
            let raw = directory.appendingPathComponent("\(name).raw")
            try stored(samples.map { $0 + (1 << (precision - 1)) }, precision: precision).write(to: raw)
            arguments += ["-i", raw.path, "-dims", "{\(width),\(height)}", "-num_comps", "\(components)", "-downsamp", "{1,1}",
                          "-signed", Array(repeating: "true", count: components).joined(separator: ","),
                          "-bit_depth", Array(repeating: "\(precision)", count: components).joined(separator: ",")]
        } else {
            let pnm = directory.appendingPathComponent(components == 3 ? "\(name).ppm" : "\(name).pgm")
            try writePNM(samples, width: width, height: height, precision: precision, components: components, to: pnm)
            arguments += ["-i", pnm.path]
        }
        let result = try run(ojphCompress, arguments)
        guard result.status == 0 else { throw XCTSkip("ojph_compress failed: \(result.output.prefix(300))") }
        return try Data(contentsOf: out)
    }

    /// Decodes with `ojph_expand`: PGM/PPM for unsigned components (they clamp negative samples), the little-endian
    /// raw writer for signed ones.
    private static func ojphDecode(_ codestream: Data, width: Int, height: Int, precision: Int, components: Int, signed: Bool,
                                   skipResolutions: Int = 0, directory: URL, name: String) throws -> (width: Int, height: Int, samples: [Int]) {
        let input = directory.appendingPathComponent("\(name)-ojph-in.j2c")
        try codestream.write(to: input)
        let out = directory.appendingPathComponent("\(name)-ojph-r\(skipResolutions)." + (signed ? "raw" : (components == 3 ? "ppm" : "pgm")))
        var arguments = ["-i", input.path, "-o", out.path]
        if skipResolutions > 0 { arguments += ["-skip_res", "\(skipResolutions),\(skipResolutions)"] }
        let result = try run(ojphExpand, arguments)
        guard result.status == 0 else { throw XCTSkip("ojph_expand failed: \(result.output.prefix(300))") }
        guard signed else {
            let image = try readPNM(out)
            XCTAssertEqual(image.components, components)
            return (image.width, image.height, image.samples)
        }
        let factor = 1 << skipResolutions
        let outWidth = (width + factor - 1) / factor, outHeight = (height + factor - 1) / factor
        let bytes = [UInt8](try Data(contentsOf: out))
        let samples: [Int] = precision > 8
            ? stride(from: 0, to: bytes.count, by: 2).map { Int(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) }
            : bytes.map { Int(Int8(bitPattern: $0)) }
        XCTAssertEqual(samples.count, outWidth * outHeight * components, "\(name): raw sample count")
        return (outWidth, outHeight, samples)
    }

    /// Decodes with `opj_decompress` into `.rawl` planes (little-endian; signed components as two's-complement codes).
    private static func opjDecode(_ codestream: Data, width: Int, height: Int, precision: Int, components: Int, signed: Bool,
                                  directory: URL, name: String) throws -> [Int] {
        let input = directory.appendingPathComponent("\(name)-opj-in.j2c")
        try codestream.write(to: input)
        let out = directory.appendingPathComponent("\(name)-opj.rawl")
        let result = try run(opjDecompress, ["-i", input.path, "-o", out.path])
        guard result.status == 0 else { throw XCTSkip("opj_decompress failed: \(result.output.prefix(300))") }
        let bytes = [UInt8](try Data(contentsOf: out))
        let planes: [Int] = precision > 8
            ? stride(from: 0, to: bytes.count, by: 2).map { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 }
            : bytes.map(Int.init)
        let signedPlanes = signed ? planes.map { ($0 + (1 << (precision - 1))) % (1 << precision) - (1 << (precision - 1)) } : planes
        guard components == 3 else { return signedPlanes }
        var interleaved = [Int](repeating: 0, count: width * height * 3)
        for component in 0..<3 { for pixel in 0..<(width * height) { interleaved[pixel * 3 + component] = signedPlanes[component * width * height + pixel] } }
        return interleaved
    }

    private static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Own encodes per syntax, decoded by OpenJPH and OpenJPEG

    func test_ownEncodesMeetEachSyntaxAndDecodeExactlyInOpenJPHAndOpenJPEG() async throws {
        guard Self.toolsAvailable() else { throw XCTSkip("OpenJPH/OpenJPEG CLI tools are not installed at /opt/homebrew/bin") }
        let directory = try Self.temporaryDirectory("htj2k-own")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 130, height = 97
        let inputs: [(name: String, precision: Int, components: Int, signed: Bool, extreme: Bool)] = [
            ("gray8", 8, 1, false, false), ("signed12", 12, 1, true, false), ("gray16", 16, 1, false, false),
            ("gray16-extremes", 16, 1, false, true), ("signed16-extremes", 16, 1, true, true), ("rgb8", 8, 3, false, false)
        ]
        for input in inputs {
            let source = Self.samples(width: width, height: height, precision: input.precision, components: input.components,
                                      signed: input.signed, extreme: input.extreme)
            for syntax in Self.htSyntaxes {
                let label = "\(input.name) \(syntax.rawValue)"
                let descriptor = Self.descriptor(syntax, width: width, height: height, precision: input.precision, components: input.components,
                                                 signed: input.signed)
                // The encoder takes RGB source samples and applies the RCT; the encapsulated object declares YBR_RCT.
                let sourceDescriptor = Self.descriptor(syntax, width: width, height: height, precision: input.precision, components: input.components,
                                                       signed: input.signed, photometric: input.components == 3 ? "RGB" : nil)
                let codestream = try await Self.ownEncode(source, descriptor: sourceDescriptor)
                let inspection = try DicomJ2KCodestreamInspector.inspect(codestream)
                XCTAssertTrue(inspection.isHighThroughput, label)
                XCTAssertTrue(inspection.isLosslessCoding, label)
                XCTAssertNil(inspection.container, label)
                XCTAssertNil(DicomHTJ2KProfile.violation(of: syntax.rawValue, in: codestream), label)
                let markers = Self.mainHeaderMarkers(codestream)
                XCTAssertNil(markers[0x64], "\(label): no COM marker (the private block-format signal is gone)")
                // CAP (T.814 A.3.2): Part 15 word, reversible, MAGB = precision + 2 (+1 with the RCT), as OpenJPH writes.
                let cap = try XCTUnwrap(markers[0x50], label)
                XCTAssertEqual([UInt8](cap.prefix(4)), [0x00, 0x02, 0x00, 0x00], label)
                let expectedMAGB = input.precision + 2 + (input.components == 3 ? 1 : 0) - 8
                XCTAssertEqual(Int(cap[cap.startIndex + 4]) << 8 | Int(cap[cap.startIndex + 5]), expectedMAGB, "\(label): Ccap15")
                if syntax == .htj2kLosslessRPCL {
                    XCTAssertEqual(inspection.progressionOrder, 2, label)
                    XCTAssertTrue(inspection.hasTileLengthMarkers, label)
                    XCTAssertEqual(inspection.decompositionLevels, DicomHTJ2KProfile.rpclDecompositionLevels(rows: height, columns: width), label)
                    let tlm = try XCTUnwrap(markers[0x55], label)
                    XCTAssertEqual([UInt8](tlm.prefix(2)), [0x00, 0x60], "\(label): Ztlm 0, 16-bit Ttlm and 32-bit Ptlm")
                    let psot = Int(tlm[tlm.startIndex + 4]) << 24 | Int(tlm[tlm.startIndex + 5]) << 16 | Int(tlm[tlm.startIndex + 6]) << 8 | Int(tlm[tlm.startIndex + 7])
                    let sot = try XCTUnwrap(codestream.range(of: Data([0xFF, 0x90])), label).lowerBound
                    XCTAssertEqual(psot, codestream.count - 2 - sot, "\(label): Ptlm equals the tile-part length up to EOC")
                } else {
                    XCTAssertEqual(inspection.progressionOrder, 0, label)
                    XCTAssertFalse(inspection.hasTileLengthMarkers, label)
                }
                let ojph = try Self.ojphDecode(codestream, width: width, height: height, precision: input.precision, components: input.components,
                                               signed: input.signed, directory: directory, name: "\(input.name)-\(syntax.rawValue)")
                XCTAssertEqual(ojph.samples, source, "\(label): ojph_expand decodes the own stream exactly")
                let opj = try Self.opjDecode(codestream, width: width, height: height, precision: input.precision, components: input.components,
                                             signed: input.signed, directory: directory, name: "\(input.name)-\(syntax.rawValue)")
                XCTAssertEqual(opj, source, "\(label): opj_decompress decodes the own stream exactly")
                let own = try await Self.ownDecode(codestream, descriptor: descriptor)
                XCTAssertEqual(own.buffer.data, Self.stored(source, precision: input.precision), "\(label): own decode")
            }
        }
    }

    func test_tiledReversibleEncodesWriteRealTilesThatOpenJPHDecodesExactly() async throws {
        guard Self.toolsAvailable() else { throw XCTSkip("OpenJPH/OpenJPEG CLI tools are not installed at /opt/homebrew/bin") }
        let directory = try Self.temporaryDirectory("htj2k-tiles")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 71, height = 45
        for (syntax, precision) in [(DicomTransferSyntax.htj2kLossless, 12), (.jpeg2000Lossless, 16)] {
            let source = Self.samples(width: width, height: height, precision: precision, signed: precision == 12)
            let descriptor = Self.descriptor(syntax, width: width, height: height, precision: precision, signed: precision == 12)
            let codestream = try await Self.ownEncode(source, descriptor: descriptor, tileSize: (32, 24))
            let siz = try XCTUnwrap(Self.mainHeaderMarkers(codestream)[0x51])
            let xtsiz = Int(siz[siz.startIndex + 18]) << 24 | Int(siz[siz.startIndex + 19]) << 16 | Int(siz[siz.startIndex + 20]) << 8 | Int(siz[siz.startIndex + 21])
            XCTAssertEqual(xtsiz, 32, "\(syntax.rawValue): XTsiz")
            XCTAssertEqual(codestream.split(separator: Data([0xFF, 0x90]), omittingEmptySubsequences: false).count - 1, 6, "\(syntax.rawValue): 3x2 tiles")
            if syntax == .htj2kLossless {  // ojph_expand decodes Part 15 streams only.
                let ojph = try Self.ojphDecode(codestream, width: width, height: height, precision: precision, components: 1, signed: precision == 12,
                                               directory: directory, name: "tiles-\(precision)")
                XCTAssertEqual(ojph.samples, source, "\(syntax.rawValue): ojph_expand")
            }
            let opj = try Self.opjDecode(codestream, width: width, height: height, precision: precision, components: 1, signed: precision == 12,
                                         directory: directory, name: "tiles-\(precision)")
            XCTAssertEqual(opj, source, "\(syntax.rawValue): opj_decompress")
            let ownTiled = try await Self.ownDecode(codestream, descriptor: descriptor)
            XCTAssertEqual(ownTiled.buffer.data, Self.stored(source, precision: precision))
        }
        // Tiling is refused typed for irreversible encodes and for the single-tile .202 syntax.
        let source = Self.samples(width: width, height: height, precision: 8)
        for (syntax, intent) in [(DicomTransferSyntax.htj2k, DicomEncodingIntent.irreversible(quality: 0.8)), (.htj2kLosslessRPCL, .reversible)] {
            do {
                _ = try await Self.ownEncode(source, descriptor: Self.descriptor(syntax, width: width, height: height, precision: 8), intent: intent, tileSize: (32, 24))
                XCTFail("\(syntax.rawValue) tiled encode must be refused")
            } catch let error as DicomJ2KSwiftBackendError {
                guard case .unsupportedShape = error else { return XCTFail("\(error)") }
            }
        }
    }

    // MARK: - Loss comes from the intent, not the UID

    func test_generalSyntaxEncodesLossyOnlyWithExplicitIntentAndLosslessSyntaxesRefuseIt() async throws {
        guard Self.toolsAvailable() else { throw XCTSkip("OpenJPH/OpenJPEG CLI tools are not installed at /opt/homebrew/bin") }
        let directory = try Self.temporaryDirectory("htj2k-intent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 96, height = 70
        let source = Self.samples(width: width, height: height, precision: 12)
        let descriptor = Self.descriptor(.htj2k, width: width, height: height, precision: 12)
        // Reversible intent under the general syntax stays lossless and keeps the SOP identity through the transcoder.
        let reversible = try await Self.ownEncode(source, descriptor: descriptor, intent: .reversible)
        XCTAssertTrue(try DicomJ2KCodestreamInspector.inspect(reversible).isLosslessCoding)
        let native = try Self.encapsulatedFile(fragments: [Self.stored(source, precision: 12)], syntax: .explicitVRLittleEndian, width: width, height: height, precision: 12)
        let transcoded = try await DicomTranscoder().transcode(native, to: .htj2k, intent: .reversible)
        let decoder = try DCMDecoder(data: transcoded)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.htj2k.rawValue)
        XCTAssertEqual(decoder.info(for: .sopInstanceUID), "2.25.23300001")
        XCTAssertTrue(decoder.info(for: .lossyImageCompression).isEmpty, "no lossy provenance for a reversible encode under .203")
        XCTAssertEqual(try DCMDecoder(data: try DicomTranscoder().transcode(transcoded, to: .explicitVRLittleEndian)).getAllFrames()?.first?.data,
                       Self.stored(source, precision: 12))
        // Irreversible intent uses the 9/7 filter; OpenJPH, OpenJPEG and the own decoder agree within rounding.
        let irreversible = try await Self.ownEncode(source, descriptor: descriptor, intent: .irreversible(quality: 0.9))
        let inspection = try DicomJ2KCodestreamInspector.inspect(irreversible)
        XCTAssertTrue(inspection.isHighThroughput)
        XCTAssertFalse(inspection.isLosslessCoding)
        XCTAssertNil(DicomHTJ2KProfile.violation(of: DicomTransferSyntax.htj2k.rawValue, in: irreversible))
        let cap = try XCTUnwrap(Self.mainHeaderMarkers(irreversible)[0x50])
        XCTAssertEqual(Int(cap[cap.startIndex + 5]) & 0x20, 0x20, "Ccap15 flags the irreversible transform")
        let ojph = try Self.ojphDecode(irreversible, width: width, height: height, precision: 12, components: 1, signed: false, directory: directory, name: "irreversible").samples
        let opj = try Self.opjDecode(irreversible, width: width, height: height, precision: 12, components: 1, signed: false, directory: directory, name: "irreversible")
        let own = Self.decodedSamples(try await Self.ownDecode(irreversible, descriptor: descriptor))
        XCTAssertLessThanOrEqual(zip(own, opj).map { abs($0 - $1) }.max() ?? 0, 2, "own 9/7 inverse within 2 LSB of OpenJPEG")
        XCTAssertLessThanOrEqual(zip(own, ojph).map { abs($0 - $1) }.max() ?? 0, 2, "own 9/7 inverse within 2 LSB of OpenJPH")
        XCTAssertLessThanOrEqual(zip(ojph, source).map { abs($0 - $1) }.max() ?? 0, 4096 / 16, "quality 0.9 stays close to the source")
        let lossy = try await DicomTranscoder().transcode(native, to: .htj2k, intent: .irreversible(quality: 0.9))
        let lossyDecoder = try DCMDecoder(data: lossy)
        XCTAssertEqual(lossyDecoder.info(for: .lossyImageCompression), "01")
        XCTAssertNotEqual(lossyDecoder.info(for: .sopInstanceUID), "2.25.23300001")
        // The lossless-only syntaxes refuse irreversible intent typed.
        for syntax in [DicomTransferSyntax.htj2kLossless, .htj2kLosslessRPCL] {
            do {
                _ = try await Self.ownEncode(source, descriptor: Self.descriptor(syntax, width: width, height: height, precision: 12), intent: .irreversible(quality: 0.9))
                XCTFail("\(syntax.rawValue) must refuse irreversible intent")
            } catch let error as DicomJ2KSwiftBackendError {
                guard case .unsupportedShape(_, let reason) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(reason.contains("lossless-only"), reason)
            }
        }
    }

    // MARK: - Independent OpenJPH inputs

    func test_openJPHEncodedInputsDecodeExactlyAcrossOptionsAndReductions() async throws {
        guard Self.toolsAvailable() else { throw XCTSkip("OpenJPH/OpenJPEG CLI tools are not installed at /opt/homebrew/bin") }
        let directory = try Self.temporaryDirectory("htj2k-ojph")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 71, height = 45
        let cases: [(name: String, precision: Int, components: Int, signed: Bool, extreme: Bool, flags: [String], tolerance: Int)] = [
            ("gray8", 8, 1, false, false, ["-reversible", "true"], 0),
            ("gray12-blocks32", 12, 1, false, false, ["-reversible", "true", "-num_decomps", "3", "-block_size", "{32,32}"], 0),
            ("gray16-rlcp", 16, 1, false, false, ["-reversible", "true", "-prog_order", "RLCP"], 0),
            ("gray16-extremes-cprl-precincts", 16, 1, false, true, ["-reversible", "true", "-prog_order", "CPRL", "-precincts", "{64,64},{32,32}"], 0),
            ("signed12-pcrl", 12, 1, true, false, ["-reversible", "true", "-prog_order", "PCRL"], 0),
            ("signed16-extremes", 16, 1, true, true, ["-reversible", "true", "-num_decomps", "2"], 0),
            ("gray12-tiles-tileparts-tlm", 12, 1, false, false, ["-reversible", "true", "-tile_size", "{40,24}", "-tileparts", "R", "-tlm_marker", "true"], 0),
            ("gray8-blocks16-lrcp", 8, 1, false, false, ["-reversible", "true", "-block_size", "{16,16}", "-prog_order", "LRCP"], 0),
            ("rgb8-rct", 8, 3, false, false, ["-reversible", "true", "-colour_trans", "true"], 0),
            ("rgb8-no-mct", 8, 3, false, false, ["-reversible", "true", "-colour_trans", "false"], 0),
            ("gray12-97", 12, 1, false, false, ["-reversible", "false", "-qstep", "0.002"], 2),
            ("rgb8-97-ict", 8, 3, false, false, ["-reversible", "false", "-colour_trans", "true", "-qstep", "0.005"], 2)
        ]
        for testCase in cases {
            let source = Self.samples(width: width, height: height, precision: testCase.precision, components: testCase.components,
                                      signed: testCase.signed, seed: 5, extreme: testCase.extreme)
            let codestream = try Self.ojphEncode(source, width: width, height: height, precision: testCase.precision, components: testCase.components,
                                                 signed: testCase.signed, flags: testCase.flags, directory: directory, name: testCase.name)
            let inspection = try DicomJ2KCodestreamInspector.inspect(codestream)
            XCTAssertTrue(inspection.isHighThroughput, testCase.name)
            let syntax: DicomTransferSyntax = testCase.tolerance == 0 ? .htj2kLossless : .htj2k
            let photometric = testCase.components == 3
                ? (testCase.flags.contains("false") && testCase.flags.contains("-colour_trans") ? "RGB" : (testCase.tolerance == 0 ? "YBR_RCT" : "YBR_ICT"))
                : "MONOCHROME2"
            let descriptor = Self.descriptor(syntax, width: width, height: height, precision: testCase.precision, components: testCase.components,
                                             signed: testCase.signed, photometric: photometric)
            // OpenJPH's raw reader/writer treat signed samples inconsistently (level shift and wrap-around), so signed
            // inputs are referenced against opj_decompress; unsigned inputs against ojph_expand and the source.
            let reference: [Int] = testCase.signed
                ? try Self.opjDecode(codestream, width: width, height: height, precision: testCase.precision, components: testCase.components,
                                     signed: true, directory: directory, name: testCase.name)
                : try Self.ojphDecode(codestream, width: width, height: height, precision: testCase.precision, components: testCase.components,
                                      signed: false, directory: directory, name: testCase.name).samples
            let ownSamples = Self.decodedSamples(try await Self.ownDecode(codestream, descriptor: descriptor)).map { word -> Int in
                guard testCase.signed else { return word }
                return testCase.precision > 8 ? Int(Int16(bitPattern: UInt16(word))) : Int(Int8(bitPattern: UInt8(word)))
            }
            if testCase.tolerance == 0 {
                XCTAssertEqual(ownSamples, reference, "\(testCase.name): exact against the independent decoder")
                if !testCase.signed { XCTAssertEqual(ownSamples, source, "\(testCase.name): exact against the source") }
            } else {
                XCTAssertLessThanOrEqual(zip(ownSamples, reference).map { abs($0 - $1) }.max() ?? 0, testCase.tolerance,
                                         "\(testCase.name): within \(testCase.tolerance) LSB of ojph_expand")
            }
            // Reduced resolutions against `ojph_expand -skip_res` (reversible, unsigned cases).
            guard testCase.tolerance == 0, !testCase.signed else { continue }
            for reduce in 1...min(2, inspection.decompositionLevels) {
                let reduced = try Self.ojphDecode(codestream, width: width, height: height, precision: testCase.precision, components: testCase.components,
                                                  signed: false, skipResolutions: reduce, directory: directory, name: testCase.name)
                let partial = try await Self.ownDecode(codestream, descriptor: descriptor,
                                                       partial: DicomPartialDecodeRequest(resolutionLevel: inspection.decompositionLevels - reduce))
                XCTAssertEqual(partial.width, reduced.width, "\(testCase.name) reduce \(reduce)")
                XCTAssertEqual(partial.height, reduced.height, "\(testCase.name) reduce \(reduce)")
                XCTAssertEqual(Self.decodedSamples(partial), reduced.samples, "\(testCase.name) reduce \(reduce): reduced decode against ojph_expand")
            }
        }
    }

    // MARK: - Declared syntax versus codestream

    func test_declaredSyntaxMustMatchTheCodestreamAndTheValidatorReportsTheRPCLOptions() async throws {
        let width = 80, height = 66
        let source = Self.samples(width: width, height: height, precision: 12)
        let part1 = try await Self.ownEncode(source, descriptor: Self.descriptor(.jpeg2000Lossless, width: width, height: height, precision: 12))
        let ht = try await Self.ownEncode(source, descriptor: Self.descriptor(.htj2kLossless, width: width, height: height, precision: 12))
        let htRPCL = try await Self.ownEncode(source, descriptor: Self.descriptor(.htj2kLosslessRPCL, width: width, height: height, precision: 12))
        let htLossy = try await Self.ownEncode(source, descriptor: Self.descriptor(.htj2k, width: width, height: height, precision: 12), intent: .irreversible(quality: 0.9))
        func expectMismatch(_ codestream: Data, under syntax: DicomTransferSyntax, _ fragment: String, line: UInt = #line) async {
            do {
                _ = try await Self.ownDecode(codestream, descriptor: Self.descriptor(syntax, width: width, height: height, precision: 12))
                XCTFail("\(syntax.rawValue) must refuse the codestream", line: line)
            } catch let error as DicomJ2KSwiftBackendError {
                guard case .metadataMismatch(_, let reason) = error else { return XCTFail("\(error)", line: line) }
                XCTAssertTrue(reason.contains(fragment), reason, line: line)
            } catch { XCTFail("\(error)", line: line) }
        }
        await expectMismatch(part1, under: .htj2kLossless, "HT")
        await expectMismatch(part1, under: .htj2k, "HT")
        await expectMismatch(ht, under: .jpeg2000Lossless, "Part 1")
        await expectMismatch(ht, under: .jpeg2000, "Part 1")
        await expectMismatch(htLossy, under: .htj2kLossless, "reversible")
        await expectMismatch(htLossy, under: .htj2kLosslessRPCL, "reversible")
        // A .201 stream declared as .202 still decodes (the samples are what they are) but the profile names the violation
        // and the validator reports it; the own .202 encode satisfies every rule.
        let lenient = try await Self.ownDecode(ht, descriptor: Self.descriptor(.htj2kLosslessRPCL, width: width, height: height, precision: 12))
        XCTAssertEqual(lenient.buffer.data, Self.stored(source, precision: 12))
        XCTAssertEqual(DicomHTJ2KProfile.violation(of: DicomTransferSyntax.htj2kLosslessRPCL.rawValue, in: ht), "PS3.5 10.18.1 requires the RPCL progression order")
        XCTAssertNil(DicomHTJ2KProfile.violation(of: DicomTransferSyntax.htj2kLosslessRPCL.rawValue, in: htRPCL))
        XCTAssertNil(DicomHTJ2KProfile.violation(of: DicomTransferSyntax.htj2kLossless.rawValue, in: htRPCL), "a .202 stream also satisfies .201")
        XCTAssertNil(DicomHTJ2KProfile.violation(of: DicomTransferSyntax.htj2k.rawValue, in: htRPCL))
        var rpclWithoutTLM = htRPCL
        let tlm = try XCTUnwrap(rpclWithoutTLM.range(of: Data([0xFF, 0x55])))
        rpclWithoutTLM.removeSubrange(tlm.lowerBound..<(tlm.lowerBound + 2 + 4 + 6))
        XCTAssertEqual(DicomHTJ2KProfile.violation(of: DicomTransferSyntax.htj2kLosslessRPCL.rawValue, in: rpclWithoutTLM), "PS3.5 10.18.1 requires a TLM marker segment")
        for (codestream, expectMismatch) in [(ht, true), (htRPCL, false)] {
            let file = try Self.encapsulatedFile(fragments: [codestream], syntax: .htj2kLosslessRPCL, width: width, height: height, precision: 12)
            let report = try DicomInstanceValidator.validate(file)
            XCTAssertEqual(report.diagnostics.contains { $0.code == DicomValidationReport.Code.codestreamProfileMismatch }, expectMismatch,
                           "\(report.diagnostics.map(\.code))")
        }
        // Thumbnail rule (either side of the base resolution at or below 64 samples) and the encoder's level choice.
        XCTAssertEqual(DicomHTJ2KProfile.rpclDecompositionLevels(rows: 64, columns: 64), 0)
        XCTAssertEqual(DicomHTJ2KProfile.rpclDecompositionLevels(rows: 65, columns: 8), 1)
        XCTAssertEqual(DicomHTJ2KProfile.rpclDecompositionLevels(rows: 512, columns: 512), 3)
        XCTAssertEqual(DicomHTJ2KProfile.rpclDecompositionLevels(rows: 4096, columns: 3000), 6)
        XCTAssertTrue(DicomHTJ2KProfile.hasThumbnailResolution(width: 1000, height: 40, decompositionLevels: 0))
        XCTAssertFalse(DicomHTJ2KProfile.hasThumbnailResolution(width: 1000, height: 100, decompositionLevels: 0))
        XCTAssertTrue(DicomHTJ2KProfile.hasThumbnailResolution(width: 1000, height: 100, decompositionLevels: 1))
        XCTAssertFalse(DicomHTJ2KProfile.hasThumbnailResolution(width: 513, height: 513, decompositionLevels: 3))
        XCTAssertTrue(DicomHTJ2KProfile.hasThumbnailResolution(width: 512, height: 512, decompositionLevels: 3))
    }

    // MARK: - Capability resolution

    func test_capabilityResolutionPrefersTheOwnHTDecoderAndKeepsOpenJPEGAsFallback() {
        for syntax in Self.htSyntaxes {
            let request = DicomCodecCapabilityRequest(operation: .decode, descriptor: Self.descriptor(syntax, width: 64, height: 64, precision: 16, signed: true))
            let preferred = DicomCodecCapabilities.resolve(request, environment: ["DICOM_J2KSWIFT_MODE": "preferred"])
            XCTAssertTrue(preferred.canExecute, syntax.rawValue)
            XCTAssertEqual(preferred.backendIdentifier, "j2kswift-cpu", syntax.rawValue)
            XCTAssertEqual(preferred.qualification, .qualified, syntax.rawValue)
            XCTAssertNil(preferred.fallbackReason, syntax.rawValue)
            let withoutOpenJPEG = DicomCodecCapabilities.resolve(request, environment: [
                "DICOM_J2KSWIFT_MODE": "preferred", "DICOM_DECODER_OPENJPEG_LIBRARY_PATH": "/nonexistent/isis-2330-openjpeg.dylib"
            ])
            XCTAssertTrue(withoutOpenJPEG.canExecute, "\(syntax.rawValue): the own decoder does not need the OpenJPEG runtime")
            XCTAssertEqual(withoutOpenJPEG.backendIdentifier, "j2kswift-cpu", syntax.rawValue)
            let defaultMode = DicomCodecCapabilities.resolve(request, environment: [:])
            XCTAssertEqual(defaultMode.backendIdentifier, "j2kswift-cpu", "\(syntax.rawValue): preferred is the default")
            let forced = DicomCodecCapabilities.resolve(request, environment: ["DICOM_J2KSWIFT_MODE": "forced-for-tests"])
            XCTAssertEqual(forced.backendIdentifier, "j2kswift-cpu", syntax.rawValue)
            XCTAssertEqual(forced.qualification, .testOnly, syntax.rawValue)
            if DicomJPEG2000Codec.supportsHTJ2K {
                let shadow = DicomCodecCapabilities.resolve(request, environment: ["DICOM_J2KSWIFT_MODE": "shadow"])
                XCTAssertEqual(shadow.backendIdentifier, "openjpeg-cpu", syntax.rawValue)
                XCTAssertEqual(shadow.shadowBackendIdentifier, "j2kswift-cpu", syntax.rawValue)
                let disabled = DicomCodecCapabilities.resolve(request, environment: ["DICOM_J2KSWIFT_MODE": "disabled"])
                XCTAssertTrue(["openjpeg-cpu", "openjpeg-htj2k"].contains(disabled.backendIdentifier ?? ""), "\(syntax.rawValue): OpenJPEG stays the fallback")
            }
            // The 24-bit shape stays outside the own decoder's qualified range and falls back with a reason.
            let deep = DicomCodecCapabilities.resolve(
                DicomCodecCapabilityRequest(operation: .decode, descriptor: DicomCompressedFrameDescriptor(
                    transferSyntaxUID: syntax.rawValue, rows: 8, columns: 8, bitsAllocated: 32, bitsStored: 24, highBit: 23, pixelRepresentation: 0,
                    samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)),
                environment: ["DICOM_J2KSWIFT_MODE": "preferred"])
            XCTAssertNotEqual(deep.backendIdentifier, "j2kswift-cpu", syntax.rawValue)
        }
        let capabilities = DicomJ2KSwiftBackend().capabilities
        XCTAssertEqual(capabilities.transferSyntaxUIDs, Set(Self.htSyntaxes.map(\.rawValue) + [
            DicomTransferSyntax.jpeg2000Lossless.rawValue, DicomTransferSyntax.jpeg2000.rawValue,
            DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.rawValue, DicomTransferSyntax.jpeg2000Part2Multicomponent.rawValue // #2331: Annex J collections
        ]))
        XCTAssertEqual(capabilities.encodeTransferSyntaxUIDs, capabilities.transferSyntaxUIDs)
    }

    // MARK: - PS3.5 encapsulation through the transcoder

    func test_transcoderEncapsulatesOneRawCodestreamPerFrameAndRoundTripsMultiframeAndRewraps() async throws {
        let width = 90, height = 70, frames = 3
        let sources = (0..<frames).map { Self.samples(width: width, height: height, precision: 12, signed: true, seed: UInt32(11 + $0)) }
        let native = try Self.encapsulatedFile(fragments: sources.map { Self.stored($0, precision: 12) }, syntax: .explicitVRLittleEndian,
                                               width: width, height: height, precision: 12, signed: true)
        let transcoder = DicomTranscoder()
        for syntax in Self.htSyntaxes {
            let compressed = try await transcoder.transcode(native, to: syntax, intent: .reversible)
            let decoder = try DCMDecoder(data: compressed)
            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), syntax.rawValue)
            let reader = try decoder.makeEncapsulatedPixelFrameReader()
            XCTAssertEqual(reader.frameCount, frames, syntax.rawValue)
            XCTAssertEqual(reader.descriptor.basicOffsetTable.offsets.count, frames, "\(syntax.rawValue): Basic Offset Table with one entry per frame")
            XCTAssertEqual(reader.descriptor.frameFragmentIndexes.map(\.count), Array(repeating: 1, count: frames), "\(syntax.rawValue): one fragment per frame")
            XCTAssertTrue(reader.descriptor.fragments.allSatisfy { $0.length.isMultiple(of: 2) }, syntax.rawValue)
            for index in 0..<frames {
                let frame = try reader.frame(at: index).data
                XCTAssertEqual([UInt8](frame.prefix(4)), [0xFF, 0x4F, 0xFF, 0x51], "\(syntax.rawValue) frame \(index): raw codestream, no JP2 box")
                XCTAssertNil(DicomHTJ2KProfile.violation(of: syntax.rawValue, in: frame), "\(syntax.rawValue) frame \(index)")
            }
            let validation = try DicomInstanceValidator.validate(compressed)
            XCTAssertFalse(validation.diagnostics.contains { $0.code == DicomValidationReport.Code.codestreamProfileMismatch }, "\(validation.diagnostics.map(\.code))")
            let roundTrip = try DCMDecoder(data: try transcoder.transcode(compressed, to: .explicitVRLittleEndian))
            XCTAssertEqual(roundTrip.getAllFrames()?.map(\.data), sources.map { Self.stored($0, precision: 12) }, syntax.rawValue)
            // The async frame reader (viewer path) returns the same samples through the own backend.
            let frameReader = DicomDecodedFrameReader(decoder: decoder)
            for index in 0..<frames {
                let execution = try await frameReader.frameExecution(at: index, environment: ["DICOM_J2KSWIFT_MODE": "preferred"])
                guard case .gray16(let pixels) = execution.frame.pixels else { return XCTFail("expected 16-bit output") }
                XCTAssertEqual(pixels.map(Int.init), Self.readerContract(sources[index], precision: 12, signed: true), "\(syntax.rawValue) frame \(index)")
                XCTAssertEqual(execution.backendIdentifier, "j2kswift-cpu", "\(syntax.rawValue) frame \(index)")
            }
        }
        // Rewrapping .201 into .203 copies the frames; .201 into .202 re-encodes with the RPCL options.
        let lossless = try await transcoder.transcode(native, to: .htj2kLossless, intent: .reversible)
        let toGeneral = try transcoder.plan(lossless, to: .htj2k)
        XCTAssertEqual(toGeneral.kind, .rewrap)
        let toRPCL = try transcoder.plan(lossless, to: .htj2kLosslessRPCL)
        XCTAssertNotEqual(toRPCL.kind, .rewrap, "\(toRPCL.steps)")
        let rpcl = try await transcoder.transcode(lossless, to: .htj2kLosslessRPCL, intent: .reversible)
        let rpclReader = try DCMDecoder(data: rpcl).makeEncapsulatedPixelFrameReader()
        for index in 0..<frames {
            XCTAssertNil(DicomHTJ2KProfile.violation(of: DicomTransferSyntax.htj2kLosslessRPCL.rawValue, in: try rpclReader.frame(at: index).data), "frame \(index)")
        }
        // Extended Offset Table encapsulation is available for the same fragments.
        let fragments = (0..<frames).map { try? rpclReader.frame(at: $0).data }.compactMap { $0 }
        let extended = try DicomTranscoder.encapsulate(fragments: fragments, forceExtendedOffsets: true)
        XCTAssertNotNil(extended.extendedOffsetTable)
        let parsed = try DicomEncapsulatedPixelDataParser().parse(data: extended.pixelData, pixelDataOffset: 0, numberOfFrames: frames,
                                                                  extendedOffsetTableData: extended.extendedOffsetTable,
                                                                  extendedOffsetTableLengthsData: extended.extendedOffsetTableLengths)
        XCTAssertEqual(parsed.extendedOffsetTable?.lengths, fragments.map { UInt64($0.count) })
    }

    // MARK: - Partial decode, parallel determinism and cancellation

    func test_partialDecodeOfRPCLFramesMatchesOpenJPHReductionsAndCropsAndHonoursCancellation() async throws {
        guard Self.toolsAvailable() else { throw XCTSkip("OpenJPH/OpenJPEG CLI tools are not installed at /opt/homebrew/bin") }
        let directory = try Self.temporaryDirectory("htj2k-partial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 300, height = 210
        let source = Self.samples(width: width, height: height, precision: 16, seed: 21)
        let native = try Self.encapsulatedFile(fragments: [Self.stored(source, precision: 16)], syntax: .explicitVRLittleEndian, width: width, height: height, precision: 16)
        let compressed = try await DicomTranscoder().transcode(native, to: .htj2kLosslessRPCL, intent: .reversible)
        let decoder = try DCMDecoder(data: compressed)
        let codestream = try decoder.makeEncapsulatedPixelFrameReader().frame(at: 0).data
        let levels = try DicomJ2KCodestreamInspector.inspect(codestream).decompositionLevels
        XCTAssertEqual(levels, 3, "300x210 needs three levels for a <= 64-sample base resolution")
        let reader = DicomDecodedFrameReader(decoder: decoder)
        let capabilities = try await reader.partialDecodeCapabilities(at: 0)
        XCTAssertEqual(capabilities.maximumResolutionReductionLevel, levels)
        XCTAssertTrue(capabilities.supportsRegion)
        let full = try await reader.frame(at: 0)
        guard case .gray16(let fullPixels) = full.pixels else { return XCTFail("expected 16-bit output") }
        XCTAssertEqual(fullPixels.map(Int.init), source)
        for reduce in 1...levels {
            let reference = try Self.ojphDecode(codestream, width: width, height: height, precision: 16, components: 1, signed: false,
                                                skipResolutions: reduce, directory: directory, name: "rpcl")
            let result = try await reader.frame(at: 0, partial: DicomPartialFrameDecodeRequest(resolutionReductionLevel: reduce))
            guard case .gray16(let pixels) = result.frame.pixels else { return XCTFail("expected 16-bit output") }
            XCTAssertEqual(result.frame.metadata.width, reference.width, "reduce \(reduce)")
            XCTAssertEqual(result.frame.metadata.height, reference.height, "reduce \(reduce)")
            XCTAssertEqual(pixels.map(Int.init), reference.samples, "reduce \(reduce): against ojph_expand -skip_res")
        }
        // A region decode equals the crop of the full decode.
        let region = DicomFrameRegion(x: 37, y: 19, width: 101, height: 83)
        let cropped = try await reader.frame(at: 0, partial: DicomPartialFrameDecodeRequest(sourceRegion: region))
        guard case .gray16(let regionPixels) = cropped.frame.pixels else { return XCTFail("expected 16-bit output") }
        XCTAssertEqual(cropped.decodedSourceRegion, region)
        var expected: [Int] = []
        for y in region.y..<(region.y + region.height) { for x in region.x..<(region.x + region.width) { expected.append(source[y * width + x]) } }
        XCTAssertEqual(regionPixels.map(Int.init), expected, "region decode equals the crop")
        // Repeated full decodes are byte-identical (deterministic code-block buckets) and cancellation is honoured.
        let descriptor = Self.descriptor(.htj2kLosslessRPCL, width: width, height: height, precision: 16)
        var outputs: Set<Data> = []
        for _ in 0..<4 { outputs.insert(try await Self.ownDecode(codestream, descriptor: descriptor).buffer.data) }
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs.first, Self.stored(source, precision: 16))
        let backend = DicomJ2KSwiftBackend()
        let request = DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0)
        let task = Task { try await backend.decode(request) }
        task.cancel()
        do {
            _ = try await task.value
        } catch is CancellationError {
        } catch {
            XCTFail("cancellation surfaced as \(error)")
        }
    }

    // MARK: - Malformed streams

    func test_malformedHTCodestreamsFailTypedWithoutCrashing() async throws {
        let width = 64, height = 48
        let source = Self.samples(width: width, height: height, precision: 12)
        let descriptor = Self.descriptor(.htj2kLossless, width: width, height: height, precision: 12)
        let codestream = try await Self.ownEncode(source, descriptor: descriptor)
        let sod = try XCTUnwrap(codestream.range(of: Data([0xFF, 0x93]))).upperBound
        var failures = 0
        for cut in [20, sod - 3, sod + 5, sod + (codestream.count - sod) / 2, codestream.count - 3] {
            do {
                let frame = try await Self.ownDecode(codestream.prefix(cut), descriptor: descriptor)
                // A truncation after the tile data may still reconstruct; the samples must then match the source.
                XCTAssertEqual(frame.buffer.data, Self.stored(source, precision: 12), "cut at \(cut)")
            } catch {
                failures += 1
            }
        }
        XCTAssertGreaterThanOrEqual(failures, 3, "truncated headers and tile data fail typed")
        var corrupted = codestream
        for offset in stride(from: sod + 8, to: codestream.count - 4, by: 97) { corrupted[offset] ^= 0x5A }
        do {
            let frame = try await Self.ownDecode(corrupted, descriptor: descriptor)
            XCTAssertEqual(frame.width, width)
        } catch {
            // Typed failure is acceptable; a crash is not.
        }
        do {
            _ = try await Self.ownDecode(Data([0xFF, 0x4F, 0xFF, 0x51, 0x00, 0x29] + [UInt8](repeating: 0, count: 60)), descriptor: descriptor)
            XCTFail("garbage must fail")
        } catch {}
        // The frame reader surfaces a typed decode failure and never falls back to ImageIO for HT.
        let file = try Self.encapsulatedFile(fragments: [codestream.prefix(sod + 5)], syntax: .htj2kLossless, width: width, height: height, precision: 12)
        do {
            _ = try await DicomDecodedFrameReader(decoder: DCMDecoder(data: file)).frame(at: 0)
            XCTFail("a truncated frame must not decode")
        } catch let error as DicomDecodedFrameReader.ReadError {
            guard case .decodeFailed = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Release timing

    func test_releaseTimingOfTheOwnHTCodecAgainstOpenJPEG() async throws {
        #if DEBUG
        throw XCTSkip("Timing is measured in release builds only (swift test -c release -Xswiftc -enable-testing).")
        #else
        try DicomTestRuntimePreflight.require(.openJPEG)
        let width = 512, height = 512
        let source = Self.samples(width: width, height: height, precision: 16, seed: 3)
        let descriptor = Self.descriptor(.htj2kLossless, width: width, height: height, precision: 16)
        let frame = DicomCodecDecodedFrame(buffer: .owned(Self.stored(source, precision: 16)), width: width, height: height, bitsPerSample: 16, componentCount: 1)
        let backend = DicomJ2KSwiftBackend()
        let encodeRequest = DicomFrameEncodeRequest(frame: frame, descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID)
        var codestream = try await backend.encode(encodeRequest)
        func time(_ iterations: Int, _ body: () async throws -> Void) async rethrows -> Double {
            try await body()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { try await body() }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000
        }
        let encode = try await time(5) { codestream = try await backend.encode(encodeRequest) }
        let request = DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0)
        let ownDecode = try await time(10) { _ = try await backend.decode(request) }
        let openJPEGDecode = try await time(10) { _ = try await DicomOpenJPEGFrameBackend().decode(request) }
        let ownFrame = try await backend.decode(request)
        let openJPEGFrame = try await DicomOpenJPEGFrameBackend().decode(request)
        XCTAssertEqual(ownFrame.buffer.data, openJPEGFrame.buffer.data)
        print("HTJ2K-BENCH 512x512 gray16 .201: own decode \(String(format: "%.2f", ownDecode)) ms, OpenJPEG decode \(String(format: "%.2f", openJPEGDecode)) ms, own encode \(String(format: "%.2f", encode)) ms, codestream \(codestream.count) bytes")
        #endif
    }
}
