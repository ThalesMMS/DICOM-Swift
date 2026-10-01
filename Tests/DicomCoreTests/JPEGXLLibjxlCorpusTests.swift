import Foundation
@testable import DicomJPEGXL
import XCTest

/// Decodes a libjxl corpus with the vendored Modular core and compares every
/// sample with djxl's output (issue #2332). The corpus is written by
/// `Scripts/conformance/jpegxl_libjxl_corpus.py` (cjxl efforts 1...9, bit
/// depths 1...16, palette, delta palette, every RCT type, all predictors,
/// group sizes, Squeeze, progressive passes, reference properties, containers)
/// into `DICOM_JPEGXL_CORPUS_DIRECTORY`; the test is skipped when the variable
/// is unset so the default suite stays hermetic.
final class JPEGXLLibjxlCorpusTests: XCTestCase {
    private static var directory: String? {
        ProcessInfo.processInfo.environment["DICOM_JPEGXL_CORPUS_DIRECTORY"]
    }

    func test_everyLibjxlStreamDecodesExactly() throws {
        guard let dir = Self.directory else { throw XCTSkip("DICOM_JPEGXL_CORPUS_DIRECTORY unset") }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jxl") }.sorted()
        XCTAssertGreaterThan(files.count, 0, "empty corpus")
        var failures: [String] = []
        var passes = 0
        for file in files {
            let name = String(file.dropLast(4))
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(file))
            let ref = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name + ".ref.pnm"))
            do {
                let started = Date()
                let frame = try JXLDecoder().decodeModularFrame(data)
                let milliseconds = Date().timeIntervalSince(started) * 1000
                let (rw, rh, rmax, rbody) = try Self.parsePNM(ref)
                let bits = Int(frame.metadata.bitDepth.bitsPerSample)
                let maxv = (1 << bits) - 1
                guard rw == frame.width, rh == frame.height, rmax == maxv else {
                    failures.append("\(name): geometry \(frame.width)x\(frame.height)/\(maxv) vs \(rw)x\(rh)/\(rmax)")
                    continue
                }
                var own = [UInt8]()
                own.reserveCapacity(rbody.count)
                for i in 0..<(frame.width * frame.height) {
                    for c in 0..<frame.colourChannels {
                        let v = frame.planes[c][i]
                        if maxv > 255 { own.append(UInt8((v >> 8) & 0xFF)) }
                        own.append(UInt8(v & 0xFF))
                    }
                }
                if own == rbody {
                    passes += 1
                    print("JPEGXL_CORPUS \(name) \(String(format: "%.1f", milliseconds)) ms")
                } else if let first = zip(own, rbody).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
                    failures.append("\(name): first difference at byte \(first.offset)")
                } else {
                    failures.append("\(name): payload size \(own.count) vs \(rbody.count)")
                }
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertEqual(passes, files.count)
    }

    func test_truncatedAndCorruptedStreamsFailTyped() throws {
        guard let dir = Self.directory else { throw XCTSkip("DICOM_JPEGXL_CORPUS_DIRECTORY unset") }
        let names = ["gray12_53x37_e7", "rgb8_53x37_e7", "gray8_pal16_300x271", "gray12_resp_512x512", "gray1_53x37_e7",
                     "gray12_container_100x100", "gray12_prog_resp_600x520"]
        var rng = SystemRandomNumberGenerator()
        var attempts = 0
        for name in names {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name + ".jxl")) else { continue }
            for cut in stride(from: 1, to: data.count, by: max(1, data.count / 24)) {
                attempts += 1
                XCTAssertThrowsError(try JXLDecoder().decodeModularFrame(data.prefix(cut)), "\(name) cut at \(cut)") { error in
                    XCTAssertTrue(error is DecoderError, "\(error)")
                }
            }
            for _ in 0..<40 {
                var corrupted = data
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    let i = Int.random(in: 0..<corrupted.count, using: &rng)
                    corrupted[corrupted.startIndex + i] ^= UInt8.random(in: 1...255, using: &rng)
                }
                attempts += 1
                // Either a typed error or a decode; never a trap.
                _ = try? JXLDecoder().decodeModularFrame(corrupted)
            }
        }
        XCTAssertGreaterThan(attempts, 0)
    }

    static func parsePNM(_ d: Data) throws -> (Int, Int, Int, [UInt8]) {
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
        return (fields[0], fields[1], fields[2], Array(d[i...]))
    }
}
