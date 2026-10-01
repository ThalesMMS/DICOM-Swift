//
//  ParityCommands.swift
//
//  Thin adapters over shared DicomCore APIs added for CLI parity (#2365): uid, dump, image, measure,
//  pixel, report, study, script and bench. Every command calls the same library entry point the
//  API tests exercise; no algorithm lives only in the CLI.
//

import ArgumentParser
import CoreGraphics
import DicomCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ParityIO {
    static let toolkitVersion = "dicomtool \(DicomTool.configuration.version)"

    static func readInput(_ path: String) throws -> Data {
        if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.fileNotReadable(path: path, reason: "File does not exist") }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    static func writeOutput(_ data: Data, to path: String?, force: Bool) throws {
        guard let path, path != "-" else { FileHandle.standardOutput.write(data); return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path), !force { throw CLIError.outputFileExists(path: path) }
        do { try data.write(to: url, options: .atomic) } catch { throw CLIError.fileNotWritable(path: path, reason: error.localizedDescription) }
    }

    static func json<T: Encodable>(_ value: T) throws -> String { try OutputFormatter(format: .json, prettyPrint: true).formatJSON(value) }

    static func decoder(_ path: String) throws -> DCMDecoder {
        let data = try readInput(path)
        do { return try DCMDecoder(data: data) } catch { throw CLIError.invalidDICOMFile(path: path, reason: String(describing: error)) }
    }

    static func region(_ text: String, argument: String) throws -> (x: Int, y: Int, width: Int, height: Int) {
        let parts = text.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4, let x = parts[0], let y = parts[1], let width = parts[2], let height = parts[3] else {
            throw CLIError.invalidArgument(argument: argument, value: text, reason: "expected X,Y,WIDTH,HEIGHT")
        }
        return (x, y, width, height)
    }
}

// MARK: - uid

struct UIDCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uid", abstract: "Generate, validate or list UIDs (metadata only)",
        subcommands: [Generate.self, Check.self, List.self], defaultSubcommand: Generate.self)

    struct Generate: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "generate", abstract: "Print new 2.25 UIDs")
        @Option(name: .long, help: "How many UIDs to print (1-1000)") var count: Int = 1
        mutating func run() throws {
            guard (1...1000).contains(count) else { throw CLIError.invalidArgument(argument: "--count", value: String(count), reason: "expected 1-1000") }
            for _ in 0..<count { print(DicomDataSetWriter.makeUID()) }
        }
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "check", abstract: "Validate UID syntax; exit 1 when any is invalid")
        @Argument(help: "UIDs to check") var uids: [String]
        @Flag(name: .long, help: "JSON output") var json = false
        mutating func run() throws {
            let results = uids.map { ["uid": $0, "valid": DicomDataSetEditor.isValidUID($0) ? "true" : "false"] }
            if json { print(try ParityIO.json(results)) } else { for result in results { print("\(result["uid"]!)\t\(result["valid"]!)") } }
            if results.contains(where: { $0["valid"] == "false" }) { throw ExitCode(1) }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List identity and referenced UIDs of a Part 10 file")
        @Argument(help: "Part 10 input (- for stdin)", completion: .file()) var input: String
        @Flag(name: .long, help: "JSON output") var json = false
        mutating func run() throws {
            let inspection = DicomPart10Rewriter().inspectUIDs(in: try ParityIO.decoder(input).dataSet)
            let object: [String: Any] = ["studyInstanceUID": inspection.studyInstanceUID ?? "", "seriesInstanceUID": inspection.seriesInstanceUID ?? "",
                                         "sopInstanceUID": inspection.sopInstanceUID ?? "", "frameOfReferenceUIDs": inspection.frameOfReferenceUIDs.sorted(),
                                         "referenced": inspection.allUIDValues.sorted()]
            if json {
                print(String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            } else {
                print("Study:    \(inspection.studyInstanceUID ?? "-")")
                print("Series:   \(inspection.seriesInstanceUID ?? "-")")
                print("Instance: \(inspection.sopInstanceUID ?? "-")")
                for uid in inspection.allUIDValues.sorted() { print("ref " + uid) }
            }
        }
    }
}

// MARK: - dump

