//
//  JPEG2000Part2InteropTests.swift
//  DicomCoreTests
//
//  Independent cross-validation of the JPEG 2000 Part 2 Multi-component codec (`.92/.93`, issue
//  #3246) against Kakadu (`kdu_compress`/`kdu_expand`), the only installed decoder that implements
//  ISO/IEC 15444-2 Annex J (OpenJPEG and Grok refuse the T.801 SGcod value 2). Kakadu's demo
//  applications run out of process as test tools only — never linked or redistributed — and every
//  test skips when they are missing. Both directions are covered: own collections (8/12/16 bits,
//  signed and unsigned, 1–64 frames, reversible `.92` and irreversible `.93`, several collections,
//  the `.92` → `.93` rewrap) decoded by `kdu_expand`, and Kakadu collections (reversible dependency
//  and SERM transformations, an irreversible matrix) decoded by the own codec and the DICOM layer.
//
//  Thales Matheus Mendonça Santos — November 2026
//

import DicomCodecs
import Foundation
import XCTest
@testable import DicomCore
@testable import DicomJPEG2000

/// Independent cross-validation of the JPEG 2000 Part 2 Multi-component codec (`.92/.93`, issue #3246) against
/// Kakadu (`kdu_compress`/`kdu_expand`), the only installed decoder that implements ISO/IEC 15444-2 Annex J
/// (OpenJPEG and Grok refuse the T.801 SGcod value 2). Kakadu's demo applications run out of process as test tools
/// only — never linked or redistributed — and every test skips when they are missing. Both directions are covered:
/// own collections (8/12/16 bits, signed and unsigned, 1–64 frames, reversible `.92` and irreversible `.93`, several
/// collections, the `.92` → `.93` rewrap) decoded by `kdu_expand`, and Kakadu collections (reversible dependency and
/// SERM transformations, an irreversible matrix) decoded by the own codec and the DICOM layer.
final class JPEG2000Part2InteropTests: XCTestCase {
    private static let lossless = DicomTransferSyntax.jpeg2000Part2MulticomponentLossless
    private static let general = DicomTransferSyntax.jpeg2000Part2Multicomponent

    // MARK: - Tools

