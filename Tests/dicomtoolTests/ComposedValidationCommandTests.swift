import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

final class ComposedValidationCommandTests: XCTestCase {
    func test_composedMode_distinguishesIncompleteFromInvalidInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = DicomDataSet(elements: [
            .init(tag: 0x00080016, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.23212402"]))
        ])
        var incomplete = metadata
        for (tag, vr) in [(0x00100010, DicomVR.PN), (0x00100020, .LO), (0x00100030, .DA), (0x00100040, .CS),
                          (0x00080020, .DA), (0x00080030, .TM), (0x00080090, .PN), (0x00080050, .SH),
                          (0x00200010, .SH), (0x00200011, .IS), (0x00200013, .IS), (0x00200020, .CS)] {
            incomplete.set(.init(tag: tag, vr: vr, value: .strings([""])))
        }
        for (tag, vr, value) in [(0x0020000D, DicomVR.UI, "2.25.23213002"), (0x0020000E, .UI, "2.25.23213003"),
                                 (0x00080064, .CS, "SYN")] {
            incomplete.set(.init(tag: tag, vr: vr, value: .strings([value])))
        }
        let file = directory.appendingPathComponent("synthetic.dcm")
        for (data, expected) in [(try DicomDataSetWriter.part10Data(from: incomplete), ExitCode(2)),
                                 (try DicomDataSetWriter.part10Data(from: metadata), ExitCode.failure), (Data(), ExitCode.failure)] {
            try data.write(to: file)
            for format in ["text", "json"] {
                var command = try ValidateCommand.parse([file.path, "--composed", "--format", format])
                XCTAssertTrue(command.composed)
                XCTAssertThrowsError(try command.run()) { XCTAssertEqual($0 as? ExitCode, expected) }
            }
        }
    }

    func test_composedMode_exitsZeroForAQualifiedProfileOnlyWithStatedFacts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sc.dcm")
        try DicomDataSetWriter.part10Data(from: DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 1, count: 12)),
            options: .init(sopInstanceUID: "2.25.23219971", studyInstanceUID: "2.25.23219972", seriesInstanceUID: "2.25.23219973",
                           seriesNumber: 1, instanceNumber: 1),
            requiredType2Attributes: .init())).write(to: file)
        let facts = ["animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "calibrated-image=no"]
        var stated = try ValidateCommand.parse([file.path, "--composed"] + facts.flatMap { ["--fact", $0] })
        XCTAssertNoThrow(try stated.run())
        var unstated = try ValidateCommand.parse([file.path, "--composed", "--fact", "animal=no"])
        XCTAssertThrowsError(try unstated.run()) { XCTAssertEqual($0 as? ExitCode, ExitCode(2)) }
        XCTAssertThrowsError(try ValidateCommand.imageConditions(from: ["animal=maybe"]))
        XCTAssertThrowsError(try ValidateCommand.imageConditions(from: ["species=no"]))
    }
}
