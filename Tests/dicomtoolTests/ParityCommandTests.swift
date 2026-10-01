import ArgumentParser
import ImageIO
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

/// Acceptance for #2365: every parity command runs the same library entry point as the API over the same input,
/// including partial failure, cancellation, stdin/stdout and operation without a backend/corpus.
final class ParityCommandTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parity-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    // MARK: fixtures

    private func gray16(frames: Int = 1, sopInstanceUID: String = "2.25.2365201") throws -> DicomDataSet {
        var bytes = Data()
        for frame in 0..<frames { for index in 0..<12 { let raw = UInt16(frame * 100 + index); bytes.append(UInt8(raw & 0xFF)); bytes.append(UInt8(raw >> 8)) } }
        let pixelData = try DicomSecondaryCapturePixelData(data: Data(bytes.prefix(24)), columns: 4, rows: 3, samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2",
                                                          bitsAllocated: 16, bitsStored: 12, highBit: 11)
        var dataSet = DicomSecondaryCaptureBuilder.dataSet(pixelData: pixelData, options: .init(sopInstanceUID: sopInstanceUID, studyInstanceUID: "2.25.2365202",
                                                                                                  seriesInstanceUID: "2.25.2365203", patientName: "Parity^CLI", patientID: "P2365C", seriesNumber: 1, instanceNumber: 1))
        if frames > 1 {
            dataSet.set(.init(tag: 0x0028_0008, vr: .IS, value: .strings([String(frames)])))
            dataSet.set(.init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(bytes)))
        }
        dataSet.set(.init(tag: 0x0028_0030, vr: .DS, value: .strings(["0.5", "0.5"])))
        return dataSet
    }

    private func part10(_ dataSet: DicomDataSet) throws -> Data {
        try DicomDataSetWriter.part10Data(from: dataSet, options: .init(mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID), mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)))
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func capture(stdin: Data? = nil, _ action: () async throws -> Void) async throws -> Data {
        let out = directory.appendingPathComponent("stdout-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        fflush(stdout)
        let savedOut = dup(STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        var savedIn: Int32 = -1
        if let stdin {
            let inFile = directory.appendingPathComponent("stdin-\(UUID().uuidString)")
            try stdin.write(to: inFile)
            let inHandle = try FileHandle(forReadingFrom: inFile)
            savedIn = dup(STDIN_FILENO)
            dup2(inHandle.fileDescriptor, STDIN_FILENO)
        }
        defer {
            fflush(stdout); dup2(savedOut, STDOUT_FILENO); close(savedOut); try? handle.close()
            if savedIn >= 0 { dup2(savedIn, STDIN_FILENO); close(savedIn) }
        }
        try await action()
        fflush(stdout)
        return try Data(contentsOf: out)
    }

    private func run(_ args: [String], stdin: Data? = nil) async throws -> Data {
        var command = try DicomTool.parseAsRoot(args)
        return try await capture(stdin: stdin) {
            if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() }
        }
    }

    private func json(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data) }

    private func canonical<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try JSONSerialization.jsonObject(with: try encoder.encode(value))
    }

    // MARK: uid

    func test_uid_generateCheckAndListAgreeWithAPI() async throws {
        let generated = String(decoding: try await run(["uid", "generate", "--count", "3"]), as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(generated.count, 3)
        XCTAssertTrue(generated.allSatisfy { DicomDataSetEditor.isValidUID(String($0)) })
        let check = try json(try await run(["uid", "check", "1.2.840", "--json"])) as? [[String: String]]
        XCTAssertEqual(check, [["uid": "1.2.840", "valid": "true"]])
        await XCTAssertThrowsErrorAsync({ try await self.run(["uid", "check", "1.2.840", "not-a-uid"]) }) { XCTAssertEqual(($0 as? ExitCode)?.rawValue, 1) }
        let input = try file("in.dcm", try part10(try gray16()))
        let listedRaw = try await run(["uid", "list", input.path, "--json"])
        let listed = try XCTUnwrap(try json(listedRaw) as? [String: Any])
        let api = DicomPart10Rewriter().inspectUIDs(in: try await DCMDecoder(contentsOf: input).dataSet)
        XCTAssertEqual(listed["sopInstanceUID"] as? String, api.sopInstanceUID)
        XCTAssertEqual(listed["referenced"] as? [String], api.allUIDValues.sorted())
        let viaStdinRaw = try await run(["uid", "list", "-", "--json"], stdin: try Data(contentsOf: input))
        let viaStdin = try XCTUnwrap(try json(viaStdinRaw) as? [String: Any])
        XCTAssertEqual(viaStdin["seriesInstanceUID"] as? String, "2.25.2365203")
    }

    // MARK: dump

    func test_dump_matchesLibraryLinesAndReadsStdin() async throws {
        let data = try part10(try gray16())
        let input = try file("in.dcm", data)
        let cli = try await run(["dump", input.path, "--json", "--preview-bytes", "4"])
        let api = DicomElementDump.lines(for: try await DCMDecoder(data: data).dataSet, options: .init(maxPreviewBytes: 4))
        XCTAssertEqual(try json(cli) as? NSArray, try canonical(api) as? NSArray)
        let text = String(decoding: try await run(["dump", "-", "--no-redact"], stdin: data), as: UTF8.self)
        let unredactedDataSet = try await DCMDecoder(data: data).dataSet
        XCTAssertEqual(text, DicomElementDump.text(DicomElementDump.lines(for: unredactedDataSet, options: .init(redactIdentifiers: false))) + "\n")
        XCTAssertTrue(text.contains("Parity^CLI"))
        let redacted = String(decoding: try await run(["dump", input.path]), as: UTF8.self)
        XCTAssertFalse(redacted.contains("Parity^CLI"))
        await XCTAssertThrowsErrorAsync({ try await self.run(["dump", self.directory.appendingPathComponent("missing.dcm").path]) }) {
            guard case .fileNotReadable? = $0 as? CLIError else { return XCTFail("\($0)") }
        }
    }

    // MARK: measure

    func test_measure_statsAndDistanceAgreeWithAPI() async throws {
        let data = try part10(try gray16())
        let input = try file("in.dcm", data)
        let stats = try await run(["measure", "stats", input.path, "--region", "1,1,2,1", "--bins", "4", "--json"])
        let decoder = try await DCMDecoder(data: data)
        let frame = try await DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
        let api = try DicomPixelMeasurement.statistics(frame: frame, region: .init(x: 1, y: 1, width: 2, height: 1), bins: 4)
        XCTAssertEqual(try json(stats) as? NSDictionary, try canonical(api) as? NSDictionary)
        let distance = try await run(["measure", "distance", input.path, "--from", "0,0", "--to", "3,0", "--json"])
        let apiDistance = DicomPixelMeasurement.distance(fromX: 0, fromY: 0, toX: 3, toY: 0, pixelSpacing: (0.5, 0.5))
        XCTAssertEqual(try json(distance) as? NSDictionary, try canonical(apiDistance) as? NSDictionary)
        XCTAssertEqual(apiDistance.millimeters, 1.5)
        await XCTAssertThrowsErrorAsync({ try await self.run(["measure", "stats", input.path, "--region", "9,9,1,1"]) }) {
            guard case .invalidArgument? = $0 as? CLIError else { return XCTFail("\($0)") }
        }
    }

    // MARK: pixel

    func test_pixelFill_dryRunPlansAndApplyMatchesAPI() async throws {
        let data = try part10(try gray16(frames: 2))
        let input = try file("in.dcm", data)
        let edit = DicomPixelEdit(region: .init(x: 1, y: 0, width: 2, height: 2), sample: 7, frames: [1])
        let planned = try await run(["pixel", "fill", input.path, "--region", "1,0,2,2", "--value", "7", "--frame", "1", "--dry-run", "--json"])
        XCTAssertEqual(try json(planned) as? NSDictionary, try canonical(try DicomPixelEditor.plan(edit, part10: data)) as? NSDictionary)
        let output = directory.appendingPathComponent("out.dcm")
        let reportRaw = try await run(["pixel", "fill", input.path, "--region", "1,0,2,2", "--value", "7", "--frame", "1", "--output", output.path, "--json"])
        let report = try XCTUnwrap(try json(reportRaw) as? [String: Any])
        let api = try DicomPixelEditor.apply(edit, part10: data)
        let cliDataSet = try DicomPart10PixelDataPreserver.dataSet(from: try await DCMDecoder(contentsOf: output))
        let apiDataSet = try DicomPart10PixelDataPreserver.dataSet(from: try await DCMDecoder(data: api.fileData))
        XCTAssertEqual(cliDataSet.element(for: .pixelData)?.value, apiDataSet.element(for: .pixelData)?.value)
        XCTAssertEqual(cliDataSet.removing(.sopInstanceUID).elements.filter { $0.group != 0x0002 }, apiDataSet.removing(.sopInstanceUID).elements.filter { $0.group != 0x0002 })
        XCTAssertEqual(report["samplesChanged"] as? Int, api.report.samplesChanged)
        XCTAssertEqual(report["derivedSOPInstanceUID"] as? String, cliDataSet.string(for: .sopInstanceUID))
        XCTAssertNotEqual(report["derivedSOPInstanceUID"] as? String, "2.25.2365201")
        await XCTAssertThrowsErrorAsync({ try await self.run(["pixel", "fill", input.path, "--region", "0,0,1,1", "--value", "70000", "--output", output.path, "--force"]) }) {
            guard case .validationFailed? = $0 as? CLIError else { return XCTFail("\($0)") }
        }
        await XCTAssertThrowsErrorAsync({ try await self.run(["pixel", "fill", input.path, "--region", "0,0,1,1", "--value", "1", "--output", input.path]) }) {
            guard case .invalidPath? = $0 as? CLIError else { return XCTFail("\($0)") }
        }
        let rle = try file("rle.dcm", try DicomTranscoder().transcode(data, to: .rleLossless))
        await XCTAssertThrowsErrorAsync({ try await self.run(["pixel", "fill", rle.path, "--region", "0,0,1,1", "--value", "1", "--dry-run"]) }) {
            guard case .validationFailed(_, let errors)? = $0 as? CLIError else { return XCTFail("\($0)") }
            XCTAssertTrue(errors.first?.contains("encapsulated") == true)
        }
    }

    // MARK: report

    func test_report_rendersLikeAPIAndRefusesNonSR() async throws {
        let document = CLIParityFixtures.report()
        let dataSet = DicomStructuredReportBuilder.dataSet(from: document, studyInstanceUID: "2.25.2365301", seriesInstanceUID: "2.25.2365302", sopInstanceUID: "2.25.2365300")
        let data = try part10(dataSet)
        let input = try file("sr.dcm", data)
        let srDecoder = try await DCMDecoder(data: data)
        let parsed = try XCTUnwrap(srDecoder.structuredReport)
        let text = String(decoding: try await run(["report", input.path]), as: UTF8.self)
        XCTAssertEqual(text, DicomStructuredReportRenderer.text(parsed))
        let html = String(decoding: try await run(["report", "-", "--format", "html"], stdin: data), as: UTF8.self)
        XCTAssertEqual(html, DicomStructuredReportRenderer.html(parsed))
        let jsonOut = try json(try await run(["report", input.path, "--format", "json"])) as? NSDictionary
        XCTAssertEqual(jsonOut, try json(try DicomStructuredReportRenderer.jsonData(parsed)) as? NSDictionary)
        let target = directory.appendingPathComponent("report.html")
        _ = try await run(["report", input.path, "--format", "html", "--output", target.path])
        XCTAssertEqual(try Data(contentsOf: target), Data(DicomStructuredReportRenderer.html(parsed).utf8))
        await XCTAssertThrowsErrorAsync({ try await self.run(["report", input.path, "--format", "html", "--output", target.path]) }) {
            guard case .outputFileExists? = $0 as? CLIError else { return XCTFail("\($0)") }
        }
        let image = try file("image.dcm", try part10(try gray16()))
        await XCTAssertThrowsErrorAsync({ try await self.run(["report", image.path]) }) {
            guard case .invalidDICOMFile? = $0 as? CLIError else { return XCTFail("\($0)") }
        }
    }

    // MARK: image

    func test_image_toDicomAndContactSheetMatchAPI() async throws {
        let dicom = try file("in.dcm", try part10(try gray16(frames: 2)))
        let png = directory.appendingPathComponent("frame.png")
        _ = try DicomImageExporter().export(decoder: try await DCMDecoder(contentsOf: dicom), frame: 0, to: png, options: .init(format: .png))
        let sc = directory.appendingPathComponent("sc.dcm")
        _ = try await run(["image", "to-dicom", png.path, "--output", sc.path, "--patient-name", "Sheet^Case", "--patient-id", "S1"])
        let decoded = try await DCMDecoder(contentsOf: sc)
        XCTAssertEqual(decoded.dataSet.string(for: .sopClassUID), DicomSecondaryCaptureImage.storageSOPClassUID)
        XCTAssertEqual(decoded.dataSet.string(for: .patientName), "Sheet^Case")
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return XCTFail("png") }
        let apiPixels = try DicomSecondaryCaptureBuilder.rgb8PixelData(from: image)
        XCTAssertEqual(try DicomPart10PixelDataPreserver.dataSet(from: decoded).element(for: .pixelData)?.value, .bytes(apiPixels.data))
        let junk = try file("junk.dcm", Data("junk".utf8))
        await XCTAssertThrowsErrorAsync({ try await self.run(["image", "to-dicom", junk.path, "--output", self.directory.appendingPathComponent("x.dcm").path]) }) {
            guard case .fileNotReadable? = $0 as? CLIError else { return XCTFail("\($0)") }
        }
        let sheet = directory.appendingPathComponent("sheet.png")
        _ = try await run(["image", "contact-sheet", dicom.path, junk.path, sc.path, "--output", sheet.path, "--columns", "2", "--cell", "16"])
        let api = try DicomContactSheet.render(inputs: [dicom, junk, sc], columns: 2, cellSize: 16, maxFramesPerInput: 16)
        XCTAssertEqual(api.tiles, 3); XCTAssertEqual(api.rows, 2); XCTAssertEqual(api.skipped.count, 1)
        XCTAssertEqual(try Data(contentsOf: sheet), api.png)
        await XCTAssertThrowsErrorAsync({ try await self.run(["image", "contact-sheet", junk.path, "--output", self.directory.appendingPathComponent("none.png").path]) }) {
            XCTAssertEqual($0 as? DicomContactSheet.Failure, .noTiles)
        }
    }

    // MARK: study

    func test_studyOrganize_plansByDefaultAndAppliesLikeAPI() async throws {
        let inputs = directory.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let a = try file("inputs/a.dcm", try part10(try gray16()))
        let b = try file("inputs/b.dcm", try part10(try gray16(sopInstanceUID: "2.25.2365299")))
        let junk = try file("inputs/junk.txt", Data("x".utf8))
        let root = directory.appendingPathComponent("organized")
        let plannedRaw = try await run(["study", "organize", inputs.path, "--into", root.path, "--json"])
        let planned = try XCTUnwrap(try json(plannedRaw) as? [String: Any])
        let api = await DicomStudyOrganizer.plan(files: [a, b, junk], into: root)
        // The directory enumerator reports resolved (/private/var) paths; compare the plans on normalised sources.
        func normalised(_ plan: Any?) -> NSDictionary? {
            guard var dictionary = plan as? [String: Any], let entries = dictionary["entries"] as? [[String: Any]] else { return nil }
            dictionary["entries"] = entries.map { entry -> [String: Any] in
                var entry = entry
                if let source = entry["source"] as? String, source.hasPrefix("/private/var/") { entry["source"] = String(source.dropFirst("/private".count)) }
                return entry
            }
            return dictionary as NSDictionary
        }
        XCTAssertEqual(normalised(planned["plan"]), normalised(try canonical(api)))
        XCTAssertNil(planned["result"] as? [String: Any])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let appliedRaw = try await run(["study", "organize", a.path, b.path, "--into", root.path, "--apply", "--json"])
        let applied = try XCTUnwrap(try json(appliedRaw) as? [String: Any])
        XCTAssertEqual(((applied["result"] as? [String: Any])?["applied"] as? [Any])?.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("P2365C/2.25.2365202/2.25.2365203/2.25.2365201.dcm").path))
        await XCTAssertThrowsErrorAsync({ try await self.run(["study", "organize", a.path, "--into", root.path, "--apply"]) }) { XCTAssertEqual(($0 as? ExitCode)?.rawValue, 1) }
    }

    // MARK: script

    func test_script_checkRunDryRunAndPartialFailureMatchAPI() async throws {
        let pipeline = try file("pipeline.json", Data("""
        {"name": "cli", "secrets": {"token": "env:PARITY_CLI_TOKEN"}, "steps": [
          {"op": "validate", "failOnError": false},
          {"op": "set", "values": ["(0008,1030)=Parity study"]},
          {"op": "remove", "values": ["(0028,0030)"]},
          {"op": "pixel-fill", "region": {"x": 0, "y": 0, "width": 2, "height": 1}, "sample": 3},
          {"op": "write", "suffix": "-cli"}
        ]}
        """.utf8))
        let normalisedRaw = try await run(["script", "check", pipeline.path])
        let normalised = try XCTUnwrap(try json(normalisedRaw) as? [String: Any])
        XCTAssertEqual((normalised["steps"] as? [[String: Any]])?.map { $0["op"] as? String }, ["validate", "set", "remove", "pixel-fill", "write"])
        let good = try file("good.dcm", try part10(try gray16()))
        let bad = try file("bad.dcm", Data("junk".utf8))
        let definition = try JSONDecoder().decode(DicomDatasetPipeline.self, from: try Data(contentsOf: pipeline))
        let dryOut = directory.appendingPathComponent("dry")
        let dryRaw = try await run(["script", "run", pipeline.path, good.path, "--output-dir", dryOut.path, "--dry-run", "--json"])
        let dry = try XCTUnwrap(try json(dryRaw) as? [String: Any])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dryOut.path))
        _ = dry
        let cliOut = directory.appendingPathComponent("cli-out"), apiOut = directory.appendingPathComponent("api-out")
        var exit: Int32?
        let cli = try await capture {
            var command = try DicomTool.parseAsRoot(["script", "run", pipeline.path, good.path, bad.path, "--output-dir", cliOut.path, "--json"])
            do { if var asyncCommand = command as? AsyncParsableCommand { try await asyncCommand.run() } else { try command.run() } } catch let code as ExitCode { exit = code.rawValue }
        }
        XCTAssertEqual(exit, 1, "partial failure exits 1 after processing every file")
        let cliReport = try JSONDecoder().decode(DicomPipelineReport.self, from: cli)
        let apiReport = try await DicomPipelineRunner.run(definition, inputs: [good, bad], options: .init(outputDirectory: apiOut), editParser: ScriptCommand.editParser)
        XCTAssertEqual(cliReport.files.map(\.status), ["ok", "failed"]); XCTAssertEqual(apiReport.files.map(\.status), ["ok", "failed"])
        XCTAssertEqual(cliReport.files[0].steps.map(\.op), apiReport.files[0].steps.map(\.op))
        XCTAssertEqual(cliReport.files[0].steps.map(\.status), ["ok", "ok", "ok", "ok", "ok"])
        XCTAssertEqual(cliReport.files[1].steps.last?.status, "failed"); XCTAssertEqual(cliReport.files[1].steps.last?.op, "set")
        let cliFile = try DicomPart10PixelDataPreserver.dataSet(from: try await DCMDecoder(contentsOf: cliOut.appendingPathComponent("good-cli.dcm")))
        let apiFile = try DicomPart10PixelDataPreserver.dataSet(from: try await DCMDecoder(contentsOf: apiOut.appendingPathComponent("good-cli.dcm")))
        XCTAssertEqual(cliFile.string(for: 0x0008_1030), "Parity study"); XCTAssertNil(cliFile.element(for: 0x0028_0030))
        XCTAssertEqual(cliFile.element(for: .pixelData)?.value, apiFile.element(for: .pixelData)?.value)
        XCTAssertEqual(cliFile.removing(.sopInstanceUID).elements.filter { $0.group != 0x0002 }, apiFile.removing(.sopInstanceUID).elements.filter { $0.group != 0x0002 })
        await XCTAssertThrowsErrorAsync({ try await self.run(["script", "run", pipeline.path, good.path]) }) {
            guard case .invalidArgument(_, _, let reason)? = $0 as? CLIError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("output directory"), reason)
        }
        let secret = try file("secret.json", Data(#"{"name":"s","secrets":{"token":"env:PARITY_CLI_TOKEN_MISSING"},"steps":[{"op":"require-secret","name":"token"}]}"#.utf8))
        await XCTAssertThrowsErrorAsync({ try await self.run(["script", "run", secret.path, good.path, "--dry-run"]) }) {
            guard case .invalidArgument(_, _, let reason)? = $0 as? CLIError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("not available"), reason)
        }
    }

    // MARK: bench

    func test_bench_writesDigestsAndFailsWithoutCorpus() async throws {
        let corpus = directory.appendingPathComponent("corpus")
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let data = try part10(try gray16())
        try data.write(to: corpus.appendingPathComponent("a.dcm"))
        let output = directory.appendingPathComponent("bench.json")
        _ = try await run(["bench", corpus.path, "--iterations", "1", "--output", output.path])
        let cli = try JSONDecoder().decode(DicomDecodeBenchmarkResult.self, from: try Data(contentsOf: output))
        let api = try DicomDecodeBenchmark.run(corpus: corpus, options: .init(iterations: 1, toolkitVersion: ParityIO.toolkitVersion))
        XCTAssertEqual(cli.files.map(\.sha256), api.files.map(\.sha256)); XCTAssertEqual(cli.toolkitVersion, api.toolkitVersion)
        XCTAssertEqual(cli.disclaimer, DicomDecodeBenchmarkResult.disclaimer)
        XCTAssertEqual(cli.files.first?.frames, 1)
        let stdout = try JSONDecoder().decode(DicomDecodeBenchmarkResult.self, from: try await run(["bench", corpus.appendingPathComponent("a.dcm").path, "--iterations", "1"]))
        XCTAssertEqual(stdout.files.count, 1)
        await XCTAssertThrowsErrorAsync({ try await self.run(["bench", self.directory.appendingPathComponent("nowhere").path]) }) {
            guard case .fileNotReadable? = $0 as? CLIError else { return XCTFail("\($0)") }
        }
    }
}

enum CLIParityFixtures {
    static func report() -> DicomSRDocument {
        let concept = DicomCodedConcept(codeValue: "121071", codingSchemeDesignator: "DCM", codeMeaning: "Finding")
        let root = DicomSRContentItem(valueType: "CONTAINER", conceptName: .init(codeValue: "18748-4", codingSchemeDesignator: "LN", codeMeaning: "Diagnostic Imaging Report"),
            continuityOfContent: "SEPARATE", children: [
                .init(relationshipType: "CONTAINS", valueType: "TEXT", conceptName: concept, textValue: "Nodule <2 cm & stable"),
                .init(relationshipType: "CONTAINS", valueType: "NUM", conceptName: .init(codeValue: "G-D7FE", codingSchemeDesignator: "SRT", codeMeaning: "Length"), numericValue: 12.5,
                      measurementUnits: .init(codeValue: "mm", codingSchemeDesignator: "UCUM")),
            ])
        return DicomSRDocument(sopClassUID: DicomSRDocument.enhancedSRStorageSOPClassUID, sopInstanceUID: "2.25.2365300", completionFlag: "COMPLETE", verificationFlag: "UNVERIFIED", root: root)
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T, _ handler: (Error) -> Void = { _ in }, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) } catch { handler(error) }
}