struct DumpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump", abstract: "Structural element dump with bounded hex previews (metadata only)")
    @Argument(help: "Part 10 input (- for stdin)", completion: .file()) var input: String
    @Flag(name: .long, help: "JSON output") var json = false
    @Option(name: .long, help: "Bytes previewed from binary values") var previewBytes: Int = 32
    @Option(name: .long, help: "Maximum sequence depth") var maxDepth: Int = 16
    @Flag(name: .long, help: "Show identifying text values instead of (redacted)") var noRedact = false
    @Flag(name: .long, help: "Omit hex previews") var noHex = false

    mutating func run() throws {
        guard previewBytes >= 0, previewBytes <= 4096 else { throw CLIError.invalidArgument(argument: "--preview-bytes", value: String(previewBytes), reason: "expected 0-4096") }
        let decoder = try ParityIO.decoder(input)
        let lines = DicomElementDump.lines(for: decoder.dataSet, options: .init(maxPreviewBytes: previewBytes, maxDepth: maxDepth, includeHex: !noHex, redactIdentifiers: !noRedact))
        print(json ? try ParityIO.json(lines) : DicomElementDump.text(lines))
    }
}

// MARK: - image

struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "image", abstract: "Image files to Secondary Capture, contact sheets from DICOM frames, and pixel comparison",
        subcommands: [ToDicom.self, ContactSheet.self, ImageCompareCommand.self])

    struct ToDicom: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "to-dicom", abstract: "Wrap a PNG/JPEG/TIFF image as a Secondary Capture object")
        @Argument(help: "Image file", completion: .file()) var input: String
        @Option(name: [.short, .long], help: "Output Part 10 file") var output: String
        @Option(name: .long, help: "Patient Name") var patientName: String?
        @Option(name: .long, help: "Patient ID") var patientId: String?
        @Option(name: .long, help: "Study Instance UID (generated when omitted)") var studyUid: String?
        @Option(name: .long, help: "Series Instance UID (generated when omitted)") var seriesUid: String?
        @Flag(name: .long, help: "Overwrite the output") var force = false

        mutating func run() throws {
            let url = URL(fileURLWithPath: input)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CLIError.fileNotReadable(path: input, reason: "not a decodable image")
            }
            let options = DicomSecondaryCaptureBuildOptions(studyInstanceUID: studyUid, seriesInstanceUID: seriesUid, patientName: patientName, patientID: patientId,
                                                            derivationDescription: "Converted from \(url.lastPathComponent) by dicomtool image to-dicom")
            let data: Data
            do { data = try DicomSecondaryCaptureBuilder.part10Data(from: image, options: options) } catch {
                throw CLIError.validationFailed(file: input, errors: [String(describing: error)])
            }
            try ParityIO.writeOutput(data, to: output, force: force)
            FileHandle.standardError.write(Data("\(image.width)x\(image.height) image written to \(output)\n".utf8))
        }
    }

    struct ContactSheet: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "contact-sheet", abstract: "Render frames of one or more files into a single PNG grid")
        @Argument(help: "Part 10 inputs", completion: .file()) var inputs: [String]
        @Option(name: [.short, .long], help: "Output PNG") var output: String
        @Option(name: .long, help: "Columns in the grid") var columns: Int = 4
        @Option(name: .long, help: "Cell size in pixels") var cell: Int = 128
        @Option(name: .long, help: "Maximum frames taken from each input") var maxFrames: Int = 16
        @Flag(name: .long, help: "Overwrite the output") var force = false

        mutating func run() throws {
            guard columns > 0, cell > 0, maxFrames > 0 else { throw CLIError.invalidArgument(argument: "--columns/--cell/--max-frames", value: "", reason: "must be positive") }
            let result = try DicomContactSheet.render(inputs: inputs.map(URL.init(fileURLWithPath:)), columns: columns, cellSize: cell, maxFramesPerInput: maxFrames)
            try ParityIO.writeOutput(result.png, to: output, force: force)
            FileHandle.standardError.write(Data("\(result.tiles) tile(s), \(result.skipped.count) skipped\n".utf8))
            for skip in result.skipped { FileHandle.standardError.write(Data("skipped \(skip)\n".utf8)) }
        }
    }
}

// MARK: - measure

