import Foundation

/// Declarative, bounded data set pipelines. A pipeline is plain JSON: named steps drawn from a fixed
/// vocabulary run in order over each input file. Nothing in a pipeline is evaluated as code, and
/// values read from DICOM files never become step parameters. Secrets are referenced by name and
/// resolved through a `DicomPipelineSecretProvider`; reports carry only the reference name.
public struct DicomDatasetPipeline: Codable, Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// Structural dump of the input (metadata only).
        case dump(maxPreviewBytes: Int)
        /// Instance validation through `DicomInstanceValidator`; `failOn` = `error` stops the file with a failure.
        case validate(failOnError: Bool)
        /// Path-addressed attribute edits (`PATH[:VR]=VALUE` strings, same grammar as `dicomtool edit`).
        case set([String])
        case remove([String])
        case regenerateUID(DicomDataSetEdit.IdentityScope)
        /// Pixel region replacement (native pixel data only).
        case pixelFill(DicomPixelEdit)
        /// De-identification with the basic profile plus options.
        case deidentify(options: [String])
        /// Writes the current object to `directory/<basename><suffix>.dcm`.
        case write(suffix: String)
        /// PNG/JPEG/TIFF export of frame 0 through `DicomImageExporter`.
        case exportImage(format: String)
        /// Records a secret reference for a later consumer without exposing its value in the report.
        case requireSecret(name: String)
    }

    public var name: String
    public var steps: [Step]
    /// Secret references: name -> provider locator (`env:VAR`). Values are never stored in the pipeline.
    public var secrets: [String: String]

    public init(name: String, steps: [Step], secrets: [String: String] = [:]) {
        self.name = name
        self.steps = steps
        self.secrets = secrets
    }

    public static let supportedStepNames = ["dump", "validate", "set", "remove", "regenerate-uid", "pixel-fill", "deidentify", "write", "export-image", "require-secret"]
    public static let maximumSteps = 64
    public static let maximumInputs = 10_000

    fileprivate static func isValidWriteSuffix(_ suffix: String) -> Bool {
        !suffix.contains("/") && !suffix.contains("..") && suffix.count <= 32
    }

    enum CodingKeys: String, CodingKey { case name, steps, secrets }
    private struct StepBox: Codable {
        var op: String
        var maxPreviewBytes: Int?
        var failOnError: Bool?
        var values: [String]?
        var scope: String?
        var region: DicomPixelEdit.Region?
        var sample: Int?
        var frames: [Int]?
        var intent: DicomPixelEdit.Intent?
        var description: String?
        var options: [String]?
        var suffix: String?
        var format: String?
        var name: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        secrets = try container.decodeIfPresent([String: String].self, forKey: .secrets) ?? [:]
        let boxes = try container.decode([StepBox].self, forKey: .steps)
        guard boxes.count <= Self.maximumSteps else {
            throw DecodingError.dataCorruptedError(forKey: .steps, in: container, debugDescription: "more than \(Self.maximumSteps) steps")
        }
        steps = try boxes.map { box in
            func bad(_ reason: String) -> DecodingError {
                DecodingError.dataCorruptedError(forKey: .steps, in: container, debugDescription: "\(box.op): \(reason)")
            }
            switch box.op {
            case "dump": return .dump(maxPreviewBytes: box.maxPreviewBytes ?? 32)
            case "validate": return .validate(failOnError: box.failOnError ?? true)
            case "set": guard let values = box.values, !values.isEmpty else { throw bad("values required") }; return .set(values)
            case "remove": guard let values = box.values, !values.isEmpty else { throw bad("values required") }; return .remove(values)
            case "regenerate-uid":
                guard let scope = box.scope.flatMap(DicomDataSetEdit.IdentityScope.init(rawValue:)) else { throw bad("scope must be instance, series, study or frameOfReference") }
                return .regenerateUID(scope)
            case "pixel-fill":
                guard let region = box.region, let sample = box.sample else { throw bad("region and sample required") }
                return .pixelFill(DicomPixelEdit(region: region, sample: sample, frames: box.frames, intent: box.intent ?? .redaction, derivationDescription: box.description))
            case "deidentify": return .deidentify(options: box.options ?? [])
            case "write":
                let suffix = box.suffix ?? "-out"
                guard Self.isValidWriteSuffix(suffix) else { throw bad("suffix must be a short file name fragment") }
                return .write(suffix: suffix)
            case "export-image":
                guard let format = box.format, ["png", "jpeg", "tiff"].contains(format) else { throw bad("format must be png, jpeg or tiff") }
                return .exportImage(format: format)
            case "require-secret": guard let name = box.name, !name.isEmpty else { throw bad("name required") }; return .requireSecret(name: name)
            default: throw bad("unknown step; supported: \(Self.supportedStepNames.joined(separator: ", "))")
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(secrets, forKey: .secrets)
        try container.encode(steps.map { step -> StepBox in
            switch step {
            case .dump(let bytes): return StepBox(op: "dump", maxPreviewBytes: bytes)
            case .validate(let fail): return StepBox(op: "validate", failOnError: fail)
            case .set(let values): return StepBox(op: "set", values: values)
            case .remove(let values): return StepBox(op: "remove", values: values)
            case .regenerateUID(let scope): return StepBox(op: "regenerate-uid", scope: scope.rawValue)
            case .pixelFill(let edit):
                return StepBox(op: "pixel-fill", region: edit.region, sample: edit.sample, frames: edit.frames, intent: edit.intent, description: edit.derivationDescription)
            case .deidentify(let options): return StepBox(op: "deidentify", options: options)
            case .write(let suffix): return StepBox(op: "write", suffix: suffix)
            case .exportImage(let format): return StepBox(op: "export-image", format: format)
            case .requireSecret(let name): return StepBox(op: "require-secret", name: name)
            }
        }, forKey: .steps)
    }
}

/// Resolves secret references. The environment provider maps `env:NAME` to `ProcessInfo` variables.
public protocol DicomPipelineSecretProvider: Sendable {
    func secret(named name: String, locator: String) throws -> String
}

public struct DicomEnvironmentSecretProvider: DicomPipelineSecretProvider {
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case unsupportedLocator(String)
        case missing(String)
        public var errorDescription: String? {
            switch self {
            case .unsupportedLocator(let locator): return "Unsupported secret locator '\(locator)'; use env:VARIABLE"
            case .missing(let name): return "Secret '\(name)' is not available from the environment"
            }
        }
    }
    private let environment: [String: String]
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) { self.environment = environment }
    public func secret(named name: String, locator: String) throws -> String {
        guard locator.hasPrefix("env:") else { throw Failure.unsupportedLocator(locator) }
        guard let value = environment[String(locator.dropFirst(4))], !value.isEmpty else { throw Failure.missing(name) }
        return value
    }
}

