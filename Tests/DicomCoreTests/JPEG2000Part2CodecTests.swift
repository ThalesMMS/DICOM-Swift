import DicomCodecs
import Foundation
import XCTest
@testable import DicomCore
@testable import DicomJPEG2000

/// JPEG 2000 Part 2 Multi-component (`1.2.840.10008.1.2.4.92/.93`, PS3.5 8.2.4) on the own DicomJPEG2000 codec
/// (#2331): frames are coded as the components of collection codestreams with an ISO/IEC 15444-2 Annex J array-based
/// transformation (MCT/MCC/MCO/CBD marker segments). No independent Part 2 decoder is installed (OpenJPEG rejects the
/// T.801 SGcod value 2), so the evidence is split: the coded components of own streams are decoded by OpenJPEG after
/// the Annex J markers are stripped and compared with the forward transformation computed here; hand-built streams
/// (OpenJPEG-coded components plus markers written from the T.801 layout) are decoded by the own codec; the DICOM
/// layer (collections, fragments, offset tables, frame mapping, validation, transcoder routes) is checked end to end.
final class JPEG2000Part2CodecTests: XCTestCase {
    private static let opjCompress = "/opt/homebrew/bin/opj_compress"
    private static let opjDecompress = "/opt/homebrew/bin/opj_decompress"
    private static let lossless = DicomTransferSyntax.jpeg2000Part2MulticomponentLossless
    private static let general = DicomTransferSyntax.jpeg2000Part2Multicomponent

    // MARK: - Fixtures

    /// Correlated frames (each frame drifts from the previous one) with noise; signed values are centred on zero.
    private static func frames(count: Int, width: Int, height: Int, precision: Int, signed: Bool, seed: UInt32 = 2331) -> [[Int]] {
        var state = seed
        let limit = 1 << precision
        var previous = (0..<(width * height)).map { index -> Int in
            state = state &* 1_664_525 &+ 1_013_904_223
            let x = index % width, y = index / width
            return (x * limit / max(1, width) / 2 + y * limit / max(1, height) / 4 + Int(state >> 8) % max(1, limit / 8)) % limit
        }
        var all: [[Int]] = []
        for _ in 0..<count {
            let frame = previous.map { value -> Int in
                state = state &* 1_664_525 &+ 1_013_904_223
                let drift = Int(state >> 8) % max(2, limit / 32) - limit / 64
                return min(limit - 1, max(0, value + drift))
            }
            all.append(signed ? frame.map { $0 - limit / 2 } : frame)
            previous = signed ? frame : frame
        }
        return all
    }

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

    private static func samples(_ stored: Data, precision: Int, signed: Bool) -> [Int] {
        let bytes = [UInt8](stored)
        guard precision > 8 else { return bytes.map { signed ? Int(Int8(bitPattern: $0)) : Int($0) } }
        return stride(from: 0, to: bytes.count, by: 2).map {
            let word = UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
            return signed ? Int(Int16(bitPattern: word)) : Int(word)
        }
    }

    private static func descriptor(_ syntax: DicomTransferSyntax, width: Int, height: Int, precision: Int, signed: Bool) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(transferSyntaxUID: syntax.rawValue, rows: height, columns: width, bitsAllocated: precision > 8 ? 16 : 8,
                                       bitsStored: precision, highBit: precision - 1, pixelRepresentation: signed ? 1 : 0, samplesPerPixel: 1,
                                       photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
    }

