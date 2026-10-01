import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

final class ConvertCommandTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func dataSet() throws -> DicomDataSet {
        DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 7, count: 12)),
            options: .init(sopInstanceUID: "2.25.23229971", studyInstanceUID: "2.25.23229972", seriesInstanceUID: "2.25.23229973",
                           seriesNumber: 1, instanceNumber: 1),
            requiredType2Attributes: .init())
            .setting(.init(tag: 0x00100010, vr: .PN, value: .strings(["Convert^Case=変換^症例"])))
    }

    /// The Part 10 reader also surfaces the file meta group; the comparison covers the data set proper.
    private func withoutFileMeta(_ dataSet: DicomDataSet) -> DicomDataSet {
        DicomDataSet(elements: dataSet.elements.filter { $0.group != 0x0002 })
    }

    func test_convert_roundTripsPart10ThroughJSONAndXML() throws {
        let original = try dataSet()
        let part10 = directory.appendingPathComponent("in.dcm")
        try DicomDataSetWriter.part10Data(from: original).write(to: part10)
        let json = directory.appendingPathComponent("out.json"), xml = directory.appendingPathComponent("out.xml")
        let back = directory.appendingPathComponent("back.dcm"), viaXML = directory.appendingPathComponent("via-xml.dcm")
        var toJSON = try ConvertCommand.parse([part10.path, "--to", "json", "--output", json.path])
        try toJSON.run()
        var toXML = try ConvertCommand.parse([json.path, "--to", "xml", "--output", xml.path])
        try toXML.run()
        var toDICOM = try ConvertCommand.parse([xml.path, "--to", "dicom", "--output", back.path])
        try toDICOM.run()
        var jsonToDICOM = try ConvertCommand.parse([json.path, "--to", "dicom", "--output", viaXML.path])
        try jsonToDICOM.run()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        XCTAssertEqual((object["00100010"] as? [String: Any])?["Value"] as? [[String: String]], [["Alphabetic": "Convert^Case", "Ideographic": "変換^症例"]])
        XCTAssertNotNil((object["7FE00010"] as? [String: Any])?["InlineBinary"])
        XCTAssertTrue(String(decoding: try Data(contentsOf: xml), as: UTF8.self).contains("<NativeDicomModel xmlns=\"http://dicom.nema.org/PS3.19/models/NativeDICOM\" xml:space=\"preserve\">"))
        for output in [back, viaXML] {
            let decoder = try DCMDecoder(contentsOf: output)
            let reparsed = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
            XCTAssertEqual(reparsed.string(for: .patientName), "Convert^Case=変換^症例")
            XCTAssertEqual(reparsed.element(for: .pixelData)?.value, .bytes(Data(repeating: 7, count: 12)))
            XCTAssertEqual(try DicomJSONCodec.encode(withoutFileMeta(reparsed)), try DicomJSONCodec.encode(original))
        }
    }

    func test_convert_reportsBulkDataOmissionAndRefusesLossyOutputs() throws {
        let json = directory.appendingPathComponent("bulk.json")
        try Data(#"{"00080016":{"vr":"UI","Value":["1.2.840.10008.5.1.4.1.1.7"]},"7FE00010":{"vr":"OB","BulkDataURI":"https://a.example/px"}}"#.utf8).write(to: json)
        var toXML = try ConvertCommand.parse([json.path, "--to", "xml", "--output", directory.appendingPathComponent("bulk.xml").path])
        XCTAssertNoThrow(try toXML.run())
        var toDICOM = try ConvertCommand.parse([json.path, "--to", "dicom", "--output", directory.appendingPathComponent("bulk.dcm").path])
        XCTAssertThrowsError(try toDICOM.run()) { XCTAssertEqual($0 as? ExitCode, ExitCode(65)) }
        let bad = directory.appendingPathComponent("bad.json")
        try Data(#"{"00280010":{"vr":"US","Value":[70000]}}"#.utf8).write(to: bad)
        var badCommand = try ConvertCommand.parse([bad.path, "--to", "xml"])
        XCTAssertThrowsError(try badCommand.run()) { XCTAssertEqual($0 as? ExitCode, ExitCode(65)) }
        let unknown = directory.appendingPathComponent("unknown.bin")
        try Data([1, 2, 3]).write(to: unknown)
        var unknownCommand = try ConvertCommand.parse([unknown.path, "--to", "json"])
        XCTAssertThrowsError(try unknownCommand.run())
        var tooLarge = try ConvertCommand.parse([json.path, "--to", "xml", "--maximum-bytes", "8"])
        XCTAssertThrowsError(try tooLarge.run())
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == ConvertCommand.self })
    }
}