public struct DicomPipelineReport: Codable, Equatable, Sendable {
    public struct StepOutcome: Codable, Equatable, Sendable {
        public let op: String
        public let status: String
        public let detail: String?
        public let output: String?
        public let changes: Int?
        public let dumpLineCount: Int?
        public let validationDiagnostics: Int?
        public let pixelEdit: DicomPixelEditReport?
    }
    public struct FileOutcome: Codable, Equatable, Sendable {
        public let input: String
        public let status: String
        public let steps: [StepOutcome]
    }
    public let pipeline: String
    public let dryRun: Bool
    public let files: [FileOutcome]
    public let secretsResolved: [String]
    public let cancelled: Bool
    public var failed: [FileOutcome] { files.filter { $0.status == "failed" } }
}

public enum DicomPipelineError: Error, Equatable, LocalizedError, Sendable {
    case tooManyInputs(Int)
    case outputDirectoryRequired
    case invalidEdit(String)
    public var errorDescription: String? {
        switch self {
        case .tooManyInputs(let count): return "\(count) inputs exceed the limit of \(DicomDatasetPipeline.maximumInputs)"
        case .outputDirectoryRequired: return "Steps that write need an output directory"
        case .invalidEdit(let reason): return reason
        }
    }
}

public enum DicomPipelineRunner {
    public struct Options: Sendable {
        public var outputDirectory: URL?
        /// Plans and validates every step without writing files.
        public var dryRun: Bool
        public var secretProvider: any DicomPipelineSecretProvider
        public var uidRoot: String
        public init(outputDirectory: URL? = nil, dryRun: Bool = false,
                    secretProvider: any DicomPipelineSecretProvider = DicomEnvironmentSecretProvider(), uidRoot: String = "2.25") {
            self.outputDirectory = outputDirectory
            self.dryRun = dryRun
            self.secretProvider = secretProvider
            self.uidRoot = uidRoot
        }
    }

