import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

final class PrintCommandTests: XCTestCase {
    func test_commandsAreRegistered_andRejectInvalidInputBeforeNetworking() throws {
        XCTAssertTrue(try DicomTool.parseAsRoot(["print", "status"]) is PrintCommand.Status)
        let command = try PrintCommand.SCU.parse(["--max-bytes", "0", "missing.dcm"])
        XCTAssertThrowsError(try command.film.job())
        let invalid = try PrintCommand.Compose.parse(["--layout", "ROW\\1,x", "--output", "unused.png", "missing.dcm"])
        XCTAssertThrowsError(try invalid.film.job())
    }

    func test_composeWritesPNG_andPixelBudgetRejectsBeforeRendering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("print-cli-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("synthetic.dcm")
        let output = directory.appendingPathComponent("film.png")
        var data = DicomDataSet(elements: [
            .init(tag: 0x0008_0016, vr: .UI, value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            .init(tag: 0x0008_0018, vr: .UI, value: .strings(["2.25.2353001"])),
            .init(tag: 0x0028_0004, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: 0x7FE0_0010, vr: .OB, value: .bytes(Data([0, 64, 128, 255])))
        ])
        for (tag, value) in [(0x0028_0002, 1), (0x0028_0010, 2), (0x0028_0011, 2),
                             (0x0028_0100, 8), (0x0028_0101, 8), (0x0028_0102, 7), (0x0028_0103, 0)] {
            data.set(.init(tag: tag, vr: .US, value: .unsignedIntegers([UInt(value)])))
        }
        try DicomDataSetWriter.part10Data(from: data).write(to: input)
        let limited = try PrintCommand.Compose.parse(["--max-bytes", "11", "--output", output.path, input.path])
        XCTAssertThrowsError(try limited.film.job())
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let command = try PrintCommand.Compose.parse(["--output", output.path, input.path])
        try await command.run()
        let snapshot = try DicomPrintJob(snapshotPNGData: Data(contentsOf: output))
        XCTAssertEqual(snapshot.imageBoxes.first?.bitmap.width, 1024)
        XCTAssertEqual(snapshot.imageBoxes.first?.bitmap.height, 1280)
    }
}