struct MeasureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "measure", abstract: "Pixel statistics and distances (pixel decode, read only)",
        subcommands: [Stats.self, Distance.self])

    struct Stats: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "stats", abstract: "Min/max/mean/SD and histogram of a frame or region")
        @Argument(help: "Part 10 input", completion: .file()) var input: String
        @Option(name: .long, help: "Frame index") var frame: Int = 0
        @Option(name: .long, help: "Region X,Y,WIDTH,HEIGHT (whole frame when omitted)") var region: String?
        @Option(name: .long, help: "Histogram bins") var bins: Int = 64
        @Flag(name: .long, help: "JSON output") var json = false

        mutating func run() throws {
            let reader = DicomDecodedFrameReader(decoder: try ParityIO.decoder(input))
            let decoded: DicomDecodedFrame
            do { decoded = try reader.frame(at: frame) } catch { throw CLIError.validationFailed(file: input, errors: [String(describing: error)]) }
            let area = try region.map { let r = try ParityIO.region($0, argument: "--region"); return DicomPixelStatistics.Region(x: r.x, y: r.y, width: r.width, height: r.height) }
            let statistics: DicomPixelStatistics
            do { statistics = try DicomPixelMeasurement.statistics(frame: decoded, region: area, bins: bins) } catch {
                throw CLIError.invalidArgument(argument: "--region", value: region ?? "", reason: error.localizedDescription)
            }
            if json { print(try ParityIO.json(statistics)); return }
            print("frame \(statistics.frame) region \(statistics.region.x),\(statistics.region.y) \(statistics.region.width)x\(statistics.region.height) samples \(statistics.sampleCount)")
            print("min \(statistics.minimum) max \(statistics.maximum) mean \(statistics.mean) sd \(statistics.standardDeviation)")
            if let minimum = statistics.rescaledMinimum, let maximum = statistics.rescaledMaximum, let mean = statistics.rescaledMean {
                print("rescaled min \(minimum) max \(maximum) mean \(mean)" + (statistics.rescaleType.map { " (" + $0 + ")" } ?? ""))
            }
        }
    }

    struct Distance: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "distance", abstract: "Distance between two pixels, in pixels and millimetres when Pixel Spacing exists")
        @Argument(help: "Part 10 input", completion: .file()) var input: String
        @Option(name: .long, help: "Start pixel X,Y") var from: String
        @Option(name: .long, help: "End pixel X,Y") var to: String
        @Flag(name: .long, help: "JSON output") var json = false

        mutating func run() throws {
            func point(_ text: String, argument: String) throws -> (Int, Int) {
                let parts = text.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 2, let x = parts[0], let y = parts[1] else { throw CLIError.invalidArgument(argument: argument, value: text, reason: "expected X,Y") }
                return (x, y)
            }
            let start = try point(from, argument: "--from"), end = try point(to, argument: "--to")
            let dataSet = try ParityIO.decoder(input).dataSet
            let distance = DicomPixelMeasurement.distance(fromX: start.0, fromY: start.1, toX: end.0, toY: end.1, pixelSpacing: DicomPixelMeasurement.pixelSpacing(from: dataSet))
            if json { print(try ParityIO.json(distance)); return }
            print("\(distance.pixels) px" + (distance.millimeters.map { " = \($0) mm" } ?? " (no Pixel Spacing)"))
        }
    }
}

// MARK: - pixel

struct PixelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pixel", abstract: "Replace a pixel region (mutation; derived object with new SOP Instance UID)",
        subcommands: [Fill.self])

    struct Fill: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "fill", abstract: "Fill a rectangle with a stored sample value",
            discussion: "Native pixel data only. The result is DERIVED with a Source Image Sequence; --dry-run reports the plan without writing.")
        @Argument(help: "Part 10 input", completion: .file()) var input: String
        @Option(name: [.short, .long], help: "Output Part 10 file (required unless --dry-run)") var output: String?
        @Option(name: .long, help: "Region X,Y,WIDTH,HEIGHT") var region: String
        @Option(name: .long, help: "Stored sample value") var value: Int
        @Option(name: .long, parsing: .singleValue, help: "Frame index, repeatable (all frames when omitted)") var frame: [Int] = []
        @Option(name: .long, help: "Intent: redaction or annotation") var intent: String = "redaction"
        @Option(name: .long, help: "Derivation Description") var description: String?
        @Flag(name: .long, help: "Plan only; write nothing") var dryRun = false
        @Flag(name: .long, help: "JSON report") var json = false
        @Flag(name: .long, help: "Overwrite the output") var force = false

        mutating func run() throws {
            guard let intentValue = DicomPixelEdit.Intent(rawValue: intent) else { throw CLIError.invalidArgument(argument: "--intent", value: intent, reason: "expected redaction or annotation") }
            let area = try ParityIO.region(region, argument: "--region")
            let edit = DicomPixelEdit(region: .init(x: area.x, y: area.y, width: area.width, height: area.height), sample: value, frames: frame.isEmpty ? nil : frame,
                                      intent: intentValue, derivationDescription: description)
            let data = try ParityIO.readInput(input)
            let report: DicomPixelEditReport
            do {
                if dryRun { report = try DicomPixelEditor.plan(edit, part10: data) } else {
                    guard let output else { throw CLIError.missingRequiredArgument(argument: "--output") }
                    guard URL(fileURLWithPath: output).standardizedFileURL.path != URL(fileURLWithPath: input).standardizedFileURL.path else {
                        throw CLIError.invalidPath(path: output, reason: "the output must differ from the input; pixel edits are never applied in place")
                    }
                    let result = try DicomPixelEditor.apply(edit, part10: data)
                    try ParityIO.writeOutput(result.fileData, to: output, force: force)
                    report = result.report
                }
            } catch let error as DicomPixelEditError {
                throw CLIError.validationFailed(file: input, errors: [error.localizedDescription])
            }
            if json { print(try ParityIO.json(report)); return }
            print("\(dryRun ? "planned" : "wrote") \(report.samplesChanged) changed sample(s) of \(report.samplesWritten) in frames \(report.framesEdited)")
            print("derived \(report.derivedSOPInstanceUID) from \(report.sourceSOPInstanceUID) (\(report.intent.rawValue))")
        }
    }
}

