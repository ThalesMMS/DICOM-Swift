import ArgumentParser
import Foundation
import XCTest
@testable import dicomtool
import DicomCore

final class ExtractCommandTests: XCTestCase {
    func test_boundedExport_matchesImagesAndOriginalFrameSidecars() async throws {
        let input = try makeTemporaryDICOM(pixelValues: [0, 100, 200, 300, 400, 500], rows: 1, columns: 2, frames: 3)
        defer { try? FileManager.default.removeItem(at: input) }
        let legacy = try temporaryDirectory()
        let bounded = try temporaryDirectory()
        for (directory, flags) in [(legacy, [String]()), (bounded, ["--bounded"])] {
            var command = try ExtractCommand.parse([input.path, "--output", directory.path, "--all-frames", "--metadata"] + flags)
            try await command.run()
        }
        for index in 0..<3 {
            let name = DicomImageExporter.fileName(baseName: input.deletingPathExtension().lastPathComponent,
                                                   frameIndex: index, frameCount: 3, format: .png)
            XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent(name)),
                           try Data(contentsOf: bounded.appendingPathComponent(name)))
            let actual = try Data(contentsOf: bounded.appendingPathComponent(name + ".json"))
            XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent(name + ".json")), actual)
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: actual) as? [String: Any])
            XCTAssertEqual(metadata["frameIndex"] as? Int, index)
            XCTAssertEqual(metadata["numberOfFrames"] as? Int, 3)
        }
    }

    func test_boundedExport_rejectsOverflowingFrameIndexBeforeArithmetic() async throws {
        let input = try makeTemporaryDICOM(pixelValues: [0, 100], rows: 1, columns: 2)
        defer { try? FileManager.default.removeItem(at: input) }
        var command = try ExtractCommand.parse([input.path, "--output", temporaryDirectory().appendingPathComponent("bad.png").path,
                                                "--bounded", "--frame", String(Int.max)])
        do { try await command.run(); XCTFail("Invalid frame accepted") }
        catch { XCTAssertEqual(error as? DicomImageExportError, .invalidFrame(index: Int.max, frameCount: 1)) }
    }

    func testExtractCommandExportsAllFramesWithMetadata() async throws {
        let dicomURL = try makeTemporaryDICOM(
            pixelValues: [0, 100, 200, 300, 400, 500],
            rows: 1,
            columns: 2,
            frames: 3
        )
        defer { try? FileManager.default.removeItem(at: dicomURL) }

        let outputDirectory = try temporaryDirectory()
        var command = try ExtractCommand.parse([
            dicomURL.path,
            "--output", outputDirectory.path,
            "--all-frames",
            "--metadata",
            "--overwrite"
        ])

        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("\(dicomURL.deletingPathExtension().lastPathComponent)_frame0001.png").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("\(dicomURL.deletingPathExtension().lastPathComponent)_frame0002.png").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("\(dicomURL.deletingPathExtension().lastPathComponent)_frame0003.png").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent("\(dicomURL.deletingPathExtension().lastPathComponent)_frame0001.png.json").path
        ))
    }

    func testExtractCommandExportsSelectedFrameAsJPEG() async throws {
        let dicomURL = try makeTemporaryDICOM(
            pixelValues: [0, 100, 200, 300],
            rows: 1,
            columns: 2,
            frames: 2
        )
        defer { try? FileManager.default.removeItem(at: dicomURL) }

        let outputURL = try temporaryDirectory().appendingPathComponent("selected.jpg")
        var command = try ExtractCommand.parse([
            dicomURL.path,
            "--output", outputURL.path,
            "--format", "jpeg",
            "--frame", "1",
            "--jpeg-quality", "0.8",
            "--overwrite"
        ])

        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private func makeTemporaryDICOM(
        pixelValues: [UInt16],
        rows: Int,
        columns: Int,
        frames: Int = 1
    ) throws -> URL {
        XCTAssertEqual(pixelValues.count, rows * columns * frames)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract_command_\(UUID().uuidString).dcm")

        var elements: [DicomDataElement] = [
            string(0x00080016, vr: .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "1.2.826.0.1.3680043.10.225.\(Int.random(in: 1...999999))"),
            string(.modality, vr: .CS, "CT"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            us(.rows, rows),
            us(.columns, columns),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            ds(.windowCenter, ["250"]),
            ds(.windowWidth, ["500"]),
            bytes(.pixelData, vr: .OW, Data(littleEndianBytes(values: pixelValues)))
        ]

        if frames > 1 {
            let pixelDataIndex = elements.firstIndex { $0.tag == DicomTag.pixelData.rawValue } ?? elements.count
            elements.insert(string(.numberOfFrames, vr: .IS, String(frames)), at: pixelDataIndex)
        }

        let data = try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements))
        try data.write(to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        string(tag.rawValue, vr: vr, value)
    }

    private func string(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    private func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)]))
    }

    private func ds(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
    }

    private func bytes(_ tag: DicomTag, vr: DicomVR, _ value: Data) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .bytes(value))
    }

    private func littleEndianBytes(values: [UInt16]) -> [UInt8] {
        values.flatMap { value -> [UInt8] in
            let little = value.littleEndian
            return [UInt8(truncatingIfNeeded: little), UInt8(truncatingIfNeeded: little >> 8)]
        }
    }
}
