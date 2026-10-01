import Foundation
import XCTest
@testable import DicomCore

/// Library-level behaviour of the #2365 parity APIs; the CLI tests compare each command against these entry points.
final class CLIParityLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("parity-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    static func gray16(columns: Int = 4, rows: Int = 3, frames: Int = 1, signed: Bool = false, values: ((Int, Int, Int) -> Int)? = nil,
                       sopInstanceUID: String = "2.25.2365001") throws -> DicomDataSet {
        var bytes = Data()
        for frame in 0..<frames {
            for row in 0..<rows {
                for column in 0..<columns {
                    let value = values?(frame, column, row) ?? (frame * 100 + row * columns + column)
                    let raw = UInt16(truncatingIfNeeded: value)
                    bytes.append(UInt8(raw & 0xFF)); bytes.append(UInt8(raw >> 8))
                }
            }
        }
        let firstFrame = bytes.prefix(columns * rows * 2)
        let pixelData = try DicomSecondaryCapturePixelData(data: Data(firstFrame), columns: columns, rows: rows, samplesPerPixel: 1,
                                                          photometricInterpretation: "MONOCHROME2", bitsAllocated: 16, bitsStored: 12, highBit: 11)
        var dataSet = DicomSecondaryCaptureBuilder.dataSet(pixelData: pixelData, options: .init(sopInstanceUID: sopInstanceUID, studyInstanceUID: "2.25.2365002",
                                                                                                  seriesInstanceUID: "2.25.2365003", patientName: "Parity^Case", patientID: "P2365",
                                                                                                  seriesNumber: 1, instanceNumber: 1))
        if frames > 1 {
            dataSet.set(.init(tag: 0x0028_0008, vr: .IS, value: .strings([String(frames)])))
            dataSet.set(.init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(bytes)))
        }
        if signed { dataSet.set(.init(tag: 0x0028_0103, vr: .US, value: .unsignedIntegers([1]))) }
        dataSet.set(.init(tag: 0x0028_1052, vr: .DS, value: .strings(["-1024"])))
        dataSet.set(.init(tag: 0x0028_1053, vr: .DS, value: .strings(["2"])))
        dataSet.set(.init(tag: 0x0028_0030, vr: .DS, value: .strings(["0.5", "0.25"])))
        return dataSet
    }

    static func part10(_ dataSet: DicomDataSet) throws -> Data {
        try DicomDataSetWriter.part10Data(from: dataSet, options: .init(mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID), mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)))
    }

    // MARK: dump

    func test_dump_redactsIdentifiersPreviewsHexAndRecursesSequences() throws {
        var dataSet = try Self.gray16()
        dataSet.set(.init(tag: 0x0008_1140, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [.init(tag: 0x0008_1155, vr: .UI, value: .strings(["2.25.9"]))]))])))
        let lines = DicomElementDump.lines(for: dataSet, options: .init(maxPreviewBytes: 4))
        let name = try XCTUnwrap(lines.first { $0.tag == "(0010,0010)" })
        XCTAssertEqual(name.preview, "(redacted)")
        XCTAssertEqual(DicomElementDump.lines(for: dataSet, options: .init(redactIdentifiers: false)).first { $0.tag == "(0010,0010)" }?.preview, "Parity^Case")
        let pixels = try XCTUnwrap(lines.first { $0.tag == "(7FE0,0010)" })
        XCTAssertEqual(pixels.hex, "00 00 01 00 ...")
        XCTAssertEqual(pixels.length, 24)
        XCTAssertEqual(lines.filter { $0.depth == 2 }.map(\.tag), ["(0008,1155)"])
        XCTAssertTrue(DicomElementDump.text(lines).contains("(0028,0010) US vm=1 3"), DicomElementDump.text(lines))
        XCTAssertTrue(DicomElementDump.lines(for: dataSet, options: .init(maxDepth: 1)).allSatisfy { $0.depth <= 1 })
    }

    // MARK: measure

    func test_statistics_regionAndRescaleAndDistance() throws {
        let data = try Self.part10(try Self.gray16())
        let frame = try DicomDecodedFrameReader(decoder: try DCMDecoder(data: data)).frame(at: 0)
        let whole = try DicomPixelMeasurement.statistics(frame: frame, bins: 4)
        XCTAssertEqual(whole.sampleCount, 12)
        XCTAssertEqual(whole.minimum, 0); XCTAssertEqual(whole.maximum, 11); XCTAssertEqual(whole.mean, 5.5, accuracy: 1e-9)
        XCTAssertEqual(whole.histogram.reduce(0, +), 12)
        XCTAssertEqual(whole.rescaledMinimum, -1024); XCTAssertEqual(whole.rescaledMaximum, -1002)
        let region = try DicomPixelMeasurement.statistics(frame: frame, region: .init(x: 1, y: 1, width: 2, height: 1))
        XCTAssertEqual(region.minimum, 5); XCTAssertEqual(region.maximum, 6); XCTAssertEqual(region.sampleCount, 2)
        XCTAssertThrowsError(try DicomPixelMeasurement.statistics(frame: frame, region: .init(x: 3, y: 0, width: 2, height: 1))) {
            XCTAssertEqual($0 as? DicomPixelMeasurementError, .regionOutOfBounds)
        }
        let dataSet = try DCMDecoder(data: data).dataSet
        let distance = DicomPixelMeasurement.distance(fromX: 0, fromY: 0, toX: 4, toY: 0, pixelSpacing: DicomPixelMeasurement.pixelSpacing(from: dataSet))
        XCTAssertEqual(distance.pixels, 4); XCTAssertEqual(distance.millimeters, 1.0)
        XCTAssertNil(DicomPixelMeasurement.distance(fromX: 0, fromY: 0, toX: 3, toY: 4, pixelSpacing: nil).millimeters)
    }

    func test_statistics_signedAndMonochrome1_useStoredSamples() throws {
        for (allocated, stored, unusedBits) in [
            (8, 4, 0xF0), (8, 8, 0), (16, 12, 0), (16, 12, 0xF000), (16, 16, 0)
        ] {
            for signed in [false, true] {
                let upper = (1 << (signed ? stored - 1 : stored)) - 1
                let samples = signed ? [-(1 << (stored - 1)), -1, 0, upper] : [0, 1, upper - 1, upper]
                for photometric in ["MONOCHROME1", "MONOCHROME2"] {
                    var dataSet = try Self.gray16(columns: 4, rows: 1, signed: signed)
                    dataSet.set(.init(tag: 0x0028_0100, vr: .US, value: .unsignedIntegers([UInt(allocated)])))
                    dataSet.set(.init(tag: 0x0028_0101, vr: .US, value: .unsignedIntegers([UInt(stored)])))
                    dataSet.set(.init(tag: 0x0028_0102, vr: .US, value: .unsignedIntegers([UInt(stored - 1)])))
                    dataSet.set(.init(tag: 0x0028_0004, vr: .CS, value: .strings([photometric])))
                    var bytes = Data()
                    for sample in samples {
                        let raw = UInt16(truncatingIfNeeded: sample) | UInt16(unusedBits)
                        bytes.append(UInt8(truncatingIfNeeded: raw))
                        if allocated == 16 { bytes.append(UInt8(raw >> 8)) }
                    }
                    dataSet.set(.init(tag: DicomTag.pixelData.rawValue, vr: allocated == 8 ? .OB : .OW, value: .bytes(bytes)))
                    let frame = try DicomDecodedFrameReader(decoder: DCMDecoder(data: Self.part10(dataSet))).frame(at: 0)
                    let stats = try DicomPixelMeasurement.statistics(frame: frame, bins: 4)
                    XCTAssertEqual(stats.minimum, Double(samples[0]))
                    XCTAssertEqual(stats.maximum, Double(upper))
                    XCTAssertEqual(stats.mean, Double(samples.reduce(0, +)) / 4, accuracy: 1e-9)
                    XCTAssertEqual(stats.histogram, signed ? [1, 1, 1, 1] : [2, 0, 0, 2])
                    let first = try DicomPixelMeasurement.statistics(frame: frame, region: .init(x: 0, y: 0, width: 1, height: 1))
                    XCTAssertEqual(first.mean, Double(samples[0]), "\(allocated)/\(stored) signed=\(signed) \(photometric)")
                    XCTAssertEqual(first.rescaledMean, Double(samples[0]) * 2 - 1024)
                }
            }
        }
    }

    func test_statistics_negativeRescaleSlope_ordersBounds() throws {
        var dataSet = try Self.gray16()
        dataSet.set(.init(tag: 0x0028_1052, vr: .DS, value: .strings(["10"])))
        dataSet.set(.init(tag: 0x0028_1053, vr: .DS, value: .strings(["-2"])))
        let frame = try DicomDecodedFrameReader(decoder: DCMDecoder(data: Self.part10(dataSet))).frame(at: 0)
        let stats = try DicomPixelMeasurement.statistics(frame: frame)
        XCTAssertEqual(stats.rescaledMinimum, -12)
        XCTAssertEqual(stats.rescaledMaximum, 10)
        XCTAssertEqual(stats.rescaledMean, -1)
    }

    // MARK: pixel edit

    func test_pixelEditor_writesDerivedObjectAndRefusesBadInput() throws {
        let data = try Self.part10(try Self.gray16(frames: 2))
        let edit = DicomPixelEdit(region: .init(x: 1, y: 0, width: 2, height: 2), sample: 7, frames: [1])
        let plan = try DicomPixelEditor.plan(edit, part10: data)
        XCTAssertEqual(plan.samplesWritten, 4); XCTAssertEqual(plan.samplesChanged, 4); XCTAssertEqual(plan.derivedSOPInstanceUID, "2.25.2365001")
        let output = try DicomPixelEditor.apply(edit, part10: data, makeUID: { "2.25.777" })
        XCTAssertEqual(output.report.derivedSOPInstanceUID, "2.25.777")
        let reader = DicomDecodedFrameReader(decoder: try DCMDecoder(data: output.fileData))
        guard case .gray16(let frame0) = try reader.frame(at: 0).pixels, case .gray16(let frame1) = try reader.frame(at: 1).pixels else { return XCTFail("expected 16-bit frames") }
        XCTAssertEqual(Array(frame0.prefix(4)), [0, 1, 2, 3], "frame 0 untouched")
        XCTAssertEqual(Array(frame1), [100, 7, 7, 103, 104, 7, 7, 107, 108, 109, 110, 111])
        let derived = try DCMDecoder(data: output.fileData).dataSet
        XCTAssertEqual(derived.strings(for: .imageType).first, "DERIVED")
        XCTAssertEqual(derived.string(for: .sopInstanceUID), "2.25.777")
        XCTAssertEqual(derived.string(for: 0x0028_0301), try DCMDecoder(data: data).dataSet.string(for: 0x0028_0301))
        guard case .sequence(let items)? = derived.element(for: 0x0008_2112)?.value else { return XCTFail("missing Source Image Sequence") }
        XCTAssertEqual(items.first?.dataSet.string(for: 0x0008_1155), "2.25.2365001")
        XCTAssertTrue(derived.string(for: 0x0008_2111)?.contains("redaction") == true)
        XCTAssertThrowsError(try DicomPixelEditor.plan(.init(region: .init(x: 3, y: 0, width: 2, height: 1), sample: 1), part10: data)) {
            XCTAssertEqual($0 as? DicomPixelEditError, .regionOutOfBounds(columns: 4, rows: 3))
        }
        XCTAssertThrowsError(try DicomPixelEditor.plan(.init(region: .init(x: 0, y: 0, width: 1, height: 1), sample: 5000), part10: data)) {
            XCTAssertEqual($0 as? DicomPixelEditError, .sampleOutOfRange(5000, bitsStored: 12, signed: false))
        }
        XCTAssertThrowsError(try DicomPixelEditor.plan(.init(region: .init(x: 0, y: 0, width: 1, height: 1), sample: 1, frames: [2]), part10: data)) {
            XCTAssertEqual($0 as? DicomPixelEditError, .frameOutOfRange(2, frameCount: 2))
        }
        let signed = try Self.part10(try Self.gray16(signed: true))
        XCTAssertNoThrow(try DicomPixelEditor.plan(.init(region: .init(x: 0, y: 0, width: 1, height: 1), sample: -2048), part10: signed))
        XCTAssertThrowsError(try DicomPixelEditor.plan(.init(region: .init(x: 0, y: 0, width: 1, height: 1), sample: 2048), part10: signed))
    }

    func test_pixelEditor_refusesEncapsulatedPixelData() throws {
        let rle = try DicomTranscoder().transcode(try Self.part10(try Self.gray16()), to: .rleLossless)
        XCTAssertThrowsError(try DicomPixelEditor.plan(.init(region: .init(x: 0, y: 0, width: 1, height: 1), sample: 1), part10: rle)) { error in
            guard case .compressedPixelData(let uid)? = error as? DicomPixelEditError else { return XCTFail("\(error)") }
            XCTAssertEqual(uid, DicomTransferSyntax.rleLossless.rawValue)
        }
    }

    // MARK: SR renderer

    static func report() -> DicomSRDocument {
        let concept = DicomCodedConcept(codeValue: "121071", codingSchemeDesignator: "DCM", codeMeaning: "Finding")
        let units = DicomCodedConcept(codeValue: "mm", codingSchemeDesignator: "UCUM")
        let root = DicomSRContentItem(valueType: "CONTAINER", conceptName: .init(codeValue: "18748-4", codingSchemeDesignator: "LN", codeMeaning: "Diagnostic Imaging Report"),
            continuityOfContent: "SEPARATE", children: [
                .init(relationshipType: "CONTAINS", valueType: "TEXT", conceptName: concept, textValue: "Nodule <2 cm & stable"),
                .init(relationshipType: "CONTAINS", valueType: "NUM", conceptName: .init(codeValue: "G-D7FE", codingSchemeDesignator: "SRT", codeMeaning: "Length"), numericValue: 12.5, measurementUnits: units),
                .init(relationshipType: "CONTAINS", valueType: "CODE", conceptName: concept, codeValue: .init(codeValue: "R-42", codingSchemeDesignator: "SRT", codeMeaning: "Stable")),
            ])
        return DicomSRDocument(sopClassUID: DicomSRDocument.enhancedSRStorageSOPClassUID, sopInstanceUID: "2.25.2365100", completionFlag: "COMPLETE", verificationFlag: "UNVERIFIED", root: root)
    }

    static func reportPart10() throws -> Data {
        let dataSet = DicomStructuredReportBuilder.dataSet(from: report(), studyInstanceUID: "2.25.2365101", seriesInstanceUID: "2.25.2365102", sopInstanceUID: "2.25.2365100")
        return try part10(dataSet)
    }

    func test_structuredReportRenderer_textHTMLAndJSONEscapeAndNest() throws {
        let document = try XCTUnwrap(try DCMDecoder(data: try Self.reportPart10()).structuredReport)
        let text = DicomStructuredReportRenderer.text(document)
        XCTAssertEqual(text, """
        CONTAINER Diagnostic Imaging Report
          CONTAINS TEXT Finding: Nodule <2 cm & stable
          CONTAINS NUM Length: 12.5 mm
          CONTAINS CODE Finding: Stable (R-42)

        """)
        let html = DicomStructuredReportRenderer.html(document)
        XCTAssertTrue(html.contains("Nodule &lt;2 cm &amp; stable"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertTrue(html.hasPrefix("<section class=\"dicom-sr\"><ul><li>"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try DicomStructuredReportRenderer.jsonData(document)) as? [String: Any])
        XCTAssertEqual(json["contentItemCount"] as? Int, 4)
        XCTAssertEqual(json["completionFlag"] as? String, "COMPLETE")
        XCTAssertEqual(((json["root"] as? [String: Any])?["children"] as? [[String: Any]])?.count, 3)
    }

    func test_structuredReportRenderer_largeAndFractionalNumbers_doNotTrap() {
        for (value, expected) in [(1e20, "1e+20"), (-1e20, "-1e+20"), (42.0, "42"), (12.5, "12.5")] {
            let document = DicomSRDocument(
                sopClassUID: DicomSRDocument.enhancedSRStorageSOPClassUID,
                sopInstanceUID: "2.25.2365100",
                root: .init(valueType: "NUM", numericValue: value)
            )
            XCTAssertTrue(DicomStructuredReportRenderer.text(document).contains(expected))
            XCTAssertTrue(DicomStructuredReportRenderer.html(document).contains(expected))
        }
    }

    // MARK: study organizer

    func test_contactSheet_nonPositiveColumns_throwBeforeRendering() {
        for columns in [0, -1] {
            XCTAssertThrowsError(try DicomContactSheet.render(inputs: [], columns: columns, cellSize: 16, maxFramesPerInput: 1)) {
                XCTAssertEqual($0 as? DicomContactSheet.Failure, .renderFailed)
            }
        }
        XCTAssertThrowsError(try DicomContactSheet.render(inputs: [], columns: 1, cellSize: 16, maxFramesPerInput: 1)) {
            XCTAssertEqual($0 as? DicomContactSheet.Failure, .noTiles)
        }
    }

    func test_studyOrganizer_plansSkipsDuplicatesAndNeverOverwrites() async throws {
        let a = directory.appendingPathComponent("a.dcm"), b = directory.appendingPathComponent("b.dcm"), junk = directory.appendingPathComponent("junk.txt")
        try Self.part10(try Self.gray16()).write(to: a)
        try Self.part10(try Self.gray16()).write(to: b)
        try Data("nope".utf8).write(to: junk)
        let root = directory.appendingPathComponent("organized")
        let plan = await DicomStudyOrganizer.plan(files: [a, b, junk], into: root)
        XCTAssertEqual(plan.planned.count, 1); XCTAssertEqual(plan.skipped.count, 2); XCTAssertEqual(plan.studyCount, 1)
        XCTAssertEqual(plan.planned.first?.destination, root.appendingPathComponent("P2365/2.25.2365002/2.25.2365003/2.25.2365001.dcm").path)
        XCTAssertTrue(plan.skipped.contains { $0.source == b.path && $0.skipReason?.contains("duplicate") == true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "planning writes nothing")
        let applied = DicomStudyOrganizer.apply(plan, mode: .copy)
        XCTAssertEqual(applied.applied.count, 1); XCTAssertTrue(applied.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "copy keeps the source")
        let again = DicomStudyOrganizer.apply(plan, mode: .copy)
        XCTAssertEqual(again.failures.count, 1, "existing destination is refused")
        let cancelled = DicomStudyOrganizer.apply(plan, mode: .copy, isCancelled: { true })
        XCTAssertTrue(cancelled.cancelled); XCTAssertTrue(cancelled.applied.isEmpty)
    }

    // MARK: pipeline

    static let pipelineJSON = """
    {"name": "demo", "secrets": {"token": "env:PARITY_TOKEN"}, "steps": [
      {"op": "dump", "maxPreviewBytes": 8},
      {"op": "validate", "failOnError": false},
      {"op": "require-secret", "name": "token"},
      {"op": "pixel-fill", "region": {"x": 0, "y": 0, "width": 1, "height": 1}, "sample": 9, "intent": "annotation"},
      {"op": "regenerate-uid", "scope": "series"},
      {"op": "write", "suffix": "-edited"},
      {"op": "export-image", "format": "png"}
    ]}
    """

    private let parser: DicomPipelineRunner.EditParser = { set, remove, _ in
        DicomDataSetEdit(operations: set.map { .set(DicomTagPath(0x0008_1030), .init(tag: 0x0008_1030, vr: .LO, value: .strings([$0]))) } + remove.map { _ in .remove(DicomTagPath(0x0008_1030)) })
    }

    func test_pipeline_decodesRunsDryRunsAndReportsPartialFailure() async throws {
        let pipeline = try JSONDecoder().decode(DicomDatasetPipeline.self, from: Data(Self.pipelineJSON.utf8))
        XCTAssertEqual(pipeline.steps.count, 7)
        XCTAssertEqual(try JSONDecoder().decode(DicomDatasetPipeline.self, from: try JSONEncoder().encode(pipeline)), pipeline)
        XCTAssertThrowsError(try JSONDecoder().decode(DicomDatasetPipeline.self, from: Data(#"{"name":"x","steps":[{"op":"eval","code":"rm -rf"}]}"#.utf8)))
        let good = directory.appendingPathComponent("good.dcm"), bad = directory.appendingPathComponent("bad.dcm")
        try Self.part10(try Self.gray16()).write(to: good)
        try Data("not dicom".utf8).write(to: bad)
        let output = directory.appendingPathComponent("out")
        let provider = DicomEnvironmentSecretProvider(environment: ["PARITY_TOKEN": "s3cret"])
        let dry = try await DicomPipelineRunner.run(pipeline, inputs: [good, bad], options: .init(outputDirectory: output, dryRun: true, secretProvider: provider), editParser: parser)
        XCTAssertTrue(dry.dryRun); XCTAssertEqual(dry.files.map(\.status), ["ok", "failed"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(dry.files[0].steps.map(\.status), ["ok", "ok", "ok", "planned", "ok", "planned", "planned"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(dry), as: UTF8.self).contains("s3cret"))
        let wet = try await DicomPipelineRunner.run(pipeline, inputs: [good, bad], options: .init(outputDirectory: output, secretProvider: provider), editParser: parser)
        XCTAssertEqual(wet.files.map(\.status), ["ok", "failed"]); XCTAssertEqual(wet.failed.count, 1)
        XCTAssertEqual(wet.files[1].steps.first?.op, "dump"); XCTAssertEqual(wet.files[1].steps.first?.status, "failed")
        let written = output.appendingPathComponent("good-edited.dcm")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("good.png").path))
        let edited = try await DCMDecoder(contentsOf: written).dataSet
        XCTAssertNotEqual(edited.string(for: .seriesInstanceUID), "2.25.2365003")
        XCTAssertEqual(edited.strings(for: .imageType).first, "DERIVED")
        XCTAssertEqual(wet.files[0].steps[3].pixelEdit?.samplesChanged, 1)
        await XCTAssertThrowsErrorAsync({ try await DicomPipelineRunner.run(pipeline, inputs: [good], options: .init(outputDirectory: output, dryRun: true, secretProvider: DicomEnvironmentSecretProvider(environment: [:])), editParser: parser) }) {
            XCTAssertEqual($0 as? DicomEnvironmentSecretProvider.Failure, .missing("token"))
        }
        await XCTAssertThrowsErrorAsync({ try await DicomPipelineRunner.run(pipeline, inputs: [good], options: .init(outputDirectory: nil, secretProvider: provider), editParser: parser) }) {
            XCTAssertEqual($0 as? DicomPipelineError, .outputDirectoryRequired)
        }
    }

    func test_pipeline_programmaticTraversalSuffix_cannotWriteOutsideOutputDirectory() async throws {
        let input = directory.appendingPathComponent("source.dcm")
        let original = try Self.part10(try Self.gray16())
        try original.write(to: input)
        let output = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output.appendingPathComponent("source"), withIntermediateDirectories: true)
        let pipeline = DicomDatasetPipeline(name: "traversal", steps: [
            .write(suffix: "-safe"), .write(suffix: "/../../escape")
        ])

        await XCTAssertThrowsErrorAsync({
            try await DicomPipelineRunner.run(pipeline, inputs: [input], options: .init(outputDirectory: output), editParser: parser)
        }) {
            XCTAssertEqual($0 as? DicomPipelineError, .invalidEdit("write: suffix must be a short file name fragment"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.dcm").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("source-safe.dcm").path))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func test_pipeline_mutatedWriteSuffix_isRejectedBeforeDryRunOrWrites() async throws {
        let input = directory.appendingPathComponent("source.dcm")
        try Self.part10(try Self.gray16()).write(to: input)
        let validJSON = Data(#"{"name":"mutated","steps":[{"op":"write","suffix":"-safe"}]}"#.utf8)
        let invalidSuffixes = ["/../../escape", "/nested", "..", "-bad..name", String(repeating: "x", count: 33)]
        for (index, suffix) in invalidSuffixes.enumerated() {
            var pipeline = try JSONDecoder().decode(DicomDatasetPipeline.self, from: validJSON)
            pipeline.steps.append(.write(suffix: suffix))
            XCTAssertThrowsError(try JSONDecoder().decode(DicomDatasetPipeline.self, from: JSONEncoder().encode(pipeline)))
            for dryRun in [true, false] {
                let output = directory.appendingPathComponent("out-\(index)-\(dryRun)")
                await XCTAssertThrowsErrorAsync({
                    try await DicomPipelineRunner.run(pipeline, inputs: [input], options: .init(outputDirectory: output, dryRun: dryRun), editParser: parser)
                }) {
                    XCTAssertEqual($0 as? DicomPipelineError, .invalidEdit("write: suffix must be a short file name fragment"))
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    func test_pipeline_validWriteSuffixes_preserveOutputPathsAndBytes() async throws {
        let input = directory.appendingPathComponent("source.dcm")
        let original = try Self.part10(try Self.gray16())
        try original.write(to: input)
        for (index, suffix) in ["", "-derived", String(repeating: "x", count: 32)].enumerated() {
            let pipeline = DicomDatasetPipeline(name: "valid", steps: [.write(suffix: suffix)])
            XCTAssertEqual(try JSONDecoder().decode(DicomDatasetPipeline.self, from: JSONEncoder().encode(pipeline)), pipeline)
            let output = directory.appendingPathComponent("out-\(index)")
            let target = output.appendingPathComponent("source" + suffix + ".dcm")
            let dry = try await DicomPipelineRunner.run(pipeline, inputs: [input], options: .init(outputDirectory: output, dryRun: true), editParser: parser)
            XCTAssertEqual(dry.files.first?.steps.first?.status, "planned")
            XCTAssertEqual(dry.files.first?.steps.first?.output, target.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            let wet = try await DicomPipelineRunner.run(pipeline, inputs: [input], options: .init(outputDirectory: output), editParser: parser)
            XCTAssertEqual(wet.files.first?.status, "ok")
            XCTAssertEqual(wet.files.first?.steps.first?.output, target.path)
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func test_pipeline_dryRun_preservesSequentialMetadataEdits() async throws {
        let input = directory.appendingPathComponent("sequential.dcm")
        var dataSet = try Self.gray16()
        dataSet.set(.init(tag: 0x0028_0301, vr: .CS, value: .strings(["NO"])))
        let original = try Self.part10(dataSet)
        try original.write(to: input)
        let output = directory.appendingPathComponent("dry-output")
        let pipeline = DicomDatasetPipeline(name: "sequential", steps: [
            .set(["first"]), .remove(["first"]), .set(["second"]), .regenerateUID(.series),
            .set(["check-regenerated"]), .deidentify(options: []), .set(["check-deidentified"]), .write(suffix: "-derived")
        ])
        let report = try await DicomPipelineRunner.run(pipeline, inputs: [input], options: .init(outputDirectory: output, dryRun: true)) { set, remove, source in
            if !remove.isEmpty {
                guard source.string(for: .studyDescription) == "first" else { throw DicomPipelineError.invalidEdit("set was discarded") }
                return .init(operations: [.remove(DicomTagPath(DicomTag.studyDescription.rawValue))])
            }
            if set == ["second"], source.element(for: .studyDescription) != nil {
                throw DicomPipelineError.invalidEdit("remove was discarded")
            }
            if set == ["check-regenerated"] {
                guard source.string(for: .seriesInstanceUID) != "2.25.2365003" else { throw DicomPipelineError.invalidEdit("UID regeneration was discarded") }
                return .init(operations: [])
            }
            if set == ["check-deidentified"] {
                guard source.string(for: 0x0012_0062) == "YES", source.string(for: .patientName) != "Parity^Case" else {
                    throw DicomPipelineError.invalidEdit("de-identification was discarded")
                }
                return .init(operations: [])
            }
            return .init(operations: [.set(DicomTagPath(DicomTag.studyDescription.rawValue),
                                          .init(tag: DicomTag.studyDescription.rawValue, vr: .LO, value: .strings(set)))])
        }
        XCTAssertEqual(report.files.first?.status, "ok", String(describing: report.files.first))
        XCTAssertEqual(report.files.first?.steps.count, pipeline.steps.count)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func test_pipeline_dryRun_keepsPixelFillsForFollowingSteps() async throws {
        let input = directory.appendingPathComponent("pixels.dcm")
        let original = try Self.part10(try Self.gray16())
        try original.write(to: input)
        let edit = DicomPixelEdit(region: .init(x: 0, y: 0, width: 1, height: 1), sample: 9)
        let pipeline = DicomDatasetPipeline(name: "pixels", steps: [.pixelFill(edit), .pixelFill(edit)])
        let report = try await DicomPipelineRunner.run(pipeline, inputs: [input], options: .init(dryRun: true), editParser: parser)
        XCTAssertEqual(report.files.first?.status, "ok")
        let steps = try XCTUnwrap(report.files.first?.steps)
        XCTAssertEqual(steps.map(\.changes), [1, 0])
        XCTAssertEqual(steps.map(\.status), ["planned", "planned"])
        XCTAssertEqual(steps[1].pixelEdit?.sourceSOPInstanceUID, steps[0].pixelEdit?.derivedSOPInstanceUID)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func test_pipeline_honoursCancellationBetweenFiles() async throws {
        let pipeline = DicomDatasetPipeline(name: "cancel", steps: [.dump(maxPreviewBytes: 4)])
        let good = directory.appendingPathComponent("good.dcm")
        try Self.part10(try Self.gray16()).write(to: good)
        let parser = self.parser
        let task = Task { () -> DicomPipelineReport in
            try await Task.sleep(nanoseconds: 200_000_000)
            return try await DicomPipelineRunner.run(pipeline, inputs: [good, good], options: .init(), editParser: parser)
        }
        task.cancel()
        do {
            let report = try await task.value
            XCTAssertTrue(report.cancelled); XCTAssertTrue(report.files.isEmpty)
        } catch is CancellationError {
            // Cancelled inside the sleep before the runner started: also acceptable.
        }
    }

    // MARK: benchmark

    func test_benchmark_recordsDigestsVersionsAndFailures() throws {
        let corpus = directory.appendingPathComponent("corpus")
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let data = try Self.part10(try Self.gray16(frames: 2))
        try data.write(to: corpus.appendingPathComponent("a.dcm"))
        try Data("junk".utf8).write(to: corpus.appendingPathComponent("b.dcm"))
        let result = try DicomDecodeBenchmark.run(corpus: corpus, options: .init(iterations: 2, toolkitVersion: "test 1"))
        XCTAssertEqual(result.toolkitVersion, "test 1"); XCTAssertEqual(result.disclaimer, DicomDecodeBenchmarkResult.disclaimer)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(result.files[0].frames, 2); XCTAssertEqual(result.files[0].iterations, 2); XCTAssertNotNil(result.files[0].medianSeconds)
        XCTAssertEqual(result.files[0].sha256.count, 64)
        XCTAssertNotNil(result.files[1].error); XCTAssertNil(result.files[1].medianSeconds)
        XCTAssertThrowsError(try DicomDecodeBenchmark.run(corpus: directory.appendingPathComponent("missing"), options: .init(toolkitVersion: "t"))) {
            XCTAssertEqual($0 as? DicomDecodeBenchmark.Failure, .corpusNotFound(self.directory.appendingPathComponent("missing").path))
        }
        XCTAssertThrowsError(try DicomDecodeBenchmark.run(corpus: corpus, options: .init(maximumFiles: 1, toolkitVersion: "t")))
        XCTAssertTrue(try DicomDecodeBenchmark.run(corpus: corpus, options: .init(toolkitVersion: "t"), isCancelled: { true }).cancelled)
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T, _ handler: (Error) -> Void = { _ in }, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) } catch { handler(error) }
}
