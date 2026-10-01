import ArgumentParser
import DicomCore
import DicomTestSupport
import Foundation
import XCTest
@testable import dicomtool

/// `dicomtool codec transcode --plan` and streamed output (#2325).
final class CodecTranscodePlanCommandTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codec-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func test_decode_malformedRegionIsRejectedBeforePublishingOutput() async throws {
        let input = directory.appendingPathComponent("ct.dcm")
        try DicomStructuralFixtures.ctSlice(index: 1).write(to: input)
        let output = directory.appendingPathComponent("pixels.raw")
        for region in ["0,nope,0,2,2", "0,,0,2,2", "0,0,2,2,", "0,0,2"] {
            var command = try XCTUnwrap(CodecCommand.parseAsRoot([
                "decode", input.path, "--output", output.path, "--region", region
            ]) as? AsyncParsableCommand)
            do {
                try await command.run()
                XCTFail("malformed region accepted: \(region)")
            } catch {
                XCTAssertEqual(error as? ExitCode, ExitCode(64))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func test_transcode_planPrintsWithoutWritingAndStreamedOutputIsPublished() async throws {
        let input = directory.appendingPathComponent("ct.dcm")
        try DicomStructuralFixtures.ctSlice(index: 1).write(to: input)
        let output = directory.appendingPathComponent("out.dcm")
        var planCommand = try CodecCommand.parseAsRoot(["transcode", input.path, "--output", output.path, "--transfer-syntax", DicomTransferSyntax.rleLossless.rawValue, "--plan", "--format", "json"])
        if var async = planCommand as? AsyncParsableCommand { try await async.run() } else { try planCommand.run() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "--plan writes nothing")
        var command = try CodecCommand.parseAsRoot(["transcode", input.path, "--output", output.path, "--transfer-syntax", DicomTransferSyntax.rleLossless.rawValue, "--progress", "--format", "json"])
        if var async = command as? AsyncParsableCommand { try await async.run() } else { try command.run() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let written = try DCMDecoder(data: try Data(contentsOf: output))
        XCTAssertEqual(written.info(for: .transferSyntaxUID), DicomTransferSyntax.rleLossless.rawValue)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".") }, "no staged leftovers")
        let bytes = try Data(contentsOf: input)
        let plan = try DicomCodecWorkflowEngine().plan(bytes, to: .rleLossless)
        XCTAssertEqual(plan.kind, .encode)
        do {
            _ = try DicomCodecWorkflowEngine().plan(bytes, to: .jpegLSNearLossless)
            XCTFail("NEAR without intent planned")
        } catch {}
    }
}