    /// The first executable named `name` on `PATH`, `/opt/homebrew/bin` or `/usr/local/bin`; nil when none is found.
    private static func tool(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The paths of `kdu_compress` and `kdu_expand`; throws `XCTSkip` when Kakadu is not installed.
    private static func kakadu() throws -> (compress: String, expand: String) {
        guard let compress = tool("kdu_compress"), let expand = tool("kdu_expand") else {
            throw XCTSkip("Kakadu kdu_compress/kdu_expand are not installed; the Part 2 interoperability evidence needs them")
        }
        return (compress, expand)
    }

    /// Runs `executable` with `arguments` and returns its combined stdout and stderr; throws on a non-zero exit.
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
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "kakadu", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(output.prefix(600))"])
        }
        return output
    }

    private static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Samples

    /// Correlated frames (a common base plus a per-frame drift and noise), full range for `precision`.
    private static func frames(count: Int, width: Int, height: Int, precision: Int, signed: Bool, seed: UInt64) -> [[Int]] {
        var state = seed
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        let low = signed ? -(1 << (precision - 1)) : 0
        let high = signed ? (1 << (precision - 1)) - 1 : (1 << precision) - 1
        let span = high - low
        let base = (0..<(width * height)).map { index -> Int in
            let x = index % width, y = index / width
            return low + (x * span / max(1, width - 1) + y * span / max(1, height - 1)) / 2 + next() % max(1, span / 16)
        }
        return (0..<count).map { frame in
            base.map { value in min(high, max(low, value + (frame * span / 97) + next() % max(2, span / 64) - span / 128)) }
        }
    }

    /// Packs samples as stored bytes: one byte each up to 8 bits, little-endian 16-bit words above.
    private static func stored(_ samples: [Int], precision: Int) -> Data {
        var data = Data(capacity: samples.count * (precision > 8 ? 2 : 1))
        for value in samples {
            if precision > 8 {
                let word = UInt16(truncatingIfNeeded: value)
                data.append(UInt8(word & 0xFF)); data.append(UInt8(word >> 8))
            } else {
                data.append(UInt8(truncatingIfNeeded: value))
            }
        }
        return data
    }

    /// Unpacks stored bytes into samples, the inverse of `stored(_:precision:)`, sign-extending when `signed`.
    private static func samples(_ stored: Data, precision: Int, signed: Bool) -> [Int] {
        let bytes = [UInt8](stored)
        guard precision > 8 else { return bytes.map { signed ? Int(Int8(bitPattern: $0)) : Int($0) } }
        return stride(from: 0, to: bytes.count, by: 2).map {
            let word = UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
            return signed ? Int(Int16(bitPattern: word)) : Int(word)
        }
    }

    /// A single-sample MONOCHROME2 frame descriptor for `syntax` at the given geometry and precision.
    private static func descriptor(_ syntax: DicomTransferSyntax, width: Int, height: Int, precision: Int, signed: Bool) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(transferSyntaxUID: syntax.rawValue, rows: height, columns: width, bitsAllocated: precision > 8 ? 16 : 8,
                                       bitsStored: precision, highBit: precision - 1, pixelRepresentation: signed ? 1 : 0, samplesPerPixel: 1,
                                       photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
    }

    /// Kakadu raw files: one byte per sample up to 8 bits (`.raw`), little-endian 16-bit words above (`.rawl`).
    private static func rawExtension(_ precision: Int) -> String { precision > 8 ? "rawl" : "raw" }

    /// Decodes a codestream with `kdu_expand` into one raw file per output component.
    private static func kakaduDecode(_ codestream: Data, components: Int, precision: Int, signed: Bool, expand: String,
                                     directory: URL, name: String) throws -> [[Int]] {
        let input = directory.appendingPathComponent("\(name).j2c")
        try codestream.write(to: input)
        let outputs = (0..<components).map { directory.appendingPathComponent("\(name)-\($0).\(rawExtension(precision))") }
        try run(expand, ["-i", input.path, "-o", outputs.map(\.path).joined(separator: ","), "-quiet"])
        return try outputs.map { samples(try Data(contentsOf: $0), precision: precision, signed: signed) }
    }

    /// Encodes frames with `kdu_compress` as one Part 2 collection over all of them; `transform` holds the
    /// `Mstage_xforms`/`Mtriang_*`/`Mmatrix_*`/`Mvector_*` attributes.
    private static func kakaduEncode(_ frames: [[Int]], width: Int, height: Int, precision: Int, signed: Bool, reversible: Bool,
                                     transform: [String], compress: String, directory: URL, name: String) throws -> Data {
        let inputs = try frames.enumerated().map { index, frame -> String in
            let url = directory.appendingPathComponent("\(name)-in\(index).\(rawExtension(precision))")
            try stored(frame, precision: precision).write(to: url)
            return url.path
        }
        let m = frames.count, sign = signed ? "yes" : "no"
        let output = directory.appendingPathComponent("\(name).j2c")
        try run(compress, ["-i", inputs.joined(separator: ","), "-o", output.path,
                           "Sdims={\(height),\(width)}", "Sprecision=\(precision + 1)", "Ssigned=yes",
                           "Nprecision=\(precision)", "Nsigned=\(sign)", "Mcomponents=\(m)", "Mprecision=\(precision)", "Msigned=\(sign)",
                           "Creversible=\(reversible ? "yes" : "no")", "Mstage_inputs:I1={0,\(m - 1)}", "Mstage_outputs:I1={0,\(m - 1)}",
                           "Mstage_collections:I1={\(m),\(m)}", "Mnum_stages=1", "Mstages=1", "-quiet"] + transform)
        return try Data(contentsOf: output)
    }

    private static func list(_ values: [Int]) -> String { values.map { "{\($0)}" }.joined(separator: ",") }

    /// Reversible dependency rows that invert the frame-to-frame difference: out[k] = in[k] + out[k−1].
    private static func dependencyTransform(_ m: Int, levelShift: Int) -> [String] {
        var coefficients: [Int] = []
        for k in 1..<m { coefficients += Array(repeating: 0, count: k - 1) + [1, 1] }
        return ["Mstage_xforms:I1={DEP,1,2,1,0}", "Mtriang_size:I1=\(coefficients.count)", "Mtriang_coeffs:I1=\(list(coefficients))",
                "Mvector_size:I2=\(m)", "Mvector_coeffs:I2=\(list([levelShift] + Array(repeating: 0, count: m - 1)))"]
    }

    /// A reversible SERM factorisation of the same inverse: the step for component t adds every earlier component.
    private static func sermTransform(_ m: Int, levelShift: Int) -> [String] {
        var rows: [Int] = []
        for step in 0..<m {
            let target = m - 1 - step
            rows += (0..<m).map { $0 < target ? -1 : ($0 == target ? 1 : 0) }
        }
        rows += (0..<m).map { $0 == m - 1 ? 1 : 0 }
        return ["Mstage_xforms:I1={MATRIX,1,2,1,0}", "Mmatrix_size:I1=\(rows.count)", "Mmatrix_coeffs:I1=\(list(rows))",
                "Mvector_size:I2=\(m)", "Mvector_coeffs:I2=\(list(Array(repeating: levelShift, count: m)))"]
    }

    /// The largest absolute difference between paired samples of `a` and `b`; 0 when either is empty.
    private static func maxDifference(_ a: [Int], _ b: [Int]) -> Int { zip(a, b).map { abs($0 - $1) }.max() ?? 0 }

    // MARK: - Own → Kakadu

    /// Kakadu reconstructs own .92 reversible collections exactly for every shape, and agrees with the own decoder
    /// within one code value on 8-bit .93 irreversible collections.
    func test_kakaduDecodesOwnReversibleAndIrreversibleCollections() async throws {
        let tools = try Self.kakadu()
        let directory = try Self.temporaryDirectory("part2-own-kdu")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 37, height = 29
        let shapes: [(precision: Int, signed: Bool, count: Int)] = [
            (8, false, 2), (8, true, 5), (12, false, 7), (12, true, 64), (16, false, 3), (16, true, 6), (12, false, 1)
        ]
        for shape in shapes {
            let label = "\(shape.precision)-bit \(shape.signed ? "signed" : "unsigned") ×\(shape.count)"
            let frames = Self.frames(count: shape.count, width: width, height: height, precision: shape.precision, signed: shape.signed,
                                     seed: UInt64(shape.precision * 100 + shape.count))
            let stored = frames.map { Self.stored($0, precision: shape.precision) }
            // .92 reversible: Kakadu reconstructs every frame exactly.
            let losslessDescriptor = Self.descriptor(Self.lossless, width: width, height: height, precision: shape.precision, signed: shape.signed)
            let reversible = try await DicomJ2KSwiftBackend().encodeCollection(frames: stored, descriptor: losslessDescriptor,
                                                                                targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible)
            let kakaduFrames = try Self.kakaduDecode(reversible, components: shape.count, precision: shape.precision, signed: shape.signed,
                                                     expand: tools.expand, directory: directory, name: "rev-\(shape.precision)-\(shape.signed)-\(shape.count)")
            XCTAssertEqual(kakaduFrames, frames, "\(label): kdu_expand of the own .92 collection")
            // .93 irreversible: Kakadu and the own decoder agree within one code value. kdu_expand 8.4.1 decodes the
            // coded components of deeper collections but its irreversible Annex J stage then returns only the offsets
            // (its own encoder collapses such stages to empty codestreams too), so the check runs at 8 bits; the
            // deeper ones are inverted from OpenJPEG-decoded coded components by Scripts/conformance/jpeg2000_part2_oracle.py.
            guard shape.precision == 8 else { continue }
            let generalDescriptor = Self.descriptor(Self.general, width: width, height: height, precision: shape.precision, signed: shape.signed)
            let irreversible = try await DicomJ2KSwiftBackend().encodeCollection(frames: stored, descriptor: generalDescriptor,
                                                                                  targetTransferSyntaxUID: Self.general.rawValue,
                                                                                  intent: .irreversible(quality: 0.95))
            let inspection = try DicomJ2KCodestreamInspector.inspect(irreversible)
            XCTAssertEqual(inspection.annexJ?.reversibleCollections, 0, "\(label): lossy coding signals an irreversible transformation")
            let own = try await DicomJ2KSwiftBackend().decodeCollection(irreversible, transferSyntaxUID: Self.general.rawValue)
                .frames.map { Self.samples($0, precision: shape.precision, signed: shape.signed) }
            let kakaduLossy = try Self.kakaduDecode(irreversible, components: shape.count, precision: shape.precision, signed: shape.signed,
                                                    expand: tools.expand, directory: directory, name: "irr-\(shape.precision)-\(shape.signed)-\(shape.count)")
            for index in 0..<shape.count {
                XCTAssertLessThanOrEqual(Self.maxDifference(own[index], kakaduLossy[index]), 1, "\(label): frame \(index) own vs kdu_expand")
            }
        }
    }

    /// A 70-frame native object transcoded to .92 and rewrapped to .93 holds two collections (64 + 6 frames) that
    /// Kakadu decodes back to the source frames in order.
    func test_kakaduDecodesTheCollectionsOfATranscodedAndRewrappedObject() async throws {
        let tools = try Self.kakadu()
        let directory = try Self.temporaryDirectory("part2-object-kdu")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 24, height = 20, precision = 16, count = 70  // two collections: 64 + 6 frames
        let frames = Self.frames(count: count, width: width, height: height, precision: precision, signed: false, seed: 3246)
        let stored = frames.map { Self.stored($0, precision: precision) }
        let native = try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32460001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32460002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32460003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(count)"])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(stored.reduce(into: Data()) { $0.append($1) }))
        ]), options: .init(transferSyntax: .explicitVRLittleEndian))
        let transcoder = DicomTranscoder()
        let lossless = try await transcoder.transcode(native, to: Self.lossless, intent: .reversible)
        let rewrapped = try await transcoder.transcode(lossless, to: Self.general, intent: .reversible)
        for (name, object) in [("92", lossless), ("93-rewrap", rewrapped)] {
            let decoder = try DCMDecoder(data: object)
            let bytes = decoder.dicomDataSnapshot()
            let fragments = try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor).fragments.map { bytes.subdata(in: $0.valueRange) }
            XCTAssertEqual(fragments.count, 2, name)
            var decoded: [[Int]] = []
            for (index, fragment) in fragments.enumerated() {
                let components = try DicomJ2KCodestreamInspector.inspect(fragment).components.count
                decoded += try Self.kakaduDecode(fragment, components: components, precision: precision, signed: false, expand: tools.expand,
                                                 directory: directory, name: "\(name)-\(index)")
            }
            XCTAssertEqual(decoded, frames, "\(name): kdu_expand of every collection restores the frames in order")
        }
    }

    // MARK: - Kakadu → own

    /// Reversible dependency and SERM collections written by Kakadu pass the Part 2 profile and decode exactly with
    /// the own codec for every shape.
    func test_ownCodecDecodesKakaduDependencyAndSERMCollections() async throws {
        let tools = try Self.kakadu()
        let directory = try Self.temporaryDirectory("part2-kdu-own")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 41, height = 23
        let shapes: [(precision: Int, signed: Bool, count: Int)] = [(8, false, 3), (8, true, 2), (12, false, 9), (12, true, 4), (16, false, 5), (16, true, 64)]
        for shape in shapes {
            let label = "\(shape.precision)-bit \(shape.signed ? "signed" : "unsigned") ×\(shape.count)"
            let frames = Self.frames(count: shape.count, width: width, height: height, precision: shape.precision, signed: shape.signed,
                                     seed: UInt64(7 * shape.precision + shape.count))
            let expected = frames.map { Self.stored($0, precision: shape.precision) }
            let levelShift = shape.signed ? 0 : 1 << (shape.precision - 1)
            for (kind, transform) in [("DEP", Self.dependencyTransform(shape.count, levelShift: levelShift)),
                                      ("SERM", Self.sermTransform(shape.count, levelShift: levelShift))] {
                let codestream = try Self.kakaduEncode(frames, width: width, height: height, precision: shape.precision, signed: shape.signed,
                                                       reversible: true, transform: transform, compress: tools.compress, directory: directory,
                                                       name: "\(kind)-\(shape.precision)-\(shape.signed)-\(shape.count)")
                let inspection = try DicomJ2KCodestreamInspector.inspect(codestream)
                XCTAssertEqual(inspection.capabilities, 0x8100, "\(label) \(kind): Kakadu's Rsiz")
                XCTAssertNil(DicomJ2KPart2Profile.violation(of: Self.lossless.rawValue, in: inspection), "\(label) \(kind)")
                XCTAssertNil(DicomJ2KPart2Profile.unsupportedReason(inspection), "\(label) \(kind)")
                let decoded = try await DicomJ2KSwiftBackend().decodeCollection(codestream, transferSyntaxUID: Self.lossless.rawValue)
                XCTAssertEqual(decoded.frames, expected, "\(label) \(kind): own decode of the Kakadu collection")
            }
        }
    }

    /// An 8-bit irreversible Kakadu matrix collection is accepted under .93, refused under .92, decodes within two
    /// codes of Kakadu, and opens through the viewer's frame session (#3256).
    func test_ownCodecDecodesKakaduIrreversibleMatrixCollections() async throws {
        let tools = try Self.kakadu()
        let directory = try Self.temporaryDirectory("part2-kdu-matrix")
        defer { try? FileManager.default.removeItem(at: directory) }
        // kdu_compress 8.4.1 only writes usable irreversible Annex J stages from 8-bit sources here (deeper sources
        // collapse to empty codestreams in the demo encoder), so the irreversible direction is checked at 8 bits.
        let width = 40, height = 32, count = 4, precision = 8
        let frames = Self.frames(count: count, width: width, height: height, precision: precision, signed: false, seed: 93)
        let cumulative = (0..<count).flatMap { row in (0..<count).map { $0 <= row ? 1 : 0 } }
        let transform = ["Mstage_xforms:I1={MATRIX,1,2,0,0}", "Mmatrix_size:I1=\(cumulative.count)", "Mmatrix_coeffs:I1=\(Self.list(cumulative))",
                         "Mvector_size:I2=\(count)", "Mvector_coeffs:I2=\(Self.list(Array(repeating: 128, count: count)))"]
        let codestream = try Self.kakaduEncode(frames, width: width, height: height, precision: precision, signed: false, reversible: false,
                                               transform: transform, compress: tools.compress, directory: directory, name: "matrix")
        let inspection = try DicomJ2KCodestreamInspector.inspect(codestream)
        XCTAssertNil(DicomJ2KPart2Profile.violation(of: Self.general.rawValue, in: inspection))
        XCTAssertNotNil(DicomJ2KPart2Profile.violation(of: Self.lossless.rawValue, in: inspection), "irreversible coding under .92")
        let own = try await DicomJ2KSwiftBackend().decodeCollection(codestream, transferSyntaxUID: Self.general.rawValue)
            .frames.map { Self.samples($0, precision: precision, signed: false) }
        let kakaduFrames = try Self.kakaduDecode(codestream, components: count, precision: precision, signed: false, expand: tools.expand,
                                                 directory: directory, name: "matrix-out")
        for index in 0..<count {
            // Kakadu runs 8-bit irreversible stages in 16-bit fixed point: one more code of rounding than the own float path.
            XCTAssertLessThanOrEqual(Self.maxDifference(own[index], kakaduFrames[index]), 2, "frame \(index): own vs kdu_expand")
            XCTAssertLessThanOrEqual(Self.maxDifference(own[index], frames[index]), 4, "frame \(index): own vs source")
        }
        // The Kakadu collection as a .93 object opens through the viewer's frame session (issue #3256).
        let object = try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32560001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32560002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32560003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(count)"])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                             value: .bytes(try DicomTranscoder.encapsulate(fragments: [codestream], emptyBasicOffsetTable: true).pixelData))
        ]), options: .init(transferSyntax: Self.general))
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: object))
        for index in 0..<count {
            guard case .gray8(let pixels) = try await session.frame(at: index).pixels else { return XCTFail("expected 8-bit output") }
            XCTAssertEqual(pixels.map(Int.init), own[index], "session frame \(index) of the Kakadu .93 object")
        }
        await session.close()
    }

    /// A .92 object holding two Kakadu collections (64 + 3 frames) validates cleanly, reads through the frame reader
    /// and the viewer's frame session (#3256), and transcodes to native without losing a frame.
    func test_kakaduCollectionsInADicomObjectReadThroughTheFrameReaderAndValidator() async throws {
        let tools = try Self.kakadu()
        let directory = try Self.temporaryDirectory("part2-kdu-object")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 30, height = 26, precision = 12
        let frames = Self.frames(count: 67, width: width, height: height, precision: precision, signed: true, seed: 67)
        let first = try Self.kakaduEncode(Array(frames[0..<64]), width: width, height: height, precision: precision, signed: true, reversible: true,
                                          transform: Self.dependencyTransform(64, levelShift: 0), compress: tools.compress,
                                          directory: directory, name: "c0")
        let second = try Self.kakaduEncode(Array(frames[64...]), width: width, height: height, precision: precision, signed: true, reversible: true,
                                           transform: Self.sermTransform(3, levelShift: 0), compress: tools.compress,
                                           directory: directory, name: "c1")
        let object = try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32460011"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32460012"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.32460013"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PART2^KAKADU"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PART2-3246"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([16])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["67"])),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                             value: .bytes(try DicomTranscoder.encapsulate(fragments: [first, second], emptyBasicOffsetTable: true).pixelData))
        ]), options: .init(transferSyntax: Self.lossless))
        let report = try DicomInstanceValidator.validate(object)
        XCTAssertFalse(report.diagnostics.contains { [.codestreamProfileMismatch, .codestreamRuleUnavailable, .pixelMetadataContradiction].contains($0.code) },
                       "\(report.diagnostics.map(\.code))")
        let decoder = try DCMDecoder(data: object)
        let reader = DicomDecodedFrameReader(decoder: decoder)
        XCTAssertEqual(reader.frameCount, 67)
        for index in [0, 31, 63, 64, 66] {
            let execution = try await reader.frameExecution(at: index)
            guard case .gray16(let pixels) = execution.frame.pixels else { return XCTFail("expected 16-bit output") }
            XCTAssertEqual(pixels.map(Int.init), frames[index].map { $0 + 32768 }, "frame \(index)")
        }
        // The viewer's frame session serves the same frames (issue #3256).
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: object))
        XCTAssertEqual(session.index.frameCount, 67)
        for index in [0, 31, 63, 64, 66] {
            guard case .gray16(let pixels) = try await session.frame(at: index).pixels else { return XCTFail("expected 16-bit output") }
            XCTAssertEqual(pixels.map(Int.init), frames[index].map { $0 + 32768 }, "session frame \(index)")
        }
        await session.close()
        // Native round trip through the transcoder keeps every frame.
        let native = try DCMDecoder(data: try DicomTranscoder().transcode(object, to: .explicitVRLittleEndian))
        XCTAssertEqual(native.getAllFrames()?.map(\.data), frames.map { Self.stored($0, precision: precision) })
    }
}
