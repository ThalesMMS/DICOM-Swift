import DicomCore
import Foundation

/// Deterministic, PHI-free full-range synthetic corpus for the clinical-path workloads. Every object is generated from
/// a seeded pattern with fixed dates so its SHA-256 is stable across runs and hosts; the manifest pins those digests.
public enum ClinicalPathSyntheticCorpus {
    public struct Object: Sendable {
        public let fixture: ClinicalPathFixture
        public let part10: Data
        public let expectedPixelSHA256: String
        public let columns: Int, rows: Int, frames: Int, bitsAllocated: Int, samplesPerPixel: Int
    }

    static func pattern16(columns: Int, rows: Int, frames: Int, seed: UInt32) -> Data {
        var bytes = Data(count: columns * rows * frames * 2)
        var state = seed
        bytes.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: UInt16.self)
            for frame in 0..<frames {
                for row in 0..<rows {
                    for column in 0..<columns {
                        // CT-like body: smooth gradient plus a low-amplitude pseudo-random texture (xorshift).
                        state ^= state << 13; state ^= state >> 17; state ^= state << 5
                        let radial = ((column - columns / 2) * (column - columns / 2) + (row - rows / 2) * (row - rows / 2))
                        let base = 1024 + (radial % 2048) + frame * 8
                        pixels[frame * columns * rows + row * columns + column] = UInt16(min(4095, base + Int(state % 32)))
                    }
                }
            }
        }
        return bytes
    }

    static func pattern8(columns: Int, rows: Int, samples: Int, seed: UInt32) -> Data {
        var bytes = Data(count: columns * rows * samples)
        var state = seed
        for index in 0..<bytes.count {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            let base = UInt8((index / samples) % 251)
            let texture = UInt8(state % 5)
            bytes[index] = base &+ texture
        }
        return bytes
    }

    static func build(id: String, generator: String, columns: Int, rows: Int, frames: Int, bits: Int, samples: Int, seed: UInt32, parameters: [String: String]) throws -> Object {
        let pixels: Data
        if bits == 16 { pixels = pattern16(columns: columns, rows: rows, frames: frames, seed: seed) } else { pixels = pattern8(columns: columns, rows: rows, samples: samples, seed: seed) }
        let frameBytes = columns * rows * samples * (bits / 8)
        let firstFrame = Data(pixels.prefix(frameBytes))
        let photometric = samples == 3 ? "RGB" : "MONOCHROME2"
        let bitsStored = bits == 16 ? 12 : 8
        let highBit = bitsStored - 1
        let planar: Int? = samples == 3 ? 0 : nil
        let pixelData = try DicomSecondaryCapturePixelData(data: firstFrame, columns: columns, rows: rows, samplesPerPixel: samples,
                                                          photometricInterpretation: photometric, bitsAllocated: bits,
                                                          bitsStored: bitsStored, highBit: highBit, planarConfiguration: planar)
        let uidBase = "2.25.2367" + String(seed)
        var dataSet = DicomSecondaryCaptureBuilder.dataSet(pixelData: pixelData, options: .init(
            sopInstanceUID: uidBase + ".3", studyInstanceUID: uidBase + ".1", seriesInstanceUID: uidBase + ".2", patientName: "Synthetic^ClinicalPath",
            patientID: "CP2367", studyDate: "20260101", studyTime: "120000", seriesNumber: 1, instanceNumber: 1, seriesDate: "20260101", seriesTime: "120000",
            seriesDescription: "Clinical path " + id, contentDate: "20260101", contentTime: "120000", instanceCreationDate: "20260101", instanceCreationTime: "120000",
            dateOfSecondaryCapture: "20260101", timeOfSecondaryCapture: "120000"))
        if frames > 1 {
            dataSet.set(.init(tag: 0x0028_0008, vr: .IS, value: .strings([String(frames)])))
            dataSet.set(.init(tag: DicomTag.pixelData.rawValue, vr: bits == 16 ? .OW : .OB, value: .bytes(pixels)))
        }
        if bits == 16 {
            dataSet.set(.init(tag: 0x0028_1050, vr: .DS, value: .strings(["40"])))
            dataSet.set(.init(tag: 0x0028_1051, vr: .DS, value: .strings(["400"])))
            dataSet.set(.init(tag: 0x0028_1052, vr: .DS, value: .strings(["-1024"])))
            dataSet.set(.init(tag: 0x0028_1053, vr: .DS, value: .strings(["1"])))
        }
        dataSet.set(.init(tag: 0x0028_0030, vr: .DS, value: .strings(["0.7", "0.7"])))
        let part10 = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID),
                                                                                    mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)))
        let formatLabel: String
        if bits == 16 { formatLabel = "MONOCHROME2 16-bit (12 stored) Explicit VR LE" } else if samples == 3 { formatLabel = "RGB 8-bit Explicit VR LE" } else { formatLabel = "MONOCHROME2 8-bit Explicit VR LE" }
        var mergedParameters = parameters
        mergedParameters["seed"] = String(seed)
        let fixture = ClinicalPathFixture(id: id, source: "synthetic:" + generator, sha256: ClinicalPathMeasurer.sha256(part10), bytes: part10.count,
                                          geometry: "\(columns)x\(rows)x\(frames)", format: formatLabel, parameters: mergedParameters)
        return Object(fixture: fixture, part10: part10, expectedPixelSHA256: ClinicalPathMeasurer.sha256(pixels), columns: columns, rows: rows, frames: frames, bitsAllocated: bits, samplesPerPixel: samples)
    }

    static func transcoded(_ source: Object, id: String, to syntax: DicomTransferSyntax, label: String) async throws -> Object {
        let data: Data
        if syntax == .htj2kLossless {
            data = try await DicomTranscoder().transcode(source.part10, to: syntax, intent: .reversible)
        } else {
            data = try DicomTranscoder().transcode(source.part10, to: syntax)
        }
        let fixture = ClinicalPathFixture(id: id, source: source.fixture.source + "+transcode", sha256: ClinicalPathMeasurer.sha256(data), bytes: data.count,
                                          geometry: source.fixture.geometry, format: label + " " + syntax.rawValue, parameters: source.fixture.parameters.merging(["transferSyntax": syntax.rawValue]) { $1 })
        return Object(fixture: fixture, part10: data, expectedPixelSHA256: source.expectedPixelSHA256, columns: source.columns, rows: source.rows, frames: source.frames,
                      bitsAllocated: source.bitsAllocated, samplesPerPixel: source.samplesPerPixel)
    }

    public static let identifiers = ["ct-512x512-16bit", "ct-multiframe-256x256x16", "rgb-512x512-8bit", "ct-512x512-16bit-jpegls", "ct-512x512-16bit-htj2k", "ct-512x512-16bit-rle"]

    /// Generates the full corpus; the aggregate digest (sorted per-object digests) identifies the corpus in reports.
    public static func generate() async throws -> (objects: [Object], corpusSHA256: String) {
        let ct = try build(id: "ct-512x512-16bit", generator: "xorshift-ct-v1", columns: 512, rows: 512, frames: 1, bits: 16, samples: 1, seed: 0x2367_0001, parameters: ["profile": "CT-like single frame"])
        let multiframe = try build(id: "ct-multiframe-256x256x16", generator: "xorshift-ct-v1", columns: 256, rows: 256, frames: 16, bits: 16, samples: 1, seed: 0x2367_0002, parameters: ["profile": "CT-like multi-frame"])
        let rgb = try build(id: "rgb-512x512-8bit", generator: "xorshift-rgb-v1", columns: 512, rows: 512, frames: 1, bits: 8, samples: 3, seed: 0x2367_0003, parameters: ["profile": "RGB secondary capture"])
        let jpegls = try await transcoded(ct, id: "ct-512x512-16bit-jpegls", to: .jpegLSLossless, label: "JPEG-LS lossless")
        let htj2k = try await transcoded(ct, id: "ct-512x512-16bit-htj2k", to: .htj2kLossless, label: "HTJ2K lossless")
        let rle = try await transcoded(ct, id: "ct-512x512-16bit-rle", to: .rleLossless, label: "RLE lossless")
        let objects = [ct, multiframe, rgb, jpegls, htj2k, rle]
        let corpus = ClinicalPathMeasurer.sha256(Data(objects.map(\.fixture.sha256).sorted().joined(separator: "\n").utf8))
        return (objects, corpus)
    }
}
