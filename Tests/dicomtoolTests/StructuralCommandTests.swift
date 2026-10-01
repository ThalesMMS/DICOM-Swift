import ArgumentParser
import DicomCore
import DicomTestSupport
import Foundation
import XCTest
@testable import dicomtool

/// `dicomtool diff`, `edit` and `dcmdir` (#2323).
final class StructuralCommandTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("structural-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func secondaryCapture(_ instance: Int, name: String = "sc") throws -> URL {
        var dataSet = DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: Data(repeating: UInt8(instance), count: 12)),
            options: .init(sopInstanceUID: "2.25.2325990\(instance)", studyInstanceUID: "2.25.23259902", seriesInstanceUID: "2.25.23259903",
                           patientName: "Cli^Case", patientID: "C-1", seriesNumber: 1, instanceNumber: instance),
            requiredType2Attributes: .init())
        dataSet.set(DicomDataElement(tag: 0x00082112, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
            DicomDataElement(tag: 0x00081150, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            DicomDataElement(tag: 0x00081155, vr: .UI, value: .strings(["2.25.2325990\(instance)"]))
        ]))])))
        let url = directory.appendingPathComponent("\(name)\(instance).dcm")
        try DicomDataSetWriter.part10Data(from: dataSet).write(to: url)
        return url
    }

    func test_edit_thenDiff_reportsExactlyTheEdits() throws {
        let source = try secondaryCapture(1)
        let original = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("edited.dcm")
        var edit = try EditCommand.parse([source.path, "--output", output.path, "--set", "00100010=Edited^Case", "--set", "(0008,2112)[0]/(0008,1160):IS=1\\2",
                                          "--set", "00181020:LO=", "--remove", "00100020", "--new-uid", "instance", "--replace-uid", "2.25.23259903=2.25.23259993"])
        try edit.run()
        let reopened = try DCMDecoder(contentsOf: output)
        XCTAssertEqual(reopened.info(for: .patientName), "Edited^Case")
        XCTAssertEqual(reopened.info(for: .seriesInstanceUID), "2.25.23259993")
        XCTAssertNotEqual(reopened.info(for: .sopInstanceUID), "2.25.23259901")
        XCTAssertEqual(reopened.info(for: 0x00020003), reopened.info(for: .sopInstanceUID))
        XCTAssertEqual(reopened.dataSet[0x00082112]?.sequenceItems[0][0x00081155]?.stringValue, reopened.info(for: .sopInstanceUID))
        XCTAssertEqual(reopened.dataSet[0x00082112]?.sequenceItems[0][0x00081160]?.stringValues, ["1", "2"])
        XCTAssertEqual(reopened.dataSet[0x00181020]?.value, .empty)
        XCTAssertFalse(reopened.dataSet.contains(.patientID))
        XCTAssertEqual(try Data(contentsOf: source), original, "source untouched")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".edited") })

        var diff = try DiffCommand.parse([source.path, output.path, "--ignore-uids"])
        XCTAssertThrowsError(try diff.run()) { XCTAssertEqual($0 as? ExitCode, ExitCode(1)) }
        var same = try DiffCommand.parse([source.path, source.path])
        XCTAssertNoThrow(try same.run())
        var ignoring = try DiffCommand.parse([source.path, output.path, "--ignore-uids", "--ignore", "00100010", "--ignore", "00100020", "--ignore", "00181020", "--ignore", "00081160"])
        XCTAssertNoThrow(try ignoring.run())
        let sameOutput = directory.appendingPathComponent("edited2.dcm")
        var again = try EditCommand.parse([source.path, "--output", sameOutput.path, "--set", "00100010=Edited^Case"])
        try again.run()
        var jsonDiff = try DiffCommand.parse([source.path, sameOutput.path, "--format", "json"])
        XCTAssertThrowsError(try jsonDiff.run())
    }

    func test_edit_nonUIIdentityOverride_isRejectedBeforeWriting() throws {
        let source = try secondaryCapture(2)
        let original = try Data(contentsOf: source)
        for tag in ["00080018", "0020000D", "0020000E", "00200052"] {
            let output = directory.appendingPathComponent("identity-\(tag).dcm")
            var command = try EditCommand.parse([source.path, "--output", output.path, "--set", "\(tag):LO=2.25.1"])
            XCTAssertThrowsError(try command.run()) { error in
                guard case CLIError.validationFailed(_, let errors) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(errors.contains { $0.contains("identity UID") }, "\(errors)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func test_edit_refusesUnsafeRequests() throws {
        let source = try secondaryCapture(2)
        let output = directory.appendingPathComponent("out.dcm")
        func failure(_ arguments: [String]) -> Error? {
            do { var command = try EditCommand.parse([source.path, "--output", output.path] + arguments); try command.run(); return nil } catch { return error }
        }
        XCTAssertNotNil(failure(["--set", "00080018=2.25.1"]), "identity through --set")
        XCTAssertNotNil(failure(["--set", "00280010:US=4"]), "pixel structure")
        XCTAssertNotNil(failure(["--remove", "00020010"]), "file meta")
        XCTAssertNotNil(failure(["--remove", "00080005", "--set", "00100010=変換"]), "charset")
        XCTAssertNotNil(failure(["--set", "00990010=x"]), "unknown VR")
        XCTAssertNotNil(failure(["--set", "00280010:XX=4"]), "unknown VR code")
        XCTAssertNotNil(failure(["--new-uid", "patient"]))
        XCTAssertNotNil(failure(["--replace-uid", "nonsense"]))
        XCTAssertNotNil(failure(["--set", "00181020:LO=x", "--output", source.path]), "never in place")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try EditCommand.value("1\\2", vr: .US, argument: "a"), .unsignedIntegers([1, 2]))
        XCTAssertEqual(try EditCommand.value("(0010,0010)", vr: .AT, argument: "a"), .unsignedIntegers([0x00100010]))
        XCTAssertEqual(try EditCommand.value("-1", vr: .SS, argument: "a"), .signedIntegers([-1]))
        XCTAssertEqual(try EditCommand.value("1.5", vr: .FD, argument: "a"), .floats([1.5]))
        XCTAssertEqual(try EditCommand.value("00ff", vr: .OB, argument: "a"), .bytes(Data([0, 255])))
        XCTAssertThrowsError(try EditCommand.value("x", vr: .US, argument: "a"))
        XCTAssertThrowsError(try EditCommand.value("x", vr: .SQ, argument: "a"))
        XCTAssertThrowsError(try EditCommand.value("0f0", vr: .OB, argument: "a"))
        for value in ["ＦＦ", "１２", "١٢", "abＺ0", "gg"] {
            XCTAssertThrowsError(try EditCommand.value(value, vr: .OB, argument: "a"))
        }
    }

    func test_dcmdir_buildsAddsValidatesAndLists() async throws {
        let first = try secondaryCapture(3), second = try secondaryCapture(4)
        let root = directory.appendingPathComponent("FILESET")
        var build = try DcmdirCommand.Build.parse([first.path, "--output", root.path, "--id", "TEST"])
        try await build.run()
        var add = try DcmdirCommand.Add.parse([root.path, second.path])
        try await add.run()
        var validate = try DcmdirCommand.Validate.parse([root.path])
        XCTAssertNoThrow(try validate.run())
        var list = try DcmdirCommand.List.parse([root.appendingPathComponent("DICOMDIR").path])
        XCTAssertNoThrow(try list.run())
        XCTAssertEqual(try DicomDirectoryReader.read(from: root.appendingPathComponent("DICOMDIR")).patients.first?.studies.first?.series.first?.images.count, 2)
        try FileManager.default.removeItem(at: root.appendingPathComponent("IMAGES/I0000002"))
        var broken = try DcmdirCommand.Validate.parse([root.path])
        XCTAssertThrowsError(try broken.run()) { XCTAssertEqual($0 as? ExitCode, ExitCode(1)) }
        var existing = try DcmdirCommand.Build.parse([first.path, "--output", root.path])
        do { try await existing.run(); XCTFail("existing destination accepted") } catch {}
        var missing = try DcmdirCommand.Validate.parse([directory.appendingPathComponent("nope").path])
        XCTAssertThrowsError(try missing.run())
        let expanded = try DcmdirCommand.expand([directory.path]).map(\.standardizedFileURL.path)
        XCTAssertTrue(expanded.contains(root.appendingPathComponent("DICOMDIR").standardizedFileURL.path))
        XCTAssertTrue(expanded.contains(root.appendingPathComponent("IMAGES/I0000001").standardizedFileURL.path))
        XCTAssertEqual(expanded.count, 4, "sc3, sc4, DICOMDIR, I0000001; the removed I0000002 excluded")
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == DcmdirCommand.self })
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == DiffCommand.self })
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == EditCommand.self })
    }

    func test_split_and_merge_commandsPublishAtomicallyAndRefuseInPlaceOutputs() throws {
        let slices = try (1...3).map { index -> URL in
            let url = directory.appendingPathComponent("ct\(index).dcm")
            try DicomStructuralFixtures.ctSlice(index: index, position: [0, 0, Double(index)]).write(to: url)
            return url
        }
        let merged = directory.appendingPathComponent("merged.dcm")
        var merge = try MergeCommand.parse(slices.map(\.path) + ["--output", merged.path])
        try merge.run()
        XCTAssertEqual(try DCMDecoder(contentsOf: merged).nImages, 3)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".merged") })
        var again = try MergeCommand.parse([directory.path, "--output", merged.path])
        XCTAssertThrowsError(try again.run(), "existing output without --force")
        var inPlace = try MergeCommand.parse(slices.map(\.path) + ["--output", slices[0].path, "--force"])
        XCTAssertThrowsError(try inPlace.run())
        var incompatible = try MergeCommand.parse([slices[0].path, slices[0].path, "--output", directory.appendingPathComponent("dup.dcm").path])
        XCTAssertThrowsError(try incompatible.run()) { XCTAssertTrue("\($0)".contains("appears more than once"), "\($0)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dup.dcm").path))

        let split = directory.appendingPathComponent("SPLIT", isDirectory: true)
        var splitCommand = try SplitCommand.parse([merged.path, "--output", split.path])
        try splitCommand.run()
        let outputs = try FileManager.default.contentsOfDirectory(atPath: split.path).sorted()
        XCTAssertEqual(outputs, ["000001.dcm", "000002.dcm", "000003.dcm"])
        XCTAssertEqual(try DCMDecoder(contentsOf: split.appendingPathComponent("000002.dcm")).info(for: .imagePositionPatient), "0\\0\\2")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".SPLIT") })
        var existing = try SplitCommand.parse([merged.path, "--output", split.path])
        XCTAssertThrowsError(try existing.run())
        var single = try SplitCommand.parse([slices[0].path, "--output", directory.appendingPathComponent("NOPE").path])
        XCTAssertThrowsError(try single.run()) { XCTAssertTrue("\($0)".contains("not a splittable"), "\($0)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("NOPE").path))
        var diff = try DiffCommand.parse([slices[1].path, split.appendingPathComponent("000002.dcm").path, "--ignore-uids", "--ignore", "00200013", "--ignore", "00080008",
                                         "--ignore", "00082112", "--ignore", "00082111", "--ignore", "00180088", "--ignore", "00080023", "--ignore", "00080033"])
        XCTAssertNoThrow(try diff.run(), "merge then split reproduces the classic slice")
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == SplitCommand.self })
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == MergeCommand.self })
    }
}
