//
//  JPEGXLConformanceVectorTests.swift
//  DicomCoreTests
//
//  The official libjxl conformance vectors (https://github.com/libjxl/conformance, `testcases/`)
//  decoded by the own JPEG XL decoder and compared with djxl 0.12 (issue #3245).
//  `Scripts/conformance/jpegxl_conformance_vectors.py` writes `reference.pnm` (and `reference.jpg`
//  for JPEG reconstructions) next to each `input.jxl`; the test is skipped while
//  DICOM_JPEGXL_CONFORMANCE_DIRECTORY is unset so the default suite stays hermetic.
//
//  Thales Matheus Mendonça Santos — November 2026
//

import DicomData
@testable import DicomCore
@testable import DicomJPEGXL
import Foundation
import XCTest

/// The official libjxl conformance vectors (https://github.com/libjxl/conformance, `testcases/`) decoded by the own
/// JPEG XL decoder and compared with djxl 0.12 (issue #3245). `Scripts/conformance/jpegxl_conformance_vectors.py`
/// writes `reference.pnm` (and `reference.jpg` for JPEG reconstructions) next to each `input.jxl`; the test is
/// skipped while DICOM_JPEGXL_CONFORMANCE_DIRECTORY is unset so the default suite stays hermetic.
///
/// Vectors inside the DICOM frame contract — one image, grey or RGB, no extra channels — must match: exactly where
/// the vector's own tolerance is below one code, within one code otherwise (VarDCT), unless the decoder refuses them
/// with a typed error or the DICOM contract check (`dicomFrameContractRefusal`: embedded-ICC XYB, orientation,
/// layers) does, which is what the DICOM adapter then reports. A vector carrying JPEG reconstruction data is checked
/// on the JPEG it rebuilds, which is how the adapter decodes it. The others (alpha, animation, CMYK and spot
/// channels) must decode or fail typed, never crash; their outcome is printed.
///
/// Grey and RGB8 vectors in scope also go through the DICOM adapter (`DicomJXLSwiftBackend`, .112), which reads
/// Modular planes directly: it must show djxl's samples or refuse typed. The lossy Modular vectors that used to be
/// refused there (#3254) — `grayscale_public_university` (restoration filters) and `delta_palette` (planes outside
/// the coded range, clamped as libjxl does) — must match, and so must `opsin_inverse` (a custom opsin inverse
/// matrix, refused by the decoder before #3259), which may not be refused at all.
final class JPEGXLConformanceVectorTests: XCTestCase {
    private static let mustMatchThroughTheAdapter: Set<String> = ["grayscale_public_university", "delta_palette", "opsin_inverse"]
    private static var directory: URL? {
        ProcessInfo.processInfo.environment["DICOM_JPEGXL_CONFORMANCE_DIRECTORY"].map { URL(fileURLWithPath: $0) }
    }