    private static func file(frames: [Data], syntax: DicomTransferSyntax, width: Int, height: Int, precision: Int, signed: Bool,
                             emptyOffsetTable: Bool = true) throws -> Data {
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23310001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23310002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23310003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["PART2^CODEC"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["PART2-2331"])),
            DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(height)])),
            DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(width)])),
            DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([precision > 8 ? 16 : 8])),
            DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision)])),
            DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([UInt(precision - 1)])),
            DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([signed ? 1 : 0]))
        ]
        if syntax == .explicitVRLittleEndian {
            if frames.count > 1 { elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(frames.count)"]))) }
            elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: precision > 8 ? .OW : .OB,
                                             value: .bytes(frames.reduce(into: Data()) { $0.append($1) })))
        } else {
            // `frames` are collection codestreams here; the declared frame count is the sum of their components.
            let components = try frames.map { try DicomJ2KCodestreamInspector.inspect($0).components.count }.reduce(0, +)
            if components > 1 { elements.append(DicomDataElement(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings(["\(components)"]))) }
            elements.append(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB,
                                             value: .bytes(try DicomTranscoder.encapsulate(fragments: frames, emptyBasicOffsetTable: emptyOffsetTable).pixelData)))
        }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements), options: .init(transferSyntax: syntax))
    }

    private static func mainHeaderMarkers(_ codestream: Data) -> [(marker: UInt8, body: Data)] {
        var markers: [(UInt8, Data)] = []
        var cursor = 2
        while cursor + 4 <= codestream.count, codestream[cursor] == 0xFF, codestream[cursor + 1] != 0x90 {
            let length = Int(codestream[cursor + 2]) << 8 | Int(codestream[cursor + 3])
            markers.append((codestream[cursor + 1], codestream.subdata(in: (cursor + 4)..<min(codestream.count, cursor + 2 + length))))
            cursor += 2 + length
        }
        return markers
    }

    /// Removes the Annex J marker segments, the Part 2 capabilities and the SGcod value so a Part 1 decoder reads
    /// the coded components as they are.
    private static func strippedOfAnnexJ(_ codestream: Data) -> Data {
        var out = Data(codestream.prefix(2))
        var cursor = 2
        while cursor + 4 <= codestream.count, codestream[cursor] == 0xFF, codestream[cursor + 1] != 0x90 {
            let length = Int(codestream[cursor + 2]) << 8 | Int(codestream[cursor + 3])
            var segment = Data(codestream[cursor..<(cursor + 2 + length)])
            switch codestream[cursor + 1] {
            case 0x51: segment[4] = 0; segment[5] = 0
            case 0x52: segment[8] = 0
            case 0x75, 0x76, 0x77, 0x78: segment = Data()
            default: break
            }
            out.append(segment)
            cursor += 2 + length
        }
        out.append(Data(codestream[cursor..<codestream.count]))
        return out
    }

    private static func segment(_ marker: UInt8, _ body: [UInt8]) -> [UInt8] {
        [0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)] + body
    }

    private static func bigEndian32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }

    /// Inserts Annex J marker segments (T.801 layout) into a Part 1 codestream: CBD, MCT decorrelation (float32 or
    /// int32), MCT offsets (int32), one MCC collection (kind 1 array-based unless `wavelet`) and one MCO stage.
    private static func annexJ(_ codestream: Data, matrix: [Double], integerMatrix: Bool, offsets: [Int32], inputs: [Int], outputs: [Int],
                               outputDepth: Int, outputSigned: Bool, reversible: Bool, wavelet: Bool = false) -> Data {
        var out = Data(codestream.prefix(2))
        var cursor = 2
        var extra: [UInt8] = []
        let n = outputs.count
        extra += segment(0x78, [UInt8(n >> 8), UInt8(n & 0xFF)] + Array(repeating: UInt8((outputSigned ? 0x80 : 0) | (outputDepth - 1)), count: n))
        var mct: [UInt8] = [0, 0, 0, UInt8(1 | (1 << 8) >> 8 & 0)]  // placeholder, rebuilt below
        mct = [0, 0]
        let imct = 1 | (1 << 8) | ((integerMatrix ? 1 : 2) << 10)
        mct += [UInt8(imct >> 8), UInt8(imct & 0xFF), 0, 0]
        for value in matrix { mct += integerMatrix ? bigEndian32(UInt32(bitPattern: Int32(value))) : bigEndian32(Float(value).bitPattern) }
        extra += segment(0x75, mct)
        let iOffsets = 2 | (2 << 8) | (1 << 10)
        var offsetSegment: [UInt8] = [0, 0, UInt8(iOffsets >> 8), UInt8(iOffsets & 0xFF), 0, 0]
        for value in offsets { offsetSegment += bigEndian32(UInt32(bitPattern: value)) }
        extra += segment(0x75, offsetSegment)
        var mcc: [UInt8] = [0, 0, 1, 0, 0, 0, 1, wavelet ? 0 : 1, UInt8(inputs.count >> 8), UInt8(inputs.count & 0xFF)]
        mcc += inputs.map { UInt8($0) }
        mcc += [UInt8(outputs.count >> 8), UInt8(outputs.count & 0xFF)] + outputs.map { UInt8($0) }
        let tmcc = 1 | (2 << 8) | ((reversible ? 1 : 0) << 16)
        mcc += [UInt8((tmcc >> 16) & 0xFF), UInt8((tmcc >> 8) & 0xFF), UInt8(tmcc & 0xFF)]
        extra += segment(0x77, mcc)
        extra += segment(0x76, [1, 1])
        while cursor + 4 <= codestream.count, codestream[cursor] == 0xFF, codestream[cursor + 1] != 0x90 {
            let length = Int(codestream[cursor + 2]) << 8 | Int(codestream[cursor + 3])
            var segmentData = Data(codestream[cursor..<(cursor + 2 + length)])
            if codestream[cursor + 1] == 0x51 {
                let rsiz = (Int(segmentData[4]) << 8 | Int(segmentData[5])) | 0x8001
                segmentData[4] = UInt8(rsiz >> 8); segmentData[5] = UInt8(rsiz & 0xFF)
            }
            if codestream[cursor + 1] == 0x52 { segmentData[8] = 2 }
            out.append(segmentData)
            cursor += 2 + length
        }
        out.append(contentsOf: extra)
        out.append(Data(codestream[cursor..<codestream.count]))
        return out
    }

    // MARK: - External tools

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

    /// Encodes component planes (little-endian `.rawl`) with `opj_compress` as a plain multi-component Part 1 stream.
    private static func opjEncode(planes: [[Int]], width: Int, height: Int, precision: Int, signed: Bool, directory: URL, name: String) throws -> Data {
        let raw = directory.appendingPathComponent("\(name).rawl")
        var data = Data()
        for plane in planes { data.append(stored(plane, precision: precision)) }
        try data.write(to: raw)
        let out = directory.appendingPathComponent("\(name).j2k")
        let result = try run(opjCompress, ["-i", raw.path, "-o", out.path, "-F", "\(width),\(height),\(planes.count),\(precision),\(signed ? "s" : "u")",
                                           "-mct", "0", "-n", "3"])
        guard result.status == 0 else { throw XCTSkip("opj_compress failed: \(result.output.prefix(300))") }
        return try Data(contentsOf: out)
    }

    /// Decodes with `opj_decompress` into one PGX file per component (the raw writer refuses more than 16 bits and
    /// the coded components of a 16-bit collection are 17 bits wide): "PG ML ± depth width height" then big-endian
    /// samples of 1, 2 or 4 bytes.
    private static func opjDecode(_ codestream: Data, width: Int, height: Int, precision: Int, signed: Bool, directory: URL, name: String) throws -> [[Int]] {
        let input = directory.appendingPathComponent("\(name)-in.j2k")
        try codestream.write(to: input)
        let out = directory.appendingPathComponent("\(name)-out.pgx")
        let result = try run(opjDecompress, ["-i", input.path, "-o", out.path])
        guard result.status == 0 else { throw XCTSkip("opj_decompress failed: \(result.output.prefix(300))") }
        var planes: [[Int]] = []
        var component = 0
        while true {
            let url = directory.appendingPathComponent("\(name)-out_\(component).pgx")
            guard FileManager.default.fileExists(atPath: url.path) else { break }
            let bytes = [UInt8](try Data(contentsOf: url))
            guard let newline = bytes.firstIndex(of: 0x0A) else { throw XCTSkip("malformed PGX header") }
            let header = String(decoding: bytes[..<newline], as: UTF8.self).split(separator: " ")
            guard header.count >= 6, header[1] == "ML", let depth = Int(header[3]), let w = Int(header[4]), let h = Int(header[5]) else {
                throw XCTSkip("unexpected PGX header \(header)")
            }
            let isSigned = header[2] == "-"
            let bytesPerSample = depth <= 8 ? 1 : (depth <= 16 ? 2 : 4)
            var values: [Int] = []
            values.reserveCapacity(w * h)
            var cursor = newline + 1
            for _ in 0..<(w * h) {
                var word: UInt32 = 0
                for _ in 0..<bytesPerSample { word = word << 8 | UInt32(bytes[cursor]); cursor += 1 }
                let value: Int
                switch bytesPerSample {
                case 1: value = isSigned ? Int(Int8(bitPattern: UInt8(word))) : Int(word)
                case 2: value = isSigned ? Int(Int16(bitPattern: UInt16(word))) : Int(word)
                default: value = isSigned ? Int(Int32(bitPattern: word)) : Int(word)
                }
                values.append(value)
            }
            XCTAssertEqual(w, width); XCTAssertEqual(h, height); XCTAssertEqual(depth, precision); XCTAssertEqual(isSigned, signed)
            planes.append(values)
            component += 1
        }
        guard !planes.isEmpty else { throw XCTSkip("opj_decompress wrote no PGX component") }
        return planes
    }

    /// The synchronous reader API (the async overload wins inside async tests).
    private static func syncFrame(_ reader: DicomDecodedFrameReader, _ index: Int) throws -> DicomDecodedFrame {
        try reader.frame(at: index)
    }

    private static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Own collections

    func test_ownCollectionsCarryTheAnnexJMarkersAndTheirCodedComponentsMatchOpenJPEG() async throws {
        guard Self.opjAvailable() else { throw XCTSkip("OpenJPEG CLI tools are not installed at /opt/homebrew/bin") }
        let directory = try Self.temporaryDirectory("part2-own")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 52, height = 40
        for (precision, signed, count) in [(8, false, 3), (12, true, 5), (16, false, 4), (16, true, 2)] {
            let label = "\(precision)-bit \(signed ? "signed" : "unsigned") ×\(count)"
            let frames = Self.frames(count: count, width: width, height: height, precision: precision, signed: signed)
            let stored = frames.map { Self.stored($0, precision: precision) }
            for syntax in [Self.lossless, Self.general] {
                let descriptor = Self.descriptor(syntax, width: width, height: height, precision: precision, signed: signed)
                let codestream = try await DicomJ2KSwiftBackend().encodeCollection(frames: stored, descriptor: descriptor,
                                                                                    targetTransferSyntaxUID: syntax.rawValue, intent: .reversible)
                let inspection = try DicomJ2KCodestreamInspector.inspect(codestream)
                XCTAssertTrue(inspection.usesPart2Extensions, label)
                XCTAssertEqual(inspection.capabilities & 0x7FFF, 0x0001, "\(label): only the Annex J extension bit")
                XCTAssertEqual(inspection.multipleComponentTransformValue, 2, "\(label): T.801 Table A.8")
                XCTAssertEqual(inspection.components.count, count, label)
                XCTAssertTrue(inspection.components.allSatisfy { $0.isSigned && $0.precision == precision + 1 }, "\(label): coded components are signed and one bit wider")
                let annexJ = try XCTUnwrap(inspection.annexJ, label)
                XCTAssertEqual(annexJ.stageCount, 1, label)
                XCTAssertEqual(annexJ.arrayBasedCollections, 1, label)
                XCTAssertEqual(annexJ.reversibleCollections, 1, label)
                XCTAssertEqual(annexJ.decorrelationArrays, 1, label)
                XCTAssertEqual(annexJ.offsetArrays, 1, label)
                XCTAssertEqual(annexJ.outputComponents?.map(\.precision), Array(repeating: precision, count: count), label)
                XCTAssertEqual(annexJ.outputComponents?.map(\.isSigned), Array(repeating: signed, count: count), label)
                XCTAssertNil(DicomJ2KPart2Profile.violation(of: syntax.rawValue, in: inspection), label)
                XCTAssertNil(DicomJ2KPart2Profile.unsupportedReason(inspection), label)
                // Own decode restores every frame.
                let decoded = try await DicomJ2KSwiftBackend().decodeCollection(codestream, transferSyntaxUID: syntax.rawValue)
                XCTAssertEqual(decoded.frames, stored, "\(label): own decode")
                XCTAssertEqual(decoded.bitsPerSample, precision, label)
                XCTAssertEqual(decoded.isSigned, signed, label)
                // OpenJPEG decodes the coded components once the Annex J signalling is stripped; they must equal the
                // forward difference transformation of the level-shifted frames (a Part 2 decoder undoes it with the
                // cumulative-sum matrix carried in the MCT segment).
                let coded = try Self.opjDecode(Self.strippedOfAnnexJ(codestream), width: width, height: height, precision: precision + 1, signed: true,
                                               directory: directory, name: "coded-\(precision)-\(signed)-\(syntax.rawValue.suffix(2))")
                let shift = signed ? 0 : 1 << (precision - 1)
                for component in 0..<count {
                    let expected = (0..<(width * height)).map { index in
                        (frames[component][index] - shift) - (component == 0 ? 0 : frames[component - 1][index] - shift)
                    }
                    XCTAssertEqual(coded[component], expected, "\(label): coded component \(component) is the forward transformation")
                }
            }
        }
    }

    func test_handBuiltAnnexJStreamsDecodeExactlyIncludingPermutedCollectionsAndFloatMatrices() async throws {
        guard Self.opjAvailable() else { throw XCTSkip("OpenJPEG CLI tools are not installed at /opt/homebrew/bin") }
        let directory = try Self.temporaryDirectory("part2-built")
        defer { try? FileManager.default.removeItem(at: directory) }
        // opj_compress rejects raw geometries whose width & height & components & depth is non-zero (a bitwise-AND check).
        let width = 48, height = 33, precision = 12, count = 3
        let frames = Self.frames(count: count, width: width, height: height, precision: precision, signed: false, seed: 9)
        let shift = 1 << (precision - 1)
        // Reversible integer stream: y0 = x0', y1 = x1' - x0', y2 = x2' - x1' (x' level-shifted); decoding matrix = cumulative sums.
        let differences = (0..<count).map { component in
            (0..<(width * height)).map { index in (frames[component][index] - shift) - (component == 0 ? 0 : frames[component - 1][index] - shift) }
        }
        let coded = try Self.opjEncode(planes: differences, width: width, height: height, precision: precision + 1, signed: true, directory: directory, name: "diff")
        let cumulative: [Double] = [1, 0, 0, 1, 1, 0, 1, 1, 1]
        let built = Self.annexJ(coded, matrix: cumulative, integerMatrix: true, offsets: Array(repeating: Int32(shift), count: count),
                                inputs: [0, 1, 2], outputs: [0, 1, 2], outputDepth: precision, outputSigned: false, reversible: true)
        let decoded = try await DicomJ2KSwiftBackend().decodeCollection(built, transferSyntaxUID: Self.lossless.rawValue)
        XCTAssertEqual(decoded.frames, frames.map { Self.stored($0, precision: precision) }, "integer decorrelation")
        // The same collection with permuted outputs: output component 2 receives row 0 and so on.
        let permuted = Self.annexJ(coded, matrix: cumulative, integerMatrix: true, offsets: Array(repeating: Int32(shift), count: count),
                                   inputs: [0, 1, 2], outputs: [2, 1, 0], outputDepth: precision, outputSigned: false, reversible: true)
        let permutedDecode = try await DicomJ2KSwiftBackend().decodeCollection(permuted, transferSyntaxUID: Self.lossless.rawValue)
        XCTAssertEqual(permutedDecode.frames, frames.reversed().map { Self.stored($0, precision: precision) }, "permuted outputs")
        // Irreversible float matrix under the general syntax: a 3×3 orthonormal-ish mix, decoded within rounding.
        let forward: [Double] = [0.5, 0.5, 0, -0.5, 0.5, 0, 0, 0, 1]
        let inverse: [Double] = [1, -1, 0, 1, 1, 0, 0, 0, 1]
        let mixed = (0..<count).map { row in
            (0..<(width * height)).map { index -> Int in
                let value = (0..<count).reduce(0.0) { $0 + forward[row * count + $1] * Double(frames[$1][index] - shift) }
                return Int(value.rounded())
            }
        }
        let codedMixed = try Self.opjEncode(planes: mixed, width: width, height: height, precision: precision + 1, signed: true, directory: directory, name: "mixed")
        let floatBuilt = Self.annexJ(codedMixed, matrix: inverse, integerMatrix: false, offsets: Array(repeating: Int32(shift), count: count),
                                     inputs: [0, 1, 2], outputs: [0, 1, 2], outputDepth: precision, outputSigned: false, reversible: false)
        let floatDecode = try await DicomJ2KSwiftBackend().decodeCollection(floatBuilt, transferSyntaxUID: Self.general.rawValue)
        for component in 0..<count {
            let got = Self.samples(floatDecode.frames[component], precision: precision, signed: false)
            XCTAssertLessThanOrEqual(zip(got, frames[component]).map { abs($0 - $1) }.max() ?? 0, 1, "float matrix component \(component) within rounding")
        }
        // The general syntax accepts the reversible stream; the lossless-only syntax refuses the irreversible one.
        _ = try await DicomJ2KSwiftBackend().decodeCollection(built, transferSyntaxUID: Self.general.rawValue)
        do {
            _ = try await DicomJ2KSwiftBackend().decodeCollection(floatBuilt, transferSyntaxUID: Self.lossless.rawValue)
            XCTFail("an irreversible collection must be refused under the lossless-only syntax")
        } catch let error as DicomJ2KSwiftBackendError {
            guard case .metadataMismatch(_, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("reversible"), reason)
        }
    }

    // MARK: - DICOM layer

    func test_transcoderWritesCollectionsThatTheReaderValidatorAndVolumeDocumentMapBackToFrames() async throws {
        let width = 48, height = 36, precision = 12, count = 70  // two collections: 64 + 6 frames
        let frames = Self.frames(count: count, width: width, height: height, precision: precision, signed: true, seed: 17)
        let stored = frames.map { Self.stored($0, precision: precision) }
        let native = try Self.file(frames: stored, syntax: .explicitVRLittleEndian, width: width, height: height, precision: precision, signed: true)
        let transcoder = DicomTranscoder()
        let plan = try transcoder.plan(native, to: Self.lossless)
        XCTAssertEqual(plan.kind, .encode)
        XCTAssertTrue(plan.steps.contains(.encodeFrames(frames: count, codec: "jpeg-2000-part2")), "\(plan.steps)")
        XCTAssertTrue(plan.steps.contains(.encapsulate(offsetTables: .emptyBasic)), "\(plan.steps)")
        let compressed = try await transcoder.transcode(native, to: Self.lossless, intent: .reversible)
        let decoder = try DCMDecoder(data: compressed)
        XCTAssertEqual(decoder.info(for: .transferSyntaxUID), Self.lossless.rawValue)
        XCTAssertEqual(decoder.nImages, count)
        let descriptor = try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor)
        XCTAssertEqual(descriptor.fragments.count, 2, "one fragment per component collection")
        XCTAssertTrue(descriptor.basicOffsetTable.offsets.isEmpty, "the fragments are collections, not frames: empty Basic Offset Table")
        let bytes = decoder.dicomDataSnapshot()
        let collections = descriptor.fragments.map { bytes.subdata(in: $0.valueRange) }
        XCTAssertEqual(try collections.map { try DicomJ2KCodestreamInspector.inspect($0).components.count }, [64, 6])
        for collection in collections { XCTAssertNil(DicomJ2KPart2Profile.violation(of: Self.lossless.rawValue, in: try DicomJ2KCodestreamInspector.inspect(collection))) }
        XCTAssertEqual(DicomDecodedFrameReader(decoder: decoder).frameCount, count)
        // Sync and async reads map frames through both collections (the cache decodes each collection once).
        let reader = DicomDecodedFrameReader(decoder: decoder)
        for index in [0, 1, 63, 64, 69] {
            guard case .gray16(let sync) = try Self.syncFrame(reader, index).pixels else { return XCTFail("expected 16-bit output") }
            XCTAssertEqual(sync.map(Int.init), frames[index].map { $0 + 32768 }, "sync frame \(index)")
            let execution = try await reader.frameExecution(at: index)
            guard case .gray16(let async) = execution.frame.pixels else { return XCTFail("expected 16-bit output") }
            XCTAssertEqual(async.map(Int.init), frames[index].map { $0 + 32768 }, "async frame \(index)")
            XCTAssertEqual(execution.backendIdentifier, "j2kswift-cpu")
            XCTAssertEqual(execution.rolloutMode, "preferred")
        }
        XCTAssertThrowsError(try Self.syncFrame(reader, count)) { error in
            guard case DicomDecodedFrameReader.ReadError.frameIndexOutOfRange = error else { return XCTFail("\(error)") }
        }
        // Partial decode is not offered for collections (an Annex J stage needs every component).
        let capabilities = try await reader.partialDecodeCapabilities(at: 0)
        XCTAssertEqual(capabilities, .unavailable)
        // The validator accepts the object (no profile mismatch, frame count matches the components).
        let report = try DicomInstanceValidator.validate(compressed)
        XCTAssertFalse(report.diagnostics.contains { [.codestreamProfileMismatch, .pixelMetadataContradiction, .invalidDataSetStructure].contains($0.code) },
                       "\(report.diagnostics.map(\.code))")
        let limitedReport = try DicomInstanceValidator.validate(compressed, limits: .init(maximumFrames: 65))
        XCTAssertTrue(limitedReport.diagnostics.contains { $0.code == .evaluationLimitReached },
                      "two collections still contain 70 frames and exceed a 65-frame budget")
        // Back to native: exact; rewrap .92 → .93 copies the collections; .93 irreversible re-encodes with loss provenance.
        let roundTrip = try DCMDecoder(data: try transcoder.transcode(compressed, to: .explicitVRLittleEndian))
        XCTAssertEqual(roundTrip.getAllFrames()?.map(\.data), stored)
        let rewrap = try transcoder.plan(compressed, to: Self.general)
        XCTAssertEqual(rewrap.kind, .rewrap)
        let general = try DCMDecoder(data: try await transcoder.transcode(compressed, to: Self.general, intent: .reversible))
        XCTAssertEqual(general.info(for: .transferSyntaxUID), Self.general.rawValue)
        XCTAssertEqual(general.encapsulatedPixelDataDescriptor?.fragments.count, 2)
        let generalObject = try await transcoder.transcode(compressed, to: Self.general, intent: .reversible)
        XCTAssertEqual(try DCMDecoder(data: try transcoder.transcode(generalObject, to: .explicitVRLittleEndian)).getAllFrames()?.map(\.data), stored)
        let lossy = try DCMDecoder(data: try await transcoder.transcode(native, to: Self.general, intent: .irreversible(quality: 0.9)))
        XCTAssertEqual(lossy.info(for: .lossyImageCompression), "01")
        XCTAssertNotEqual(lossy.info(for: .sopInstanceUID), "2.25.23310001")
        let lossyReader = DicomDecodedFrameReader(decoder: lossy)
        guard case .gray16(let lossyPixels) = try Self.syncFrame(lossyReader, 5).pixels else { return XCTFail("expected 16-bit output") }
        XCTAssertLessThanOrEqual(zip(lossyPixels.map { Int($0) - 32768 }, frames[5]).map { abs($0 - $1) }.max() ?? 0, 4096 / 16)
        // The volume document uses the own codec: slices in frame order.
        let document = try DicomJP3DVolumeDocument(decoder: decoder)
        XCTAssertEqual(document.fragments.count, 2)
        let volume = try document.decodedVolume()
        XCTAssertEqual(volume.depth, count)
        XCTAssertEqual(volume.voxels, stored.reduce(into: Data()) { $0.append($1) })
    }

    func test_syntaxRulesRefuseWrongCapabilitiesIntentsAndUnsupportedTransformsTyped() async throws {
        guard Self.opjAvailable() else { throw XCTSkip("OpenJPEG CLI tools are not installed at /opt/homebrew/bin") }
        let directory = try Self.temporaryDirectory("part2-rules")
        defer { try? FileManager.default.removeItem(at: directory) }
        let width = 40, height = 30, precision = 12
        let frames = Self.frames(count: 3, width: width, height: height, precision: precision, signed: false, seed: 4)
        let stored = frames.map { Self.stored($0, precision: precision) }
        let backend = DicomJ2KSwiftBackend()
        let descriptor = Self.descriptor(Self.lossless, width: width, height: height, precision: precision, signed: false)
        // Intent: the lossless-only syntax refuses irreversible encodes; colour frames are refused.
        do {
            _ = try await backend.encodeCollection(frames: stored, descriptor: descriptor, targetTransferSyntaxUID: Self.lossless.rawValue,
                                                   intent: .irreversible(quality: 0.9))
            XCTFail(".92 must refuse irreversible intent")
        } catch let error as DicomJ2KSwiftBackendError {
            guard case .unsupportedShape = error else { return XCTFail("\(error)") }
        }
        let encodeDecision = DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .encode, descriptor: descriptor, intent: .irreversible(quality: 0.5)))
        XCTAssertFalse(encodeDecision.canExecute)
        XCTAssertEqual(encodeDecision.reasonCode, .intentUnsupported)
        let colour = DicomCompressedFrameDescriptor(transferSyntaxUID: Self.general.rawValue, rows: 8, columns: 8, bitsAllocated: 8, bitsStored: 8, highBit: 7,
                                                    pixelRepresentation: 0, samplesPerPixel: 3, photometricInterpretation: "RGB", planarConfiguration: 0)
        XCTAssertFalse(DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .encode, descriptor: colour)).canExecute)
        // Decisions: experimental on the own backend, test-only when forced, refused when disabled, no partial decode.
        let decode = DicomCodecCapabilityRequest(operation: .decode, descriptor: descriptor)
        let preferred = DicomCodecCapabilities.resolve(decode, environment: [:])
        XCTAssertTrue(preferred.canExecute)
        XCTAssertEqual(preferred.backendIdentifier, "j2kswift-cpu")
        XCTAssertEqual(preferred.qualification, .experimental)
        XCTAssertEqual(DicomCodecCapabilities.resolve(decode, environment: ["DICOM_J2KSWIFT_MODE": "forced-for-tests"]).qualification, .testOnly)
        let disabled = DicomCodecCapabilities.resolve(decode, environment: ["DICOM_J2KSWIFT_MODE": "disabled"])
        XCTAssertFalse(disabled.canExecute)
        XCTAssertEqual(disabled.reasonCode, .profileForbidden)
        let partial = DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .decode, descriptor: descriptor,
                                                                                 partialDecode: DicomCodecPartialDecodeRequest(resolutionLevel: 1)))
        XCTAssertEqual(partial.reasonCode, .partialUnsupported)
        // Capabilities: a Part 1 codestream under .92, a Part 2 collection under .90, Annex G under .92.
        let collection = try await backend.encodeCollection(frames: stored, descriptor: descriptor, targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible)
        let part1 = try Self.opjEncode(planes: frames, width: width, height: height, precision: precision, signed: false, directory: directory, name: "plain")
        let part1Inspection = try DicomJ2KCodestreamInspector.inspect(part1)
        XCTAssertEqual(DicomJ2KPart2Profile.violation(of: Self.lossless.rawValue, in: part1Inspection),
                       "the codestream does not declare ISO/IEC 15444-2 capabilities (Rsiz bit 15)")
        XCTAssertEqual(DicomHTJ2KProfile.violation(of: DicomTransferSyntax.jpeg2000Lossless.rawValue, in: collection),
                       "the codestream uses ISO/IEC 15444-2 extensions, which the Part 1 and Part 15 syntaxes do not permit")
        let frameDecision = DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .decode, descriptor: descriptor, frameData: part1))
        XCTAssertEqual(frameDecision.reasonCode, .unqualifiedProfile)
        // A plain multi-component Part 1 stream still decodes as frames (identity), while the validator flags it.
        let plainDecode = try await backend.decodeCollection(part1, transferSyntaxUID: Self.lossless.rawValue)
        XCTAssertEqual(plainDecode.frames, stored, "plain multi-component collection decodes leniently")
        let plainFile = try Self.file(frames: [part1], syntax: Self.lossless, width: width, height: height, precision: precision, signed: false)
        XCTAssertTrue(try DicomInstanceValidator.validate(plainFile).diagnostics.contains { $0.code == .codestreamProfileMismatch })
        let conformantFile = try Self.file(frames: [collection], syntax: Self.lossless, width: width, height: height, precision: precision, signed: false)
        XCTAssertFalse(try DicomInstanceValidator.validate(conformantFile).diagnostics.contains { $0.code == .codestreamProfileMismatch })
        // Unsupported transformations are refused typed: a wavelet-based collection and a dependency array.
        let shift = 1 << (precision - 1)
        let differences = (0..<3).map { c in (0..<(width * height)).map { i in (frames[c][i] - shift) - (c == 0 ? 0 : frames[c - 1][i] - shift) } }
        let coded = try Self.opjEncode(planes: differences, width: width, height: height, precision: precision + 1, signed: true, directory: directory, name: "diff")
        let wavelet = Self.annexJ(coded, matrix: [1, 0, 0, 1, 1, 0, 1, 1, 1], integerMatrix: true, offsets: [Int32(shift), Int32(shift), Int32(shift)],
                                  inputs: [0, 1, 2], outputs: [0, 1, 2], outputDepth: precision, outputSigned: false, reversible: true, wavelet: true)
        do {
            _ = try await backend.decodeCollection(wavelet, transferSyntaxUID: Self.lossless.rawValue)
            XCTFail("wavelet-based collections are not implemented")
        } catch let error as DicomJ2KSwiftBackendError {
            guard case .unsupportedShape(_, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("wavelet-based"), reason)
        }
        let waveletFile = try Self.file(frames: [wavelet], syntax: Self.lossless, width: width, height: height, precision: precision, signed: false)
        let waveletReport = try DicomInstanceValidator.validate(waveletFile)
        XCTAssertTrue(waveletReport.diagnostics.contains { $0.code == .codestreamRuleUnavailable }, "\(waveletReport.diagnostics.map(\.code))")
        XCTAssertFalse(waveletReport.diagnostics.contains { $0.code == .codestreamProfileMismatch }, "PS3.5 permits wavelet-based collections")
        // Malformed markers fail typed: a singular matrix, a missing array, a wrong CBD count, a truncated collection.
        let singular = Self.annexJ(coded, matrix: [1, 1, 0, 1, 1, 0, 0, 0, 1], integerMatrix: true, offsets: [Int32(shift), Int32(shift), Int32(shift)],
                                   inputs: [0, 1, 2], outputs: [0, 1, 2], outputDepth: precision, outputSigned: false, reversible: true)
        _ = try await backend.decodeCollection(singular, transferSyntaxUID: Self.lossless.rawValue)  // decodable: the decoder applies the matrix as given
        var missingArray = Self.annexJ(coded, matrix: [1, 0, 0, 1, 1, 0, 1, 1, 1], integerMatrix: true, offsets: [Int32(shift), Int32(shift), Int32(shift)],
                                       inputs: [0, 1, 2], outputs: [0, 1, 2], outputDepth: precision, outputSigned: false, reversible: true)
        let mccRange = try XCTUnwrap(missingArray.range(of: Data([0xFF, 0x77])))
        missingArray[mccRange.lowerBound + 4 + 7 + 1 + 2 + 3 + 2 + 3 + 2] = 7  // Tmcc low byte: decorrelation array 7 is undefined
        for (name, stream) in [("missing array", missingArray), ("truncated", collection.prefix(collection.count / 2)), ("garbage", Data([0xFF, 0x4F, 0xFF, 0x51, 0, 4]))] {
            do {
                _ = try await backend.decodeCollection(stream, transferSyntaxUID: Self.lossless.rawValue)
                XCTFail("\(name) must fail")
            } catch is DicomJ2KSwiftBackendError {
            } catch is J2KError {
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
        // A wrong Number of Frames is a typed encapsulation error through the reader.
        var mismatch = try Self.file(frames: [collection], syntax: Self.lossless, width: width, height: height, precision: precision, signed: false)
        let framesTag = try XCTUnwrap(mismatch.range(of: Data("3 ".utf8)))
        mismatch.replaceSubrange(framesTag, with: Data("4 ".utf8))
        XCTAssertThrowsError(try Self.syncFrame(DicomDecodedFrameReader(decoder: DCMDecoder(data: mismatch)), 0)) { error in
            guard case DicomDecodedFrameReader.ReadError.unusableEncapsulation(let diagnostics) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(diagnostics.joined().contains("4 frame"), "\(diagnostics)")
        }
        // Disabled rollout: the reader refuses typed instead of guessing.
        let file = try Self.file(frames: [collection], syntax: Self.lossless, width: width, height: height, precision: precision, signed: false)
        let disabledReader = DicomDecodedFrameReader(decoder: try DCMDecoder(data: file))
        do {
            _ = try await disabledReader.frameExecution(at: 0, environment: ["DICOM_J2KSWIFT_MODE": "disabled"])
            XCTFail("disabled rollout must refuse")
        } catch let error as DicomDecodedFrameReader.ReadError {
            guard case .unsupportedTransferSyntax = error else { return XCTFail("\(error)") }
        }
    }

    func test_collectionLimitsAreTyped() async throws {
        let descriptor = Self.descriptor(Self.lossless, width: 4, height: 4, precision: 8, signed: false)
        let backend = DicomJ2KSwiftBackend()
        do {
            _ = try await backend.encodeCollection(frames: [], descriptor: descriptor, targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible)
            XCTFail("an empty collection must be refused")
        } catch let error as DicomJ2KSwiftBackendError {
            guard case .unsupportedShape = error else { return XCTFail("\(error)") }
        }
        do {
            _ = try await backend.encodeCollection(frames: [Data(count: 15)], descriptor: descriptor, targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible)
            XCTFail("a short frame must be refused")
        } catch let error as DicomJ2KSwiftBackendError {
            guard case .unsupportedShape(_, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("15 bytes"), reason)
        }
        XCTAssertEqual(DicomJ2KPart2Profile.framesPerCollection, 64)
        XCTAssertGreaterThanOrEqual(DicomJ2KPart2Profile.maximumCollectionComponents, 64)
        XCTAssertEqual(try DicomJ2KPart2Profile.differenceMatrix(count: 3).coefficients, [1, 0, 0, -1, 1, 0, 0, -1, 1])
        XCTAssertEqual(try DicomJ2KPart2Profile.differenceMatrix(count: 3).inverse().coefficients.map { $0.rounded() }, [1, 0, 0, 1, 1, 0, 1, 1, 1])
    }
}
