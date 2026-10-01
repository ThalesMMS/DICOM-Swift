import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

final class NonRasterCommandTests: XCTestCase {
    func test_waveform_boundedExport_preservesPhysicalValuesAndPadding() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cli-waveform-\(UUID()).dcm")
        defer { try? FileManager.default.removeItem(at: url) }
        try DicomWaveformBuilder.write(multiplexGroups: [.init(samplingFrequency: 500,
            paddingValue: try .init(rawValue: -32768, interpretation: .signed16),
            channels: [.init(sensitivity: 2, sensitivityUnits: .init(codeValue: "mV", codingSchemeDesignator: "UCUM"),
                samples: [1, -32768, 3, 4])])], to: url,
            annotations: [.init(referencedChannels: [.init(multiplexGroupNumber: 1, channelNumber: 1)],
                text: "Synthetic", temporalRangeType: .point, referencedSamplePositions: [1])])
        let source = try await DicomByteSource.openFile(url)
        let reader = try await DicomWaveformSegmentReader.open(source: source)
        let inspection = try WaveformCommand.inspectionJSON(reader.index)
        XCTAssertTrue(inspection.contains("Synthetic"))
        XCTAssertTrue(inspection.contains("mV"))
        let before = await source.metrics
        let window = try await reader.samples(group: 1, channels: [1], sampleRange: 1..<3)
        let after = await source.metrics
        XCTAssertEqual(after.receivedBytes - before.receivedBytes, 4)
        let csv = try WaveformCommand.Export.output(window, format: "csv")
        XCTAssertTrue(csv.contains("1,0.002,,\"mV\""))
        XCTAssertTrue(csv.contains("1,0.004,6.0,\"mV\""))
        let json = try WaveformCommand.Export.output(window, format: "json")
        XCTAssertTrue(json.contains("null"))
        await source.close()
        var command = try WaveformCommand.Export.parse([url.path, "--group", "1", "--channels", "1",
            "--start", "0.002", "--end", "0.006", "--format", "csv"])
        try await command.run()
    }

    func test_document_extract_keepsPayloadBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cli-document-\(UUID()).dcm")
        let out = url.appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: out) }
        let payload = Data("%PDF-1.7\nSynthetic\n%%EOF".utf8)
        try DicomEncapsulatedDocumentBuilder.part10Data(documentData: payload,
            options: .init(kind: .pdf, documentTitle: "CLI fixture")).write(to: url)
        var command = try DocumentCommand.Extract.parse([url.path, out.path])
        try await command.run()
        XCTAssertEqual(try Data(contentsOf: out), payload)
        let document = try await DocumentCommand.load(url.path)
        let info = try DocumentCommand.informationJSON(document)
        XCTAssertTrue(info.contains("plausible"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any])
        XCTAssertEqual(object["mimeType"] as? String, "application/pdf")
    }

    func test_video_inspectAndExtract_preserveOriginalStream() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DicomCoreTests/Fixtures/Video/known-pframes.h264")
        let stream = try Data(contentsOf: fixture)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cli-video-\(UUID()).dcm")
        let out = url.appendingPathExtension("h264")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: out) }
        let pixels = try DicomVideoPixelData(streamData: stream, transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            columns: 128, rows: 96, numberOfFrames: 96, frameTimeMilliseconds: 1000 / 12)
        try DicomVideoBuilder.write(video: pixels, to: url)
        let video = try await VideoCommand.load(url.path)
        var command = try VideoCommand.ExtractStream.parse([url.path, out.path])
        try await command.run()
        XCTAssertEqual(try Data(contentsOf: out), video.streamData)
        let json = try VideoCommand.inspectionJSON(video)
        XCTAssertTrue(json.contains("presentationIndex"))
        XCTAssertTrue(json.contains("keyFrame"))
        #if canImport(AVFoundation)
        let container = url.appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: container) }
        var remux = try VideoCommand.Remux.parse([url.path, container.path])
        try await remux.run()
        let data = try Data(contentsOf: container)
        XCTAssertEqual(String(decoding: data[4..<8], as: UTF8.self), "ftyp")
        #endif
    }
}