    /// Each prepared vector the DICOM frame contract admits decodes within its djxl tolerance or is refused typed;
    /// vectors the contract refuses are skipped. Skipped without the vector directory.
    func test_conformanceVectors_matchLibjxl() async throws {
        guard let directory = Self.directory else { throw XCTSkip("DICOM_JPEGXL_CONFORMANCE_DIRECTORY unset") }
        let cases = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted().filter {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0)/reference.pnm").path)
        }
        XCTAssertGreaterThan(cases.count, 0, "no prepared vectors")
        var failures: [String] = []
        var inScope = 0
        // Required vectors that reached the adapter comparison; every one must, whatever path it takes.
        var comparedThroughTheAdapter: Set<String> = []
        for name in cases {
            let folder = directory.appendingPathComponent(name)
            let input = try Data(contentsOf: folder.appendingPathComponent("input.jxl"))
            let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("test.json"))))
                as? [String: Any] ?? [:]
            let extraChannels = (meta["extra_channel_type"] as? [Any])?.count ?? 0
            let frames = (meta["frames"] as? [[String: Any]]) ?? []
            let peak = frames.first?["peak_error"] as? Double ?? 0
            let dicomScope = extraChannels == 0 && frames.count <= 1
            let (width, height, maxValue, reference) = try Self.parsePNM(Data(contentsOf: folder.appendingPathComponent("reference.pnm")))
            if let refusal = JXLDecoder().dicomFrameContractRefusal(input) {
                print("JPEGXL_CONFORMANCE \(name) refusedByContract scope=\(dicomScope) \(refusal)")
                if Self.mustMatchThroughTheAdapter.contains(name) {
                    failures.append("\(name): refused by the DICOM frame contract: \(refusal)")
                }
                continue
            }
            let rebuildsJPEG = JXLDecoder().carriesJPEGReconstruction(input)
            let started = Date()
            let frame: ImageFrame
            do {
                frame = try await JXLDecoder().decode(input)
            } catch {
                let typed = error is DecoderError
                print("JPEGXL_CONFORMANCE \(name) refused typed=\(typed) scope=\(dicomScope) \(error)")
                // A typed refusal is an acceptable outcome; only an untyped failure is not.
                if !typed || Self.mustMatchThroughTheAdapter.contains(name) { failures.append("\(name): \(error)") }
                continue
            }
            let milliseconds = Date().timeIntervalSince(started) * 1000
            let colour = reference.count / max(1, width * height * (maxValue > 255 ? 2 : 1))
            guard frame.width == width, frame.height == height, frame.channels - frame.alphaChannels >= colour else {
                print("JPEGXL_CONFORMANCE \(name) geometry \(frame.width)x\(frame.height)x\(frame.channels) vs \(width)x\(height)x\(colour)")
                if dicomScope { failures.append("\(name): geometry") }
                continue
            }
            var maximum = 0
            for pixel in 0..<(width * height) {
                for channel in 0..<colour {
                    let own = Self.sample(frame, pixel: pixel, channel: channel, maxValue: maxValue)
                    let index = pixel * colour + channel
                    let ref = maxValue > 255
                        ? Int(reference[index * 2]) << 8 | Int(reference[index * 2 + 1])
                        : Int(reference[index])
                    maximum = max(maximum, abs(own - ref))
                }
            }
            let tolerance = max(Int((peak * Double(maxValue)).rounded()), 0) == 0 ? 0 : 1
            print("JPEGXL_CONFORMANCE \(name) maxAbs=\(maximum) tolerance=\(tolerance) scope=\(dicomScope) "
                  + "\(String(format: "%.1f", milliseconds)) ms")
            if dicomScope, !rebuildsJPEG {
                inScope += 1
                if maximum > tolerance { failures.append("\(name): \(maximum) codes from djxl (tolerance \(tolerance))") }
                if colour == 1 || maxValue == 255 {
                    let adapter = await Self.adapterDifference(input, width: width, height: height, colour: colour,
                                                               maxValue: maxValue, reference: reference)
                    if Self.mustMatchThroughTheAdapter.contains(name) { comparedThroughTheAdapter.insert(name) }
                    print("JPEGXL_CONFORMANCE \(name) adapter \(adapter.map { "maxAbs=\($0)" } ?? "refused")")
                    if let difference = adapter, difference > tolerance {
                        failures.append("\(name): the DICOM adapter is \(difference) codes from djxl")
                    } else if adapter == nil, Self.mustMatchThroughTheAdapter.contains(name) {
                        failures.append("\(name): refused by the DICOM adapter")
                    }
                }
            }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("reference.jpg").path) {
                let jpeg = try Data(contentsOf: folder.appendingPathComponent("reference.jpg"))
                do {
                    let rebuilt = try await JXLDecoder().decodeLosslessJPEG(input)
                    print("JPEGXL_CONFORMANCE \(name) jpegReconstruction byteExact=\(rebuilt == jpeg)")
                    if rebuilt != jpeg { failures.append("\(name): JPEG reconstruction differs from djxl") }
                } catch {
                    failures.append("\(name): JPEG reconstruction refused: \(error)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(inScope, 4, "too few vectors compared inside the DICOM frame contract")
        // A required vector that is missing, out of scope or stopped earlier never reached the adapter comparison.
        let notCompared = Self.mustMatchThroughTheAdapter.subtracting(comparedThroughTheAdapter).sorted()
        XCTAssertTrue(notCompared.isEmpty, "required vectors not compared through the adapter: \(notCompared)")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// The largest difference between the DICOM adapter's decode (.112, unsigned, Bits Stored at the reference depth)
    /// and djxl's samples, or `nil` when the adapter refuses the stream.
    private static func adapterDifference(
        _ input: Data, width: Int, height: Int, colour: Int, maxValue: Int, reference: Data
    ) async -> Int? {
        let bits = maxValue.bitWidth - maxValue.leadingZeroBitCount
        let descriptor = DicomCompressedFrameDescriptor(
            transferSyntaxUID: DicomTransferSyntax.jpegXL.rawValue, rows: height, columns: width,
            bitsAllocated: bits > 8 ? 16 : 8, bitsStored: bits, highBit: bits - 1, pixelRepresentation: 0,
            samplesPerPixel: colour, photometricInterpretation: colour == 3 ? "RGB" : "MONOCHROME2",
            planarConfiguration: colour == 3 ? 0 : nil)
        guard let frame = try? await DicomJXLSwiftBackend().decode(
            DicomFrameDecodeRequest(frameData: input, descriptor: descriptor, frameIndex: 0)) else { return nil }
        let bytes = [UInt8](frame.buffer.data)
        let step = bits > 8 ? 2 : 1
        guard bytes.count == width * height * colour * step else { return Int.max }
        var maximum = 0
        for index in 0..<(width * height * colour) {
            let own = step == 1 ? Int(bytes[index]) : Int(bytes[index * 2]) | Int(bytes[index * 2 + 1]) << 8
            let theirs = step == 1 ? Int(reference[reference.startIndex + index])
                : Int(reference[reference.startIndex + index * 2]) << 8 | Int(reference[reference.startIndex + index * 2 + 1])
            maximum = max(maximum, abs(own - theirs))
        }
        return maximum
    }

    /// A sample at the codestream's bit depth: 8-bit output stays as is; 16-bit output of a shallower codestream
    /// is scaled the way djxl writes its PNM (to `maxValue`).
    private static func sample(_ frame: ImageFrame, pixel: Int, channel: Int, maxValue: Int) -> Int {
        let index = pixel * frame.channels + channel
        switch frame.pixelType {
        case .uint8:
            let value = Int(frame.data[index])
            return maxValue == 255 ? value : Int((Double(value) * Double(maxValue) / 255).rounded())
        case .uint16, .int16:
            let value = Int(frame.data[index * 2]) | Int(frame.data[index * 2 + 1]) << 8
            return value
        case .float32:
            let bits = UInt32(frame.data[index * 4]) | UInt32(frame.data[index * 4 + 1]) << 8
                | UInt32(frame.data[index * 4 + 2]) << 16 | UInt32(frame.data[index * 4 + 3]) << 24
            let value = Double(Float(bitPattern: bits))
            return Int((min(max(value, 0), 1) * Double(maxValue)).rounded())
        }
    }

    /// Parses a binary PNM header into width, height and maximum value, returned with the pixel payload after it.
    private static func parsePNM(_ data: Data) throws -> (Int, Int, Int, Data) {
        var tokens: [String] = []
        var cursor = data.startIndex
        while tokens.count < 4, cursor < data.endIndex {
            while cursor < data.endIndex, data[cursor] == 0x0A || data[cursor] == 0x20 || data[cursor] == 0x0D || data[cursor] == 0x09 {
                cursor += 1
            }
            var token = ""
            while cursor < data.endIndex, ![0x0A, 0x20, 0x0D, 0x09].contains(data[cursor]) {
                token.append(Character(UnicodeScalar(data[cursor])))
                cursor += 1
            }
            tokens.append(token)
        }
        cursor += 1
        guard tokens.count == 4, let width = Int(tokens[1]), let height = Int(tokens[2]), let maxValue = Int(tokens[3]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (width, height, maxValue, data.subdata(in: cursor..<data.endIndex))
    }
}
