import ArgumentParser
import DicomCodecs
import DicomCore
import DicomTestSupport
import Foundation
import XCTest
@testable import dicomtool

final class CodecProgressiveEncodingCommandTests: XCTestCase {
    private func run(_ arguments: [String]) async throws {
        var command = try CodecCommand.parseAsRoot(arguments)
        if var async = command as? AsyncParsableCommand { try await async.run() } else { try command.run() }
    }

    func test_progressiveFlags_reachPlanAndPublishedCodestream() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codec-progressive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.dcm"), output = root.appendingPathComponent("output.dcm")
        // Structural fixture defaults contain opaque words; supply actual 12-bit samples for pixel fidelity.
        let pixels = Data((0..<16).flatMap { [UInt8($0 * 11), UInt8(0)] })
        try DicomStructuralFixtures.ctSlice(index: 1, pixels: pixels).write(to: input)
        let arguments = ["transcode", input.path, "--output", output.path, "--transfer-syntax", DicomTransferSyntax.jpeg2000Lossless.rawValue,
                         "--j2k-layers", "2", "--j2k-decompositions", "1", "--j2k-progression", "rlcp", "--format", "json"]
        try await run(arguments + ["--plan"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try await run(arguments)
        let decoder = try await DCMDecoder(contentsOf: output)
        let frames = try XCTUnwrap(decoder.makeEncapsulatedPixelFrameReader())
        let header = try DicomJ2KCodestreamInspector.inspect(frames.frameData(at: 0))
        XCTAssertEqual(header.layerCount, 2); XCTAssertEqual(header.decompositionLevels, 1)
        XCTAssertEqual(header.progressionOrder, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".") })
    }

    func test_invalidProgressionAndLayerCount_exit64WithoutWriting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codec-progressive-invalid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("source.dcm"), output = root.appendingPathComponent("output.dcm")
        // Structural fixture defaults contain opaque words; supply actual 12-bit samples for pixel fidelity.
        let pixels = Data((0..<16).flatMap { [UInt8($0 * 11), UInt8(0)] })
        try DicomStructuralFixtures.ctSlice(index: 1, pixels: pixels).write(to: input)
        let base = ["transcode", input.path, "--output", output.path, "--transfer-syntax", DicomTransferSyntax.jpeg2000Lossless.rawValue]
        for options in [["--j2k-progression", "pcrl"], ["--j2k-progression", "bogus"], ["--j2k-layers", "0"], ["--j2k-decompositions", "99"]] {
            do { try await run(base + options); XCTFail("Accepted \(options)") }
            catch { XCTAssertEqual((error as? ExitCode)?.rawValue, 64, "\(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
