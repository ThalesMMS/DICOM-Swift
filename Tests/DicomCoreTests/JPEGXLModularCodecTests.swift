import DicomData
@testable import DicomCore
@testable import DicomJPEGXL
import Foundation
import XCTest

/// JPEG XL Modular lossless (ISO/IEC 18181-1 Annex C) on the own DicomJPEGXL
/// core, issue #2332: cross-checked against libjxl (`cjxl`/`djxl`) in both
/// directions over bit depths, signedness, colour, group layouts, odd sizes,
/// ICC profiles, and refused typed on truncation, decompression bombs,
/// transform corruption and inadmissible DICOM shapes.
final class JPEGXLModularCodecTests: XCTestCase {
    private static let lossless = DicomTransferSyntax.jpegXLLossless
    private static let general = DicomTransferSyntax.jpegXL
    private static let experimental = ["DICOM_JXLSWIFT_MODE": "experimental"]

    // MARK: - Fixtures

    /// Smooth clinical-looking samples with noise; signed values are centred on zero.
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

    /// Interleaved little-endian stored bytes for `bitsAllocated` 8 or 16.
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

    private static func descriptor(
        _ syntax: DicomTransferSyntax, width: Int, height: Int, precision: Int, signed: Bool,
        channels: Int = 1, bitsAllocated: Int? = nil, photometric: String? = nil
    ) -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(
            transferSyntaxUID: syntax.rawValue, rows: height, columns: width,
            bitsAllocated: bitsAllocated ?? (precision > 8 ? 16 : 8),
            bitsStored: precision, highBit: precision - 1, pixelRepresentation: signed ? 1 : 0,
            samplesPerPixel: channels,
            photometricInterpretation: photometric ?? (channels == 3 ? "RGB" : "MONOCHROME2"),
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
        frames: [Data], syntax: DicomTransferSyntax, width: Int, height: Int, precision: Int, signed: Bool,
        channels: Int = 1, icc: Data? = nil
    ) throws -> Data {
        var elements: [DicomDataElement] = [
            DicomDataElement(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23320001"])),
            DicomDataElement(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23320002"])),
            DicomDataElement(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23320003"])),
            DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["OT"])),
            DicomDataElement(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["JPEGXL^CODEC"])),
            DicomDataElement(tag: DicomTag.patientID.rawValue, vr: .LO, value: .strings(["JXL-2332"])),
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
        if let icc {
            elements.append(DicomDataElement(tag: DicomTag.iccProfile.rawValue, vr: .OB, value: .bytes(icc)))
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

    // MARK: - External tools

    private func requireExecutable(_ name: String) throws -> String {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = (pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin"])
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("Required interoperability tool \(name) is unavailable")
        }
        return executable
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let standardError = Pipe()
        process.standardError = standardError
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let diagnostic = String(data: standardError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return (process.terminationStatus, diagnostic)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jxl-2332-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// PGM/PPM (maxval up to 65535, big-endian samples) of unsigned planes.
    private static func pnm(_ planes: [[Int32]], width: Int, height: Int, precision: Int) -> Data {
        var data = Data("\(planes.count == 3 ? "P6" : "P5")\n\(width) \(height)\n\((1 << precision) - 1)\n".utf8)
        for i in 0..<(width * height) {
            for plane in planes {
                let v = plane[i]
                if precision > 8 { data.append(UInt8(v >> 8)) }
                data.append(UInt8(v & 0xFF))
            }
        }
        return data
    }

    private static func parsePNM(_ d: Data) throws -> (width: Int, height: Int, maxval: Int, planes: [[Int32]]) {
        var fields: [Int] = []
        var i = d.startIndex
        var magic = ""
        while fields.count < 3 {
            while i < d.endIndex, d[i] == 0x20 || d[i] == 0x0A || d[i] == 0x0D || d[i] == 0x09 { i += 1 }
            var token = ""
            while i < d.endIndex, !(d[i] == 0x20 || d[i] == 0x0A || d[i] == 0x0D || d[i] == 0x09) {
                token.append(Character(UnicodeScalar(d[i]))); i += 1
            }
            if magic.isEmpty { magic = token } else { fields.append(try XCTUnwrap(Int(token))) }
        }
        i += 1
        let channels = magic == "P6" ? 3 : 1
        let count = fields[0] * fields[1]
        var planes = [[Int32]](repeating: [Int32](repeating: 0, count: count), count: channels)
        let body = Array(d[i...])
        var cursor = 0
        for p in 0..<count {
            for c in 0..<channels {
                if fields[2] > 255 {
                    planes[c][p] = Int32(body[cursor]) << 8 | Int32(body[cursor + 1]); cursor += 2
                } else {
                    planes[c][p] = Int32(body[cursor]); cursor += 1
                }
            }
        }
        return (fields[0], fields[1], fields[2], planes)
    }

    /// Minimal PNG (8/16-bit gray or RGB, stored deflate blocks) with an iCCP chunk.
    private static func png(_ planes: [[Int32]], width: Int, height: Int, precision: Int, icc: Data) -> Data {
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in bytes {
                c ^= UInt32(b)
                for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
            }
            return c ^ 0xFFFF_FFFF
        }
        func adler32(_ bytes: [UInt8]) -> UInt32 {
            var a: UInt32 = 1, b: UInt32 = 0
            for x in bytes { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
            return (b << 16) | a
        }
        func zlibStored(_ payload: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [0x78, 0x01]
            var offset = 0
            repeat {
                let n = min(65535, payload.count - offset)
                let last: UInt8 = offset + n >= payload.count ? 1 : 0
                out.append(last)
                out.append(UInt8(n & 0xFF)); out.append(UInt8(n >> 8))
                out.append(UInt8(~n & 0xFF)); out.append(UInt8((~n >> 8) & 0xFF))
                out.append(contentsOf: payload[offset..<(offset + n)])
                offset += n
            } while offset < payload.count
            let a = adler32(payload)
            out.append(contentsOf: [UInt8(a >> 24), UInt8((a >> 16) & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)])
            return out
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let t = Array(type.utf8)
            let n = UInt32(body.count)
            var out: [UInt8] = [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            out += t + body
            let c = crc32(t + body)
            out += [UInt8(c >> 24), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
            return out
        }
        let depth: UInt8 = precision > 8 ? 16 : 8
        let colourType: UInt8 = planes.count == 3 ? 2 : 0
        var ihdr: [UInt8] = []
        for v in [UInt32(width), UInt32(height)] { ihdr += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        ihdr += [depth, colourType, 0, 0, 0]
        var raw: [UInt8] = []
        for y in 0..<height {
            raw.append(0)
            for x in 0..<width {
                for plane in planes {
                    let v = plane[y * width + x]
                    if depth == 16 { raw.append(UInt8(v >> 8)) }
                    raw.append(UInt8(v & 0xFF))
                }
            }
        }
        var out: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        out += chunk("IHDR", ihdr)
        out += chunk("iCCP", Array("dicom".utf8) + [0, 0] + zlibStored(Array(icc)))
        out += chunk("IDAT", zlibStored(raw))
        out += chunk("IEND", [])
        return Data(out)
    }

    /// The ICC profile inside a PNG's iCCP chunk (zlib-inflated).
    private static func pngICC(_ data: Data) throws -> Data? {
        var cursor = 8
        let bytes = Array(data)
        while cursor + 8 <= bytes.count {
            let n = Int(bytes[cursor]) << 24 | Int(bytes[cursor + 1]) << 16 | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
            let type = String(decoding: bytes[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            let body = Array(bytes[(cursor + 8)..<(cursor + 8 + n)])
            if type == "iCCP" {
                guard let zero = body.firstIndex(of: 0) else { return nil }
                // zlib stream: 2-byte header, raw deflate, 4-byte Adler-32.
                let compressed = Data(body[(zero + 4)..<(body.count - 4)])
                return try (compressed as NSData).decompressed(using: .zlib) as Data
            }
            cursor += 12 + n
        }
        return nil
    }

    private static func systemICC(_ name: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/\(name)"))
    }

    // MARK: - libjxl streams decoded by the own core

    func test_cjxlStreamsDecodeExactlyThroughTheBackend() async throws {
        let cjxl = try requireExecutable("cjxl")
        let dir = try temporaryDirectory()
        let backend = DicomJXLSwiftBackend()
        struct Case { let name: String; let width: Int; let height: Int; let precision: Int; let signed: Bool; let channels: Int; let flags: [String] }
        let cases = [
            Case(name: "gray8", width: 53, height: 37, precision: 8, signed: false, channels: 1, flags: ["-e", "7"]),
            Case(name: "gray10", width: 53, height: 37, precision: 10, signed: false, channels: 1, flags: ["-e", "7"]),
            Case(name: "gray12", width: 301, height: 277, precision: 12, signed: false, channels: 1, flags: ["-e", "7"]),
            Case(name: "gray12-e9", width: 300, height: 271, precision: 12, signed: false, channels: 1, flags: ["-e", "9"]),
            Case(name: "gray12-e1", width: 300, height: 271, precision: 12, signed: false, channels: 1, flags: ["-e", "1"]),
            Case(name: "gray12-groups", width: 600, height: 520, precision: 12, signed: false, channels: 1, flags: ["-e", "7", "-g", "1"]),
            Case(name: "gray12-squeeze", width: 300, height: 271, precision: 12, signed: false, channels: 1, flags: ["-e", "7", "-R", "1"]),
            Case(name: "gray12-progressive", width: 600, height: 520, precision: 12, signed: false, channels: 1, flags: ["-e", "7", "-p"]),
            Case(name: "gray16", width: 513, height: 257, precision: 16, signed: false, channels: 1, flags: ["-e", "7"]),
            Case(name: "gray12-signed", width: 300, height: 271, precision: 12, signed: true, channels: 1, flags: ["-e", "7"]),
            Case(name: "gray16-signed", width: 300, height: 271, precision: 16, signed: true, channels: 1, flags: ["-e", "7"]),
            Case(name: "gray8-palette", width: 300, height: 271, precision: 8, signed: false, channels: 1, flags: ["-e", "7", "-X", "64"]),
            Case(name: "rgb8", width: 300, height: 271, precision: 8, signed: false, channels: 3, flags: ["-e", "7"]),
            Case(name: "rgb8-rct", width: 200, height: 150, precision: 8, signed: false, channels: 3, flags: ["-e", "7", "-C", "13"]),
            Case(name: "rgb16", width: 277, height: 301, precision: 16, signed: false, channels: 3, flags: ["-e", "7"]),
            Case(name: "rgb12", width: 200, height: 150, precision: 12, signed: false, channels: 3, flags: ["-e", "5"]),
            Case(name: "gray1", width: 53, height: 37, precision: 1, signed: false, channels: 1, flags: ["-e", "7"]),
            Case(name: "gray4", width: 53, height: 37, precision: 4, signed: false, channels: 1, flags: ["-e", "7"])
        ]
        for c in cases {
            var planes = Self.samples(width: c.width, height: c.height, precision: c.precision, signed: c.signed, seed: UInt32(c.name.hashValue & 0xFFFF), channels: c.channels)
            if c.name.contains("palette") { planes = planes.map { $0.map { ($0 / 16) * 16 } } }
            // cjxl takes the unsigned representation; the DICOM object declares the sign.
            let shift: Int32 = c.signed ? Int32(1) << Int32(c.precision - 1) : 0
            let unsigned = planes.map { $0.map { $0 &+ shift } }
            let source = dir.appendingPathComponent(c.name + (c.channels == 3 ? ".ppm" : ".pgm"))
            try Self.pnm(unsigned, width: c.width, height: c.height, precision: c.precision).write(to: source)
            let jxl = dir.appendingPathComponent(c.name + ".jxl")
            let result = try Self.run(cjxl, [source.path, jxl.path, "-d", "0", "-m", "1", "--container=0", "--quiet"] + c.flags)
            XCTAssertEqual(result.status, 0, "cjxl \(c.name): \(result.error)")
            let codestream = try Data(contentsOf: jxl)
            let descriptor = Self.descriptor(Self.lossless, width: c.width, height: c.height, precision: c.precision, signed: c.signed, channels: c.channels)
            if c.channels == 3 && c.precision > 8 {
                // The codec covers RGB up to 16 bits; the DICOM frame contract carries RGB8 only.
                let frame = try JXLDecoder().decodeModularFrame(codestream)
                for ch in 0..<3 { XCTAssertEqual(frame.planes[ch], planes[ch], "\(c.name) channel \(ch)") }
                do {
                    _ = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
                    XCTFail("\(c.name): colour above 8 bits must be refused by the DICOM adapter")
                } catch is DicomJXLSwiftBackendError {}
                continue
            }
            let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
            XCTAssertEqual(decoded.buffer.data, Self.stored(planes, bitsAllocated: descriptor.bitsAllocated), c.name)
            XCTAssertEqual(decoded.bitsPerSample, c.precision, c.name)
            let inspection = try DicomJXLSwiftBackend.inspectFrame(codestream)
            XCTAssertEqual(inspection.bitsPerSample, c.precision, c.name)
            XCTAssertTrue(inspection.isModular, c.name)
            XCTAssertFalse(inspection.hasEmbeddedICCProfile, c.name)
        }
    }

    // MARK: - Own streams decoded by libjxl

    func test_ownStreamsDecodeExactlyWithDjxl() async throws {
        let djxl = try requireExecutable("djxl")
        let dir = try temporaryDirectory()
        let backend = DicomJXLSwiftBackend()
        struct Case { let name: String; let width: Int; let height: Int; let precision: Int; let signed: Bool; let channels: Int; let syntax: DicomTransferSyntax }
        let cases = [
            Case(name: "gray8", width: 53, height: 37, precision: 8, signed: false, channels: 1, syntax: Self.lossless),
            Case(name: "gray1", width: 61, height: 29, precision: 1, signed: false, channels: 1, syntax: Self.lossless),
            Case(name: "gray4", width: 53, height: 37, precision: 4, signed: false, channels: 1, syntax: Self.lossless),
            Case(name: "gray7-signed", width: 53, height: 37, precision: 7, signed: true, channels: 1, syntax: Self.lossless),
            Case(name: "gray10", width: 301, height: 277, precision: 10, signed: false, channels: 1, syntax: Self.lossless),
            Case(name: "gray12", width: 512, height: 512, precision: 12, signed: false, channels: 1, syntax: Self.lossless),
            Case(name: "gray12-signed", width: 300, height: 271, precision: 12, signed: true, channels: 1, syntax: Self.general),
            Case(name: "gray12-groups", width: 600, height: 520, precision: 12, signed: true, channels: 1, syntax: Self.lossless),
            Case(name: "gray16", width: 513, height: 257, precision: 16, signed: false, channels: 1, syntax: Self.lossless),
            Case(name: "gray16-signed", width: 300, height: 271, precision: 16, signed: true, channels: 1, syntax: Self.lossless),
            Case(name: "gray14", width: 1030, height: 17, precision: 14, signed: false, channels: 1, syntax: Self.lossless),
            Case(name: "rgb8", width: 300, height: 271, precision: 8, signed: false, channels: 3, syntax: Self.lossless),
            Case(name: "rgb8-groups", width: 600, height: 520, precision: 8, signed: false, channels: 3, syntax: Self.general),
            Case(name: "rgb12", width: 200, height: 150, precision: 12, signed: false, channels: 3, syntax: Self.lossless),
            Case(name: "rgb16", width: 277, height: 301, precision: 16, signed: false, channels: 3, syntax: Self.lossless)
        ]
        for c in cases {
            let planes = Self.samples(width: c.width, height: c.height, precision: c.precision, signed: c.signed, seed: UInt32(c.name.utf8.reduce(0) { $0 &+ UInt32($1) }), channels: c.channels)
            let descriptor = Self.descriptor(c.syntax, width: c.width, height: c.height, precision: c.precision, signed: c.signed, channels: c.channels)
            let frame = Self.frame(planes, width: c.width, height: c.height, precision: c.precision, bitsAllocated: descriptor.bitsAllocated)
            let codestream: Data
            if c.channels == 3 && c.precision > 8 {
                // Codec-level colour above 8 bits (outside the DICOM frame contract).
                codestream = try SpecModularEncoder.encodePlanes(
                    width: c.width, height: c.height, planes: planes, bitsPerSample: UInt32(c.precision)).codestream
            } else {
                codestream = try await backend.encode(DicomFrameEncodeRequest(
                    frame: frame, descriptor: descriptor, targetTransferSyntaxUID: c.syntax.rawValue, intent: .reversible))
            }
            XCTAssertEqual(codestream.prefix(2), Data([0xFF, 0x0A]), "\(c.name): raw codestream, no container")
            let jxl = dir.appendingPathComponent(c.name + ".jxl")
            try codestream.write(to: jxl)
            let out = dir.appendingPathComponent(c.name + (c.channels == 3 ? ".ppm" : ".pgm"))
            let result = try Self.run(djxl, [jxl.path, out.path, "--quiet"])
            XCTAssertEqual(result.status, 0, "djxl \(c.name): \(result.error)")
            let decoded = try Self.parsePNM(try Data(contentsOf: out))
            XCTAssertEqual(decoded.width, c.width, c.name)
            XCTAssertEqual(decoded.height, c.height, c.name)
            XCTAssertEqual(decoded.maxval, (1 << c.precision) - 1, "\(c.name): djxl reports the coded bit depth")
            let shift: Int32 = c.signed ? Int32(1) << Int32(c.precision - 1) : 0
            for ch in 0..<c.channels {
                XCTAssertEqual(decoded.planes[ch], planes[ch].map { $0 &+ shift }, "\(c.name) channel \(ch)")
            }
            // The own decoder agrees with itself and applies the DICOM sign.
            if c.channels == 3 && c.precision > 8 {
                let back = try JXLDecoder().decodeModularFrame(codestream)
                for ch in 0..<3 { XCTAssertEqual(back.planes[ch], planes[ch], "\(c.name) own channel \(ch)") }
            } else {
                let back = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
                XCTAssertEqual(back.buffer.data, frame.buffer.data, c.name)
            }
        }
    }

    func test_signIsTakenFromPixelRepresentationNotFromTheCodestream() async throws {
        let backend = DicomJXLSwiftBackend()
        let (width, height) = (40, 30)
        let planes = Self.samples(width: width, height: height, precision: 12, signed: true, seed: 3)
        let signed = Self.descriptor(Self.lossless, width: width, height: height, precision: 12, signed: true)
        let codestream = try await backend.encode(DicomFrameEncodeRequest(
            frame: Self.frame(planes, width: width, height: height, precision: 12, bitsAllocated: 16),
            descriptor: signed, targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible))
        let unsigned = Self.descriptor(Self.lossless, width: width, height: height, precision: 12, signed: false)
        let asUnsigned = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: unsigned, frameIndex: 0))
        XCTAssertEqual(asUnsigned.buffer.data, Self.stored(planes.map { $0.map { $0 + 2048 } }, bitsAllocated: 16),
                       "the codestream is unsigned; only Pixel Representation restores the sign")
        let asSigned = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: signed, frameIndex: 0))
        XCTAssertEqual(asSigned.buffer.data, Self.stored(planes, bitsAllocated: 16))
    }

    // MARK: - ICC passthrough

    func test_iccProfileTravelsInsideTheCodestreamAsPassthrough() async throws {
        let djxl = try requireExecutable("djxl")
        let cjxl = try requireExecutable("cjxl")
        guard let gray = Self.systemICC("Generic Gray Profile.icc"), let rgb = Self.systemICC("sRGB Profile.icc") else {
            throw XCTSkip("system ICC profiles unavailable")
        }
        let dir = try temporaryDirectory()
        let backend = DicomJXLSwiftBackend()
        for (name, icc, channels, precision) in [("gray12", gray, 1, 12), ("rgb8", rgb, 3, 8), ("gray16", gray, 1, 16)] {
            let (width, height) = (70, 45)
            let planes = Self.samples(width: width, height: height, precision: precision, signed: false, seed: 11, channels: channels)
            let descriptor = Self.descriptor(Self.lossless, width: width, height: height, precision: precision, signed: false, channels: channels)
            let codestream = try await backend.encode(DicomFrameEncodeRequest(
                frame: Self.frame(planes, width: width, height: height, precision: precision, bitsAllocated: descriptor.bitsAllocated),
                descriptor: descriptor, targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible, iccProfile: icc))
            // Own reading: bytes identical, pixels untouched, no colorimetric conversion.
            let frame = try JXLDecoder().decodeModularFrame(codestream)
            XCTAssertEqual(frame.iccProfile, icc, name)
            XCTAssertTrue(frame.metadata.colorEncoding.useICC, name)
            let inspection = try DicomJXLSwiftBackend.inspectFrame(codestream)
            XCTAssertTrue(inspection.hasEmbeddedICCProfile, name)
            XCTAssertEqual(inspection.embeddedICCProfileByteCount, icc.count, name)
            XCTAssertEqual(inspection.colourChannels, channels, name)
            let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
            XCTAssertEqual(decoded.buffer.data, Self.stored(planes, bitsAllocated: descriptor.bitsAllocated), name)
            // libjxl accepts the ICC stream, reproduces the pixels and the profile.
            let jxl = dir.appendingPathComponent(name + ".jxl")
            try codestream.write(to: jxl)
            let png = dir.appendingPathComponent(name + ".png")
            let result = try Self.run(djxl, [jxl.path, png.path, "--quiet"])
            XCTAssertEqual(result.status, 0, "djxl \(name): \(result.error)")
            XCTAssertEqual(try Self.pngICC(try Data(contentsOf: png)), icc, "\(name): djxl reproduces the embedded profile")
            let pnm = dir.appendingPathComponent(name + (channels == 3 ? ".ppm" : ".pgm"))
            XCTAssertEqual(try Self.run(djxl, [jxl.path, pnm.path, "--quiet"]).status, 0)
            let parsed = try Self.parsePNM(try Data(contentsOf: pnm))
            for c in 0..<channels { XCTAssertEqual(parsed.planes[c], planes[c], "\(name) channel \(c)") }
        }
        // A profile whose colour space contradicts Samples per Pixel is refused before coding.
        do {
            let planes = Self.samples(width: 8, height: 8, precision: 8, signed: false, seed: 1, channels: 3)
            let descriptor = Self.descriptor(Self.lossless, width: 8, height: 8, precision: 8, signed: false, channels: 3)
            _ = try await backend.encode(DicomFrameEncodeRequest(
                frame: Self.frame(planes, width: 8, height: 8, precision: 8, bitsAllocated: 8),
                descriptor: descriptor, targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible, iccProfile: gray))
            XCTFail("a GRAY profile on RGB samples must be refused")
        } catch let error as DicomJXLSwiftBackendError {
            XCTAssertTrue((error.errorDescription ?? "").contains("GRAY"), "\(error)")
        }
        // cjxl-written profile (PNG iCCP) surfaces unchanged from the own decoder.
        let (width, height) = (64, 48)
        let planes = Self.samples(width: width, height: height, precision: 8, signed: false, seed: 5, channels: 3)
        let source = dir.appendingPathComponent("icc-source.png")
        try Self.png(planes, width: width, height: height, precision: 8, icc: rgb).write(to: source)
        let jxl = dir.appendingPathComponent("icc-cjxl.jxl")
        let result = try Self.run(cjxl, [source.path, jxl.path, "-d", "0", "-m", "1", "--container=0", "--quiet", "-e", "7"])
        XCTAssertEqual(result.status, 0, "cjxl icc: \(result.error)")
        let frame = try JXLDecoder().decodeModularFrame(try Data(contentsOf: jxl))
        XCTAssertEqual(frame.iccProfile, rgb, "cjxl embeds the PNG profile; the own decoder returns it byte for byte")
        XCTAssertEqual(frame.planes[0], planes[0])
        XCTAssertEqual(frame.planes[2], planes[2])
    }

    // MARK: - DICOM layer

    func test_transcoderKeepsOneFragmentPerFrameAndTheICCProfileElement() async throws {
        guard let icc = Self.systemICC("Generic Gray Profile.icc") else { throw XCTSkip("system ICC profiles unavailable") }
        let (width, height, frames) = (75, 51, 3)
        let sources = (0..<frames).map { Self.samples(width: width, height: height, precision: 12, signed: true, seed: UInt32(20 + $0))[0] }
        let native = try Self.file(frames: sources.map { Self.stored([$0], bitsAllocated: 16) }, syntax: .explicitVRLittleEndian,
                                   width: width, height: height, precision: 12, signed: true, icc: icc)
        let transcoder = DicomTranscoder()
        for syntax in [Self.lossless, Self.general] {
            let compressed = try await transcoder.transcode(native, to: syntax, intent: .reversible, environment: Self.experimental)
            let decoder = try DCMDecoder(data: compressed)
            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), syntax.rawValue)
            let descriptor = try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor)
            XCTAssertEqual(descriptor.fragments.count, frames, "one fragment per frame (PS3.5 A.4.13)")
            XCTAssertTrue(descriptor.fragments.allSatisfy { $0.length.isMultiple(of: 2) }, "even fragment lengths")
            XCTAssertEqual(descriptor.basicOffsetTable.offsets.count, frames)
            XCTAssertEqual(decoder.dataSet.element(for: .iccProfile)?.value, .bytes(icc), "the ICC Profile element stays in the data set")
            XCTAssertEqual(decoder.intValue(for: .bitsStored), 12)
            XCTAssertEqual(decoder.intValue(for: .pixelRepresentation), 1)
            let reader = try decoder.makeEncapsulatedPixelFrameReader()
            for index in 0..<frames {
                let inspection = try DicomJXLSwiftBackend.inspectFrame(try reader.frameData(at: index))
                XCTAssertEqual(inspection.embeddedICCProfileByteCount, icc.count, "frame \(index) embeds the profile")
                XCTAssertEqual(inspection.bitsPerSample, 12)
            }
            let restored = try await transcoder.transcode(compressed, to: .explicitVRLittleEndian, intent: .reversible, environment: Self.experimental)
            let restoredDecoder = try DCMDecoder(data: restored)
            XCTAssertEqual(restoredDecoder.getAllFrames()?.map(\.data), sources.map { Self.stored([$0], bitsAllocated: 16) }, "native round trip exact")
            XCTAssertEqual(restoredDecoder.dataSet.element(for: .iccProfile)?.value, .bytes(icc))
        }
        // The lossy route refuses to drop the profile silently.
        do {
            _ = try await transcoder.transcode(native, to: Self.general, intent: .irreversible(quality: 0.5), environment: Self.experimental)
            XCTFail("irreversible with ICC must be refused")
        } catch {
            XCTAssertTrue("\(error)".contains("ICC"), "\(error)")
        }
    }

    func test_capabilityResolutionAcceptsTheWidenedShapesUnderTheFlag() {
        let twelve = Self.descriptor(Self.lossless, width: 64, height: 64, precision: 12, signed: true)
        let disabled = DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .decode, descriptor: twelve), environment: [:])
        XCTAssertFalse(disabled.canExecute, "the rollout stays opt-in")
        let decode = DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .decode, descriptor: twelve), environment: Self.experimental)
        XCTAssertTrue(decode.canExecute)
        XCTAssertEqual(decode.backendIdentifier, "jxlswift")
        XCTAssertEqual(decode.qualification, .experimental)
        let encode = DicomCodecCapabilities.resolve(
            DicomCodecCapabilityRequest(operation: .encode, descriptor: twelve, intent: .reversible), environment: Self.experimental)
        XCTAssertTrue(encode.canExecute)
        let rgb16 = Self.descriptor(Self.lossless, width: 64, height: 64, precision: 16, signed: false, channels: 3)
        XCTAssertFalse(DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .encode, descriptor: rgb16, intent: .reversible), environment: Self.experimental).canExecute,
                       "colour above 8 bits stays outside the frame contract")
        let rgb8 = Self.descriptor(Self.lossless, width: 64, height: 64, precision: 8, signed: false, channels: 3)
        XCTAssertTrue(DicomCodecCapabilities.resolve(DicomCodecCapabilityRequest(operation: .encode, descriptor: rgb8, intent: .reversible), environment: Self.experimental).canExecute)
        let lossyOnLossless = DicomCodecCapabilities.resolve(
            DicomCodecCapabilityRequest(operation: .encode, descriptor: twelve, intent: .irreversible(quality: 0.5)), environment: Self.experimental)
        XCTAssertFalse(lossyOnLossless.canExecute, "the lossless-only syntax refuses irreversible intent")
    }

    // MARK: - Refusals

    func test_inadmissibleDicomShapesAreRefusedTyped() async throws {
        let backend = DicomJXLSwiftBackend()
        func refuse(_ descriptor: DicomCompressedFrameDescriptor, _ label: String, contains: String) async {
            let bytes = descriptor.bitsAllocated / 8 * descriptor.rows * descriptor.columns * descriptor.samplesPerPixel
            let frame = DicomCodecDecodedFrame(buffer: .owned(Data(count: bytes)), width: descriptor.columns, height: descriptor.rows,
                                               bitsPerSample: descriptor.bitsStored, componentCount: descriptor.samplesPerPixel)
            do {
                _ = try await backend.encode(DicomFrameEncodeRequest(frame: frame, descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID, intent: .reversible))
                XCTFail("\(label) must be refused")
            } catch let error as DicomJXLSwiftBackendError {
                XCTAssertTrue((error.errorDescription ?? "").contains(contains), "\(label): \(error)")
            } catch {
                XCTFail("\(label): unexpected \(error)")
            }
        }
        let uid = Self.lossless.rawValue
        await refuse(DicomCompressedFrameDescriptor(transferSyntaxUID: uid, rows: 4, columns: 4, bitsAllocated: 24, bitsStored: 24, highBit: 23, pixelRepresentation: 0, samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil), "24-bit container", contains: "invalid")
        await refuse(DicomCompressedFrameDescriptor(transferSyntaxUID: uid, rows: 4, columns: 4, bitsAllocated: 8, bitsStored: 12, highBit: 11, pixelRepresentation: 0, samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil), "stored above allocated", contains: "invalid")
        await refuse(DicomCompressedFrameDescriptor(transferSyntaxUID: uid, rows: 4, columns: 4, bitsAllocated: 16, bitsStored: 12, highBit: 15, pixelRepresentation: 0, samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil), "high bit", contains: "High Bit")
        await refuse(DicomCompressedFrameDescriptor(transferSyntaxUID: uid, rows: 4, columns: 4, bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0, samplesPerPixel: 1, photometricInterpretation: "PALETTE COLOR", planarConfiguration: nil), "palette colour", contains: "PALETTE COLOR")
        await refuse(DicomCompressedFrameDescriptor(transferSyntaxUID: uid, rows: 4, columns: 4, bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 1, samplesPerPixel: 3, photometricInterpretation: "RGB", planarConfiguration: 0), "signed RGB", contains: "unsigned")
        await refuse(DicomCompressedFrameDescriptor(transferSyntaxUID: uid, rows: 4, columns: 4, bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0, samplesPerPixel: 3, photometricInterpretation: "RGB", planarConfiguration: 1), "planar 1", contains: "Planar")
        await refuse(DicomCompressedFrameDescriptor(transferSyntaxUID: uid, rows: 4, columns: 4, bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0, samplesPerPixel: 3, photometricInterpretation: "YBR_FULL", planarConfiguration: 0), "YBR_FULL", contains: "RGB")
        // Samples outside Bits Stored never reach the coder.
        let twelve = Self.descriptor(Self.lossless, width: 4, height: 4, precision: 12, signed: false)
        var bad = Data(count: 32); bad[5] = 0x10
        do {
            _ = try await backend.encode(DicomFrameEncodeRequest(
                frame: DicomCodecDecodedFrame(buffer: .owned(bad), width: 4, height: 4, bitsPerSample: 12, componentCount: 1),
                descriptor: twelve, targetTransferSyntaxUID: uid, intent: .reversible))
            XCTFail("out-of-range sample must be refused")
        } catch let error as DicomJXLSwiftBackendError {
            XCTAssertTrue((error.errorDescription ?? "").contains("exceeds"), "\(error)")
        }
    }

    func test_codestreamAndDescriptorDisagreementsAreRefusedTyped() async throws {
        let backend = DicomJXLSwiftBackend()
        let (width, height) = (33, 21)
        let planes = Self.samples(width: width, height: height, precision: 12, signed: false, seed: 9)
        let twelve = Self.descriptor(Self.lossless, width: width, height: height, precision: 12, signed: false)
        let codestream = try await backend.encode(DicomFrameEncodeRequest(
            frame: Self.frame(planes, width: width, height: height, precision: 12, bitsAllocated: 16),
            descriptor: twelve, targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible))
        func expectMismatch(_ descriptor: DicomCompressedFrameDescriptor, _ label: String, contains: String) async {
            do {
                _ = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream, descriptor: descriptor, frameIndex: 0))
                XCTFail("\(label) must be refused")
            } catch let error as DicomJXLSwiftBackendError {
                XCTAssertTrue((error.errorDescription ?? "").contains(contains), "\(label): \(error)")
            } catch {
                XCTFail("\(label): unexpected \(error)")
            }
        }
        await expectMismatch(Self.descriptor(Self.lossless, width: width, height: height, precision: 16, signed: false), "bits stored 16 vs 12-bit stream", contains: "Bits Stored")
        await expectMismatch(Self.descriptor(Self.lossless, width: width + 1, height: height, precision: 12, signed: false), "columns", contains: "differ")
        // Samples per Pixel disagreement (8-bit grey stream under an RGB8 descriptor).
        let gray8 = try await backend.encode(DicomFrameEncodeRequest(
            frame: Self.frame(Self.samples(width: width, height: height, precision: 8, signed: false, seed: 6), width: width, height: height, precision: 8, bitsAllocated: 8),
            descriptor: Self.descriptor(Self.lossless, width: width, height: height, precision: 8, signed: false),
            targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible))
        do {
            _ = try await backend.decode(DicomFrameDecodeRequest(
                frameData: gray8, descriptor: Self.descriptor(Self.lossless, width: width, height: height, precision: 8, signed: false, channels: 3), frameIndex: 0))
            XCTFail("samples per pixel mismatch must be refused")
        } catch let error as DicomJXLSwiftBackendError {
            XCTAssertTrue((error.errorDescription ?? "").contains("colour channel"), "\(error)")
        }
        // A VarDCT frame under the lossless-only syntax is a mismatch.
        let lossy = try await backend.encode(DicomFrameEncodeRequest(
            frame: Self.frame(Self.samples(width: 64, height: 64, precision: 8, signed: false, seed: 1), width: 64, height: 64, precision: 8, bitsAllocated: 8),
            descriptor: Self.descriptor(Self.general, width: 64, height: 64, precision: 8, signed: false),
            targetTransferSyntaxUID: Self.general.rawValue, intent: .irreversible(quality: 0.5)))
        do {
            _ = try await backend.decode(DicomFrameDecodeRequest(frameData: lossy, descriptor: Self.descriptor(Self.lossless, width: 64, height: 64, precision: 8, signed: false), frameIndex: 0))
            XCTFail("VarDCT under .110 must be refused")
        } catch let error as DicomJXLSwiftBackendError {
            XCTAssertTrue((error.errorDescription ?? "").contains("Modular"), "\(error)")
        }
    }

    func test_hostileStreamsAreRefusedBeforeAllocation() async throws {
        let backend = DicomJXLSwiftBackend()
        let (width, height) = (48, 40)
        let planes = Self.samples(width: width, height: height, precision: 12, signed: false, seed: 4)
        let descriptor = Self.descriptor(Self.lossless, width: width, height: height, precision: 12, signed: false)
        let codestream = try await backend.encode(DicomFrameEncodeRequest(
            frame: Self.frame(planes, width: width, height: height, precision: 12, bitsAllocated: 16),
            descriptor: descriptor, targetTransferSyntaxUID: Self.lossless.rawValue, intent: .reversible))
        // Decompression bomb: a header that announces 16384 x 16384 pixels for a few bytes.
        var bomb = try SpecModularEncoder.writeModularPrelude(width: 16_384, height: 16_384, bitsPerSample: 12, colorSpace: .grayscale, extraChannels: [], animation: nil)
        bomb.append(codestream.suffix(from: 40))
        do {
            _ = try await backend.decode(DicomFrameDecodeRequest(frameData: bomb, descriptor: descriptor, frameIndex: 0))
            XCTFail("the bomb must be refused")
        } catch let error as DicomJXLSwiftBackendError {
            XCTAssertTrue((error.errorDescription ?? "").contains("differ"), "refused on the header alone: \(error)")
        }
        do {
            _ = try JXLDecoder().decodeModularFrame(bomb, maximumSamples: 1 << 20)
            XCTFail("the sample bound must refuse the bomb")
        } catch let error as DecoderError {
            XCTAssertTrue((error.errorDescription ?? "\(error)").contains("bound"), "\(error)")
        }
        // Truncation at every 7th byte: typed errors, never a trap or a silent success.
        var refused = 0
        for cut in stride(from: 1, to: codestream.count - 1, by: 7) {
            do {
                _ = try await backend.decode(DicomFrameDecodeRequest(frameData: codestream.prefix(cut), descriptor: descriptor, frameIndex: 0))
            } catch is DicomJXLSwiftBackendError {
                refused += 1
            }
        }
        XCTAssertEqual(refused, stride(from: 1, to: codestream.count - 1, by: 7).underestimatedCount, "every truncation is refused")
        // Transform corruption: flip bytes inside the group header / transform area.
        var corrupted = 0
        for offset in 20..<min(60, codestream.count) {
            var damaged = codestream
            damaged[damaged.startIndex + offset] ^= 0x5A
            do {
                let decoded = try await backend.decode(DicomFrameDecodeRequest(frameData: damaged, descriptor: descriptor, frameIndex: 0))
                _ = decoded
            } catch is DicomJXLSwiftBackendError {
                corrupted += 1
            }
        }
        XCTAssertGreaterThan(corrupted, 0)
    }

    func test_extraChannelsAndUnsupportedFramesAreRefusedTyped() async throws {
        let cjxl = try requireExecutable("cjxl")
        let dir = try temporaryDirectory()
        // PAM with alpha: cjxl writes an extra channel, which the DICOM profile does not admit.
        let (width, height) = (24, 16)
        var pam = Data("P7\nWIDTH \(width)\nHEIGHT \(height)\nDEPTH 2\nMAXVAL 255\nTUPLTYPE GRAYSCALE_ALPHA\nENDHDR\n".utf8)
        for i in 0..<(width * height) { pam.append(UInt8(i & 0xFF)); pam.append(UInt8(255 - (i & 0x7F))) }
        let source = dir.appendingPathComponent("alpha.pam")
        try pam.write(to: source)
        let jxl = dir.appendingPathComponent("alpha.jxl")
        let result = try Self.run(cjxl, [source.path, jxl.path, "-d", "0", "-m", "1", "--container=0", "--quiet", "-e", "3"])
        XCTAssertEqual(result.status, 0, result.error)
        let descriptor = Self.descriptor(Self.lossless, width: width, height: height, precision: 8, signed: false)
        do {
            _ = try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(frameData: try Data(contentsOf: jxl), descriptor: descriptor, frameIndex: 0))
            XCTFail("alpha must be refused")
        } catch let error as DicomJXLSwiftBackendError {
            XCTAssertTrue((error.errorDescription ?? "").contains("extra channels"), "\(error)")
        }
        // A lossy Modular (XYB) frame decodes under .112 (issue #2333) and is refused typed under the lossless-only .110.
        let lossySource = dir.appendingPathComponent("lossy.pgm")
        try Self.pnm(Self.samples(width: 64, height: 64, precision: 8, signed: false, seed: 2), width: 64, height: 64, precision: 8).write(to: lossySource)
        let lossy = dir.appendingPathComponent("lossy.jxl")
        XCTAssertEqual(try Self.run(cjxl, [lossySource.path, lossy.path, "-d", "1", "-m", "1", "--container=0", "--quiet"]).status, 0)
        let lossyFrame = try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(
            frameData: try Data(contentsOf: lossy), descriptor: Self.descriptor(Self.general, width: 64, height: 64, precision: 8, signed: false), frameIndex: 0))
        XCTAssertEqual(lossyFrame.buffer.data.count, 64 * 64)
        do {
            _ = try await DicomJXLSwiftBackend().decode(DicomFrameDecodeRequest(
                frameData: try Data(contentsOf: lossy), descriptor: Self.descriptor(Self.lossless, width: 64, height: 64, precision: 8, signed: false), frameIndex: 0))
            XCTFail("XYB modular must be refused under the lossless-only syntax")
        } catch let error as DicomJXLSwiftBackendError {
            XCTAssertTrue((error.errorDescription ?? "").contains("reversible"), "\(error)")
        }
    }
}