// MARK: - report

struct ReportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "report", abstract: "Render a Structured Report content tree as text, HTML or JSON (metadata only)")
    @Argument(help: "SR Part 10 input (- for stdin)", completion: .file()) var input: String
    @Option(name: .long, help: "text, html or json") var format: String = "text"
    @Option(name: [.short, .long], help: "Output file (stdout when omitted)") var output: String?
    @Flag(name: .long, help: "Overwrite the output") var force = false

    mutating func run() throws {
        guard let document = try ParityIO.decoder(input).structuredReport else {
            throw CLIError.invalidDICOMFile(path: input, reason: "not a Structured Report object")
        }
        let rendered: Data
        switch format {
        case "text": rendered = Data(DicomStructuredReportRenderer.text(document).utf8)
        case "html": rendered = Data(DicomStructuredReportRenderer.html(document).utf8)
        case "json": rendered = try DicomStructuredReportRenderer.jsonData(document) + Data("\n".utf8)
        default: throw CLIError.invalidArgument(argument: "--format", value: format, reason: "expected text, html or json")
        }
        try ParityIO.writeOutput(rendered, to: output, force: force)
    }
}

// MARK: - study

struct StudyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "study", abstract: "Organise loose files into patient/study/series folders (plan by default)",
        subcommands: [Organize.self])

    struct Organize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "organize", abstract: "Plan a folder layout; --apply copies or moves after the plan is shown")
        @Argument(help: "Input files or directories", completion: .file()) var inputs: [String]
        @Option(name: .long, help: "Destination root") var into: String
        @Flag(name: .long, help: "Perform the plan (copy unless --move)") var apply = false
        @Flag(name: .long, help: "Move instead of copy") var move = false
        @Flag(name: .long, help: "Skip the patient level") var noPatientLevel = false
        @Flag(name: .long, help: "JSON output") var json = false

        mutating func run() async throws {
            var files: [URL] = []
            for input in inputs {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: input, isDirectory: &isDirectory) else { throw CLIError.fileNotReadable(path: input, reason: "File does not exist") }
                if isDirectory.boolValue {
                    let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: input), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    while let url = enumerator?.nextObject() as? URL {
                        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
                    }
                } else { files.append(URL(fileURLWithPath: input)) }
            }
            let plan = await DicomStudyOrganizer.plan(files: files, into: URL(fileURLWithPath: into), options: .init(includePatientLevel: !noPatientLevel))
            var result: DicomStudyOrganizerResult?
            if apply { result = DicomStudyOrganizer.apply(plan, mode: move ? .move : .copy, isCancelled: { Task.isCancelled }) }
            if json {
                struct Output: Encodable { let plan: DicomStudyOrganizerPlan; let result: DicomStudyOrganizerResult? }
                print(try ParityIO.json(Output(plan: plan, result: result)))
            } else {
                for entry in plan.entries {
                    if let destination = entry.destination { print("\(entry.source) -> \(destination)") } else { print("skip \(entry.source): \(entry.skipReason ?? "")") }
                }
                print("\(plan.planned.count) planned, \(plan.skipped.count) skipped, \(plan.studyCount) stud\(plan.studyCount == 1 ? "y" : "ies")" + (apply ? "" : " (plan only; add --apply)"))
                if let result { print("\(result.applied.count) applied, \(result.failures.count) failed\(result.cancelled ? ", cancelled" : "")") }
            }
            if let result, !result.failures.isEmpty { throw ExitCode(1) }
        }
    }
}

