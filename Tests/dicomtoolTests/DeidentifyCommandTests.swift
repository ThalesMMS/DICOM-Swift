import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

/// `dicomtool deidentify` (#2324): cohort session across inputs, dry run, report without values, rejection exit.
final class DeidentifyCommandTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("deidentify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func instance(_ name: String, uid: String, references: String, burnedIn: String = "NO") throws -> URL {
        var dataSet = DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: 3, count: 12)),
            options: .init(sopInstanceUID: uid, studyInstanceUID: "2.25.23359001", seriesInstanceUID: "2.25.23359002",
                           patientName: "SENTINEL^CLI", patientID: "SENT-CLI", seriesNumber: 1, instanceNumber: 1),
            requiredType2Attributes: .init(studyDate: "20240301"))
        dataSet.set(DicomDataElement(tag: 0x00280301, vr: .CS, value: .strings([burnedIn])))
        dataSet.set(DicomDataElement(tag: 0x00081140, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
            DicomDataElement(tag: 0x00081150, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: 0x00081155, vr: .UI, value: .strings([references]))
        ]))])))
        let url = directory.appendingPathComponent(name)
        try DicomDataSetWriter.part10Data(from: dataSet).write(to: url)
        return url
    }

    func test_deidentify_keepsCohortReferencesWritesReportAndKeyAndRejectsBurnedIn() throws {
        let a = try instance("a.dcm", uid: "2.25.23359011", references: "2.25.23359012")
        let b = try instance("b.dcm", uid: "2.25.23359012", references: "2.25.23359011")
        let out = directory.appendingPathComponent("OUT"), report = directory.appendingPathComponent("report.json"), key = directory.appendingPathComponent("key.json")
        var dry = try DeidentifyCommand.parse([a.path, b.path, "--dry-run", "--report", report.path])
        try dry.run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        let dryReport = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(dryReport["dryRun"] as? Bool, true)
        var command = try DeidentifyCommand.parse([a.path, b.path, "--output", out.path, "--option", "retainLongitudinalModifiedDates", "--date-shift=-10",
                                                   "--report", report.path, "--reversal-key", key.path])
        try command.run()
        let outA = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(contentsOf: out.appendingPathComponent("a.dcm")))
        let outB = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(contentsOf: out.appendingPathComponent("b.dcm")))
        XCTAssertEqual(outA[0x00081140]?.sequenceItems.first?[0x00081155]?.stringValue, outB.string(for: .sopInstanceUID))
        XCTAssertEqual(outB[0x00081140]?.sequenceItems.first?[0x00081155]?.stringValue, outA.string(for: .sopInstanceUID))
        XCTAssertEqual(outA.string(for: .studyInstanceUID), outB.string(for: .studyInstanceUID))
        XCTAssertEqual(outA.string(for: .patientName), nil)
        XCTAssertEqual(outA[0x00100010]?.value, .empty)
        XCTAssertEqual(outA.string(for: .studyDate), "20240220")
        XCTAssertEqual(outA[0x00120062]?.stringValue, "YES")
        XCTAssertEqual(try Data(contentsOf: a).count > 0, true, "inputs untouched")
        XCTAssertEqual(try DCMDecoder(contentsOf: a).info(for: .patientName), "SENTINEL^CLI")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        let instances = try XCTUnwrap(json["instances"] as? [[String: Any]])
        XCTAssertEqual(instances.map { $0["classification"] as? String }, ["deidentifiedPerProfile", "deidentifiedPerProfile"])
        XCTAssertFalse(String(decoding: try Data(contentsOf: report), as: UTF8.self).contains("SENTINEL"))
        XCTAssertFalse(String(decoding: try Data(contentsOf: report), as: UTF8.self).contains("2.25.23359011"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int, 0o600)
        let reversal = try JSONDecoder().decode(DicomDeidentificationSession.ReversalKey.self, from: Data(contentsOf: key))
        XCTAssertEqual(reversal.uidMap["2.25.23359011"], outA.string(for: .sopInstanceUID))
        XCTAssertEqual(reversal.dateShiftDays, -10)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: out.path).contains { $0.hasPrefix(".") })
        // Resuming from the key reproduces the same identities; existing outputs are never overwritten.
        let out2 = directory.appendingPathComponent("OUT2")
        var resumed = try DeidentifyCommand.parse([a.path, "--output", out2.path, "--option", "retainLongitudinalModifiedDates", "--resume-key", key.path])
        try resumed.run()
        XCTAssertEqual(try DCMDecoder(contentsOf: out2.appendingPathComponent("a.dcm")).info(for: .sopInstanceUID), outA.string(for: .sopInstanceUID))
        var overwrite = try DeidentifyCommand.parse([a.path, "--output", out.path])
        XCTAssertThrowsError(try overwrite.run())
        // Rejection: exit 1, nothing written for the rejected input, report says why.
        let burned = try instance("c.dcm", uid: "2.25.23359013", references: "2.25.23359011", burnedIn: "YES")
        let out3 = directory.appendingPathComponent("OUT3")
        var rejecting = try DeidentifyCommand.parse([burned.path, "--output", out3.path, "--report", report.path])
        XCTAssertThrowsError(try rejecting.run()) { XCTAssertEqual($0 as? ExitCode, ExitCode(1)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out3.appendingPathComponent("c.dcm").path))
        let rejectedReport = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(((rejectedReport["instances"] as? [[String: Any]])?.first?["rejection"]) as? String, "burnedInAnnotation")
        var accepted = try DeidentifyCommand.parse([burned.path, "--output", out3.path, "--burned-in", "flag"])
        XCTAssertNoThrow(try accepted.run())
        var badOption = try DeidentifyCommand.parse([a.path, "--output", out3.path, "--option", "cleanEverything"])
        XCTAssertThrowsError(try badOption.run())
        var conflicting = try DeidentifyCommand.parse([a.path, "--output", out3.path, "--option", "retainLongitudinalFullDates", "--option", "retainLongitudinalModifiedDates"])
        XCTAssertThrowsError(try conflicting.run())
        var inside = try DeidentifyCommand.parse([out.appendingPathComponent("a.dcm").path, "--output", out.path])
        XCTAssertThrowsError(try inside.run())
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == DeidentifyCommand.self })
    }

    func test_reversalKey_inputAliasesAreRejectedBeforeAnyOutput() throws {
        let directoryAlias = directory.appendingPathComponent("directory-alias")
        try FileManager.default.createSymbolicLink(at: directoryAlias, withDestinationURL: directory)
        for variant in ["direct", "directory-link", "file-link"] {
            let first = try instance("a-\(variant).dcm", uid: "2.25.23359041", references: "2.25.23359042")
            let second = try instance("b-\(variant).dcm", uid: "2.25.23359042", references: "2.25.23359041")
            let original = try Data(contentsOf: second)
            let key: URL
            switch variant {
            case "directory-link": key = directoryAlias.appendingPathComponent(second.lastPathComponent)
            case "file-link":
                key = directory.appendingPathComponent("key-alias")
                try FileManager.default.createSymbolicLink(at: key, withDestinationURL: second)
            default: key = second
            }
            let output = directory.appendingPathComponent("OUT-\(variant)")
            var command = try DeidentifyCommand.parse([
                first.path, second.path, "--output", output.path, "--reversal-key", key.path
            ])
            XCTAssertThrowsError(try command.run())
            XCTAssertEqual(try Data(contentsOf: second), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func test_reversalKey_laterCollisionKeepsEarlierOutputRecoverable() throws {
        let firstUID = "2.25.23359021"
        let first = try instance("a.dcm", uid: firstUID, references: "2.25.23359022")
        let second = try instance("b.dcm", uid: "2.25.23359022", references: firstUID)
        let output = directory.appendingPathComponent("OUT")
        let key = directory.appendingPathComponent("key.json")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sentinel = Data("existing destination".utf8)
        try sentinel.write(to: output.appendingPathComponent("b.dcm"))
        var command = try DeidentifyCommand.parse([
            first.path, second.path, "--output", output.path, "--reversal-key", key.path
        ])
        XCTAssertThrowsError(try command.run())
        let published = try DCMDecoder(contentsOf: output.appendingPathComponent("a.dcm"))
        let reversal = try JSONDecoder().decode(DicomDeidentificationSession.ReversalKey.self, from: Data(contentsOf: key))
        XCTAssertEqual(reversal.uidMap[firstUID], published.info(for: .sopInstanceUID))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("b.dcm")), sentinel)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int, 0o600)
    }

    func test_reversalKey_publicationFailureDoesNotPublishOutput() throws {
        let input = try instance("a.dcm", uid: "2.25.23359021", references: "2.25.23359022")
        let output = directory.appendingPathComponent("OUT")
        let unavailableKey = directory.appendingPathComponent("missing/key.json")
        var command = try DeidentifyCommand.parse([
            input.path, "--output", output.path, "--reversal-key", unavailableKey.path
        ])
        XCTAssertThrowsError(try command.run())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func test_recursiveInputs_duplicateBasenamesHaveDistinctOutputsAndReportPaths() throws {
        let input = directory.appendingPathComponent("INPUT")
        for folder in ["one", "two"] {
            try FileManager.default.createDirectory(at: input.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        _ = try instance("INPUT/one/image.dcm", uid: "2.25.23359031", references: "2.25.23359032")
        _ = try instance("INPUT/two/image.dcm", uid: "2.25.23359032", references: "2.25.23359031")
        let output = directory.appendingPathComponent("OUT")
        let report = directory.appendingPathComponent("report.json")
        var command = try DeidentifyCommand.parse([input.path, "--output", output.path, "--report", report.path])
        try command.run()
        let first = try DCMDecoder(contentsOf: output.appendingPathComponent("one/image.dcm"))
        let second = try DCMDecoder(contentsOf: output.appendingPathComponent("two/image.dcm"))
        XCTAssertNotEqual(first.info(for: .sopInstanceUID), second.info(for: .sopInstanceUID))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        let entries = try XCTUnwrap(json["instances"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["input"] as? String }, ["one/image.dcm", "two/image.dcm"])
        XCTAssertEqual(entries.compactMap { $0["output"] as? String }, ["one/image.dcm", "two/image.dcm"])
    }

    func test_reversalKey_replacingPublicFilePublishesPrivatePermissions() throws {
        let input = try instance("a.dcm", uid: "2.25.23359011", references: "2.25.23359012")
        let key = directory.appendingPathComponent("key.json")
        try Data("old key".utf8).write(to: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key.path)
        var command = try DeidentifyCommand.parse([
            input.path, "--output", directory.appendingPathComponent("OUT").path, "--reversal-key", key.path
        ])
        try command.run()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNoThrow(try JSONDecoder().decode(DicomDeidentificationSession.ReversalKey.self, from: Data(contentsOf: key)))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
            $0.hasPrefix(".deidentify-key-")
        })
    }
}