    /// Edit parser shared with the CLI: `PATH[:VR]=VALUE`.
    public typealias EditParser = @Sendable (_ set: [String], _ remove: [String], _ source: DicomDataSet) throws -> DicomDataSetEdit

    /// Runs the pipeline over every input; a failing file does not stop the others. Honours task
    /// cancellation between files and marks the report as cancelled.
    public static func run(_ pipeline: DicomDatasetPipeline, inputs: [URL], options: Options, editParser: @escaping EditParser) async throws -> DicomPipelineReport {
        guard inputs.count <= DicomDatasetPipeline.maximumInputs else { throw DicomPipelineError.tooManyInputs(inputs.count) }
        for case .write(let suffix) in pipeline.steps {
            guard DicomDatasetPipeline.isValidWriteSuffix(suffix) else {
                throw DicomPipelineError.invalidEdit("write: suffix must be a short file name fragment")
            }
        }
        let writes = pipeline.steps.contains { if case .write = $0 { return true }; if case .exportImage = $0 { return true }; return false }
        if writes, !options.dryRun, options.outputDirectory == nil { throw DicomPipelineError.outputDirectoryRequired }
        var resolved: [String] = []
        for case .requireSecret(let name) in pipeline.steps {
            guard let locator = pipeline.secrets[name] else { throw DicomPipelineError.invalidEdit("secret '\(name)' is not declared in the pipeline") }
            _ = try options.secretProvider.secret(named: name, locator: locator)
            resolved.append(name)
        }
        if let directory = options.outputDirectory, writes, !options.dryRun {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var files: [DicomPipelineReport.FileOutcome] = []
        var cancelled = false
        for input in inputs {
            if Task.isCancelled { cancelled = true; break }
            files.append(await process(input, pipeline: pipeline, options: options, editParser: editParser))
        }
        return DicomPipelineReport(pipeline: pipeline.name, dryRun: options.dryRun, files: files, secretsResolved: resolved, cancelled: cancelled)
    }

    private static func process(_ input: URL, pipeline: DicomDatasetPipeline, options: Options, editParser: EditParser) async -> DicomPipelineReport.FileOutcome {
        var outcomes: [DicomPipelineReport.StepOutcome] = []
        var current: Data
        do { current = try Data(contentsOf: input, options: .mappedIfSafe) } catch {
            return .init(input: input.path, status: "failed", steps: [.init(op: "read", status: "failed", detail: error.localizedDescription, output: nil, changes: nil, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil)])
        }
        let base = input.deletingPathExtension().lastPathComponent
        for step in pipeline.steps {
            let name: String
            do {
                switch step {
                case .dump(let bytes):
                    name = "dump"
                    let decoder = try DCMDecoder(data: current)
                    let lines = DicomElementDump.lines(for: decoder.dataSet, options: .init(maxPreviewBytes: bytes))
                    outcomes.append(.init(op: name, status: "ok", detail: nil, output: nil, changes: nil, dumpLineCount: lines.count, validationDiagnostics: nil, pixelEdit: nil))
                case .validate(let failOnError):
                    name = "validate"
                    let report = try DicomInstanceValidator.validate(current)
                    let errors = report.diagnostics.filter { $0.severity == .error }.count
                    if failOnError, errors > 0 {
                        outcomes.append(.init(op: name, status: "failed", detail: "\(errors) validation error(s)", output: nil, changes: nil, dumpLineCount: nil, validationDiagnostics: report.diagnostics.count, pixelEdit: nil))
                        return .init(input: input.path, status: "failed", steps: outcomes)
                    }
                    outcomes.append(.init(op: name, status: "ok", detail: nil, output: nil, changes: nil, dumpLineCount: nil, validationDiagnostics: report.diagnostics.count, pixelEdit: nil))
                case .set(let values), .remove(let values):
                    let isSet: Bool
                    if case .set = step { isSet = true; name = "set" } else { isSet = false; name = "remove" }
                    let source = try DicomPart10PixelDataPreserver.dataSet(from: try DCMDecoder(data: current))
                    let edit = try editParser(isSet ? values : [], isSet ? [] : values, source)
                    let (result, editResult) = try DicomDataSetEditor.apply(edit, toPart10: current)
                    current = result.fileData
                    outcomes.append(.init(op: name, status: "ok", detail: nil, output: nil, changes: editResult.diff.changes.count, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil))
                case .regenerateUID(let scope):
                    name = "regenerate-uid"
                    let (result, editResult) = try DicomDataSetEditor.apply(DicomDataSetEdit(operations: [.regenerateUID(scope)]), toPart10: current)
                    current = result.fileData
                    outcomes.append(.init(op: name, status: "ok", detail: scope.rawValue, output: nil, changes: editResult.uidReplacements.count, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil))
                case .pixelFill(let edit):
                    name = "pixel-fill"
                    let output = try DicomPixelEditor.apply(edit, part10: current)
                    current = output.fileData
                    outcomes.append(.init(op: name, status: options.dryRun ? "planned" : "ok", detail: nil, output: nil,
                                          changes: output.report.samplesChanged, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: output.report))
                case .deidentify(let optionNames):
                    name = "deidentify"
                    let parsed = try Set(optionNames.map { text -> DicomDeidentificationTable.Option in
                        guard let value = DicomDeidentificationTable.Option(rawValue: text) else { throw DicomPipelineError.invalidEdit("unknown de-identification option '\(text)'") }
                        return value
                    })
                    let deidentifier = try DicomDeidentifier(profile: DicomDeidentificationProfile(options: parsed), session: DicomDeidentificationSession(uidRoot: options.uidRoot))
                    let (fileData, report) = try deidentifier.apply(current)
                    current = fileData
                    outcomes.append(.init(op: name, status: report.classification == .deidentifiedPerProfile ? "ok" : "failed", detail: report.classification.rawValue, output: nil, changes: report.actions.count, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil))
                    if report.classification != .deidentifiedPerProfile { return .init(input: input.path, status: "failed", steps: outcomes) }
                case .write(let suffix):
                    name = "write"
                    let target = (options.outputDirectory ?? input.deletingLastPathComponent()).appendingPathComponent(base + suffix + ".dcm")
                    if options.dryRun {
                        outcomes.append(.init(op: name, status: "planned", detail: nil, output: target.path, changes: nil, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil))
                    } else {
                        guard !FileManager.default.fileExists(atPath: target.path) else { throw DicomPipelineError.invalidEdit("refusing to overwrite \(target.lastPathComponent)") }
                        try current.write(to: target, options: .atomic)
                        outcomes.append(.init(op: name, status: "ok", detail: nil, output: target.path, changes: nil, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil))
                    }
                case .exportImage(let formatName):
                    name = "export-image"
                    let format: DicomImageExportFormat = formatName == "jpeg" ? .jpeg : formatName == "tiff" ? .tiff : .png
                    let target = (options.outputDirectory ?? input.deletingLastPathComponent()).appendingPathComponent(base + "." + format.rawValue)
                    if options.dryRun {
                        _ = try DCMDecoder(data: current)
                        outcomes.append(.init(op: name, status: "planned", detail: nil, output: target.path, changes: nil, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil))
                    } else {
                        let result = try DicomImageExporter().export(decoder: try DCMDecoder(data: current), frame: 0, to: target, options: .init(format: format))
                        outcomes.append(.init(op: name, status: "ok", detail: nil, output: result.imageURL.path, changes: nil, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil))
                    }
                case .requireSecret(let secretName):
                    name = "require-secret"
                    outcomes.append(.init(op: name, status: "ok", detail: secretName, output: nil, changes: nil, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil))
                }
            } catch {
                outcomes.append(.init(op: stepName(step), status: "failed", detail: String(describing: error), output: nil, changes: nil, dumpLineCount: nil, validationDiagnostics: nil, pixelEdit: nil))
                return .init(input: input.path, status: "failed", steps: outcomes)
            }
        }
        return .init(input: input.path, status: "ok", steps: outcomes)
    }

    static func stepName(_ step: DicomDatasetPipeline.Step) -> String {
        switch step {
        case .dump: return "dump"
        case .validate: return "validate"
        case .set: return "set"
        case .remove: return "remove"
        case .regenerateUID: return "regenerate-uid"
        case .pixelFill: return "pixel-fill"
        case .deidentify: return "deidentify"
        case .write: return "write"
        case .exportImage: return "export-image"
        case .requireSecret: return "require-secret"
        }
    }
}