// MARK: - script

struct ScriptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "script", abstract: "Run a declarative JSON pipeline over files (no code evaluation)",
        discussion: "Steps: \(DicomDatasetPipeline.supportedStepNames.joined(separator: ", ")). Secrets are declared as env:VARIABLE references and never printed.",
        subcommands: [Run.self, Check.self], defaultSubcommand: Run.self)

    static func load(_ path: String) throws -> DicomDatasetPipeline {
        let data = try ParityIO.readInput(path)
        do { return try JSONDecoder().decode(DicomDatasetPipeline.self, from: data) } catch {
            throw CLIError.invalidArgument(argument: "pipeline", value: path, reason: String(describing: error))
        }
    }

    static let editParser: DicomPipelineRunner.EditParser = { set, remove, source in
        try EditCommand.plan(set: set, remove: remove, replaceUid: [], newUid: [], createItems: false, source: source)
    }

    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "check", abstract: "Parse a pipeline and print its normalised form")
        @Argument(help: "Pipeline JSON", completion: .file()) var pipeline: String
        mutating func run() throws { print(try ParityIO.json(try ScriptCommand.load(pipeline))) }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run", abstract: "Execute a pipeline; per-file failures are reported and do not stop other files")
        @Argument(help: "Pipeline JSON", completion: .file()) var pipeline: String
        @Argument(help: "Input Part 10 files", completion: .file()) var inputs: [String]
        @Option(name: .long, help: "Output directory for write/export steps") var outputDir: String?
        @Flag(name: .long, help: "Plan every step without writing") var dryRun = false
        @Flag(name: .long, help: "JSON report") var json = false

        mutating func run() async throws {
            let definition = try ScriptCommand.load(pipeline)
            let report: DicomPipelineReport
            do {
                report = try await DicomPipelineRunner.run(definition, inputs: inputs.map(URL.init(fileURLWithPath:)),
                    options: .init(outputDirectory: outputDir.map(URL.init(fileURLWithPath:)), dryRun: dryRun), editParser: ScriptCommand.editParser)
            } catch {
                throw CLIError.invalidArgument(argument: "pipeline", value: pipeline, reason: error.localizedDescription)
            }
            if json { print(try ParityIO.json(report)) } else {
                for file in report.files {
                    print("\(file.status) \(file.input)")
                    for step in file.steps { print("  \(step.op): \(step.status)" + (step.detail.map { " " + $0 } ?? "") + (step.output.map { " -> " + $0 } ?? "")) }
                }
                print("\(report.files.count - report.failed.count) ok, \(report.failed.count) failed" + (report.cancelled ? ", cancelled" : ""))
            }
            if !report.failed.isEmpty || report.cancelled { throw ExitCode(1) }
        }
    }
}

// MARK: - bench

struct BenchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bench", abstract: "Decode timings over an explicit corpus with digests and versions (not a clinical claim)")
    @Argument(help: "Corpus directory or file", completion: .file()) var corpus: String
    @Option(name: .long, help: "Iterations per file") var iterations: Int = 3
    @Option(name: .long, help: "Maximum files") var maxFiles: Int = 500
    @Option(name: [.short, .long], help: "JSON result file (stdout when omitted)") var output: String?
    @Flag(name: .long, help: "Overwrite the output") var force = false

    mutating func run() throws {
        let result: DicomDecodeBenchmarkResult
        do {
            result = try DicomDecodeBenchmark.run(corpus: URL(fileURLWithPath: corpus), options: .init(iterations: iterations, maximumFiles: maxFiles, toolkitVersion: ParityIO.toolkitVersion))
        } catch let error as DicomDecodeBenchmark.Failure {
            throw CLIError.fileNotReadable(path: corpus, reason: error.localizedDescription)
        }
        try ParityIO.writeOutput(Data((try ParityIO.json(result) + "\n").utf8), to: output, force: force)
        if output != nil { FileHandle.standardError.write(Data("\(result.files.count) file(s); \(result.disclaimer)\n".utf8)) }
    }
}
