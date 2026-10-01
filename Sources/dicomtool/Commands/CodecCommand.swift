//
//  CodecCommand.swift
//  dicomtool
//
//  Thin filesystem/stdout adapter over DicomCodecWorkflowEngine.
//

import ArgumentParser
import DicomCore
import Foundation

struct CodecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codec",
        abstract: "Run shared codec inspection, decode, comparison, and transcode workflows",
        subcommands: [
            CodecCapabilitiesCommand.self,
            CodecInspectCommand.self,
            CodecValidateCommand.self,
            CodecDecodeCommand.self,
            CodecCompareCommand.self,
            CodecTranscodeCommand.self
        ]
    )
}

private struct CodecCapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Report codec backends, versions, source, and qualified operations"
    )

    @Option(name: [.short, .long], help: "Output format: text or json.")
    var format: OutputFormat = .text

    @Option(name: .long, help: "Qualify the pixel profile of this DICOM file; default is 2x2 unsigned 8-bit monochrome.")
    var file: String?

    func run() throws {
        do {
            let engine = DicomCodecWorkflowEngine()
            let report = try file.map { try engine.capabilities(for: CodecCommandSupport.read($0)) }
                ?? engine.capabilities()
            try CodecCommandSupport.emit(report, format: format)
        } catch {
            throw CodecCommandSupport.exit(for: error)
        }
    }
}

private struct CodecInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect pixel attributes, encapsulation, and eligible codec backends"
    )

    @Argument(help: "Path to a DICOM Part 10 file.", completion: .file(extensions: ["dcm", "dicom"]))
    var file: String

    @Option(name: [.short, .long], help: "Output format: text or json.")
    var format: OutputFormat = .text

    func run() throws {
        do {
            try CodecCommandSupport.emit(
                DicomCodecWorkflowEngine().inspect(try CodecCommandSupport.read(file)),
                format: format
            )
        } catch {
            throw CodecCommandSupport.exit(for: error)
        }
    }
}

private struct CodecValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate pixel attributes, frame mapping, BOT/EOT, and encapsulation"
    )

    @Argument(help: "Path to a DICOM Part 10 file.", completion: .file(extensions: ["dcm", "dicom"]))
    var file: String

    @Option(name: [.short, .long], help: "Output format: text or json.")
    var format: OutputFormat = .text

    func run() throws {
        do {
            let report = try DicomCodecWorkflowEngine().validate(try CodecCommandSupport.read(file))
            try CodecCommandSupport.emit(report, format: format)
            if !report.success {
                throw ExitCode(65)
            }
        } catch {
            throw CodecCommandSupport.exit(for: error)
        }
    }
}

private struct CodecDecodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode",
        abstract: "Decode selected frames into one raw in-memory pixel artifact"
    )

    @Argument(help: "Path to a DICOM Part 10 file.", completion: .file(extensions: ["dcm", "dicom"]))
    var file: String

    @Option(name: [.short, .long], help: "Raw decoded pixel artifact path.")
    var output: String

    @Option(name: .long, help: "Comma-separated zero-based frame indexes; defaults to all frames.")
    var frames: String?

    @Option(name: [.short, .long], help: "Report format: text or json.")
    var format: OutputFormat = .text

    @Option(name: .long, help: "Partial decode: number of highest resolution levels to discard (JPEG 2000/HTJ2K).")
    var resolutionLevel: Int?

    @Option(name: .long, help: "Partial decode: source region x,y,width,height in full-resolution pixels.")
    var region: String?

    @Option(name: .long, help: "Partial decode: highest quality layer to decode (cumulative, zero-based).")
    var maxLayer: Int?

    mutating func run() async throws {
        do {
            let data = try CodecCommandSupport.read(file)
            if resolutionLevel != nil || region != nil || maxLayer != nil {
                try await runPartial(data)
                return
            }
            let result = try await DicomCodecWorkflowEngine().decode(
                data,
                frameIndexes: try CodecCommandSupport.frameIndexes(frames)
            )
            try CodecCommandSupport.write(result.data, to: output)
            try CodecCommandSupport.emit(result.report, format: format)
        } catch {
            throw CodecCommandSupport.exit(for: error)
        }
    }

    /// Partial decode through the frame reader (`frame(at:partial:)`): the artifact carries the reader's pixel
    /// contract (16-bit samples offset for signed data, MONOCHROME1 inverted) at the reduced geometry.
    private func runPartial(_ data: Data) async throws {
        var sourceRegion: DicomFrameRegion?
        if let region {
            let parts = try region.split(separator: ",", omittingEmptySubsequences: false).map { component in
                guard let value = Int(component.trimmingCharacters(in: .whitespaces)) else {
                    throw ValidationError("--region must be x,y,width,height.")
                }
                return value
            }
            guard parts.count == 4 else { throw ValidationError("--region must be x,y,width,height.") }
            sourceRegion = DicomFrameRegion(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        }
        let request = try DicomPartialFrameDecodeRequest(sourceRegion: sourceRegion, resolutionReductionLevel: resolutionLevel ?? 0,
                                                         maximumQualityLayer: maxLayer)
        let decoder = try DCMDecoder(data: data)
        let reader = DicomDecodedFrameReader(decoder: decoder)
        let indexes = try CodecCommandSupport.frameIndexes(frames) ?? Array(0..<max(1, reader.frameCount))
        var artifact = Data()
        var frameReports: [PartialFrameReport] = []
        for index in indexes {
            let partial = try await reader.frame(at: index, partial: request)
            let frame = partial.frame
            let bytes: Data
            let samples: Int
            switch frame.pixels {
            case .gray8(let pixels): bytes = Data(pixels); samples = 1
            case .gray16(let pixels):
                var buffer = Data(count: pixels.count * 2)
                buffer.withUnsafeMutableBytes { raw in
                    let target = raw.bindMemory(to: UInt16.self)
                    for (offset, value) in pixels.enumerated() { target[offset] = value.littleEndian }
                }
                bytes = buffer; samples = 1
            case .rgb8(let interleaved): bytes = Data(interleaved); samples = 3
            }
            artifact.append(bytes)
            frameReports.append(PartialFrameReport(frame: index, width: frame.metadata.width, height: frame.metadata.height,
                                                   samplesPerPixel: samples, byteCount: bytes.count,
                                                   execution: partial.execution.rawValue, deliveredQualityLayer: partial.deliveredQualityLayer,
                                                   qualityState: String(describing: partial.qualityState), codecBytesAvoided: partial.codecBytesAvoided))
        }
        try CodecCommandSupport.write(artifact, to: output)
        let report = PartialDecodeReport(resolutionLevel: resolutionLevel ?? 0, region: region, maxLayer: maxLayer, frames: frameReports)
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        case .text:
            for frame in frameReports {
                print("frame \(frame.frame): \(frame.width)x\(frame.height)x\(frame.samplesPerPixel), \(frame.byteCount) bytes")
            }
        }
    }

    private struct PartialFrameReport: Encodable {
        let frame: Int
        let width: Int
        let height: Int
        let samplesPerPixel: Int
        let byteCount: Int
        let execution: String
        let deliveredQualityLayer: Int?
        let qualityState: String
        let codecBytesAvoided: Int?
    }

    private struct PartialDecodeReport: Encodable {
        let resolutionLevel: Int
        let region: String?
        let maxLayer: Int?
        let frames: [PartialFrameReport]
    }
}

private struct CodecCompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare candidate and oracle decoded pixels for one compressed frame"
    )

    @Argument(help: "Path to a DICOM Part 10 file.", completion: .file(extensions: ["dcm", "dicom"]))
    var file: String

    @Option(name: .long, help: "Zero-based frame index.")
    var frame: Int = 0

    @Option(name: [.short, .long], help: "Output format: text or json.")
    var format: OutputFormat = .text

    mutating func run() async throws {
        do {
            let report = try await DicomCodecWorkflowEngine().compare(
                try CodecCommandSupport.read(file),
                frameIndex: frame
            )
            try CodecCommandSupport.emit(report, format: format)
            if !report.success {
                throw ExitCode(65)
            }
        } catch {
            throw CodecCommandSupport.exit(for: error)
        }
    }
}

private struct CodecTranscodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcode",
        abstract: "Transcode a complete DICOM object and validate the output artifact"
    )

    @Argument(help: "Path to a DICOM Part 10 file.", completion: .file(extensions: ["dcm", "dicom"]))
    var file: String

    @Option(name: [.short, .long], help: "Output DICOM Part 10 path.")
    var output: String

    @Option(name: .long, help: "Destination transfer syntax UID.")
    var transferSyntax: String

    @Option(name: .long, help: "Lossy quality (0...1); selects irreversible encoding.")
    var quality: Double?

    @Option(name: .long, help: "JPEG 2000 cumulative resolution-detail layers (1...decomposition levels + 1).")
    var j2kLayers: Int?

    @Option(name: .long, help: "JPEG 2000 wavelet decomposition levels; explicit values are validated, never clamped.")
    var j2kDecompositions: Int?

    @Option(name: .long, help: "JPEG 2000 packet order: lrcp, rlcp or rpcl; .202 requires single-layer rpcl.")
    var j2kProgression: String?

    @Option(name: .long, help: "JPEG-LS NEAR value; selects near-lossless encoding.")
    var near: Int?

    @Option(name: .long, help: "JPEG lossless predictor 1...7 (1.2.840.10008.1.2.4.57; .70 accepts 1 only).")
    var predictor: Int?

    @Option(name: .long, help: "JPEG lossless point transform (bits dropped before prediction; non-zero is lossy).")
    var pointTransform: Int?

    @Option(name: .long, help: "JPEG lossless restart interval in MCU rows (0 = none).")
    var restartRows: Int?

    @Option(name: .long, help: "JPEG-LS scan interleave for colour frames: none, line or sample.")
    var interleave: String?

    @Option(name: .long, help: "JPEG-LS restart interval in lines (0 = none; lossless non-interleaved scans only).")
    var restartLines: Int?

    @Option(name: .long, help: "JPEG XL Butteraugli distance (0 = reversible Modular; 0 < d <= 25 selects the irreversible VarDCT route of 1.2.840.10008.1.2.4.112).")
    var distance: Double?

    @Option(name: .long, help: "JPEG XL encoder effort 1...9.")
    var effort: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "JPEG XL VarDCT Gaborish pre-filter (default on).")
    var gaborish = true

    @Flag(name: .long, inversion: .prefixedNo, help: "JPEG XL VarDCT adaptive quantisation (default on).")
    var adaptiveQuantization = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Compare decoded source/output pixels.")
    var verifyDecodedPixels = true

    @Option(name: [.short, .long], help: "Report format: text or json.")
    var format: OutputFormat = .text

    @Flag(name: .long, help: "Print the executable plan (steps, frame format, predicted cost) and write nothing.")
    var plan = false

    @Flag(name: .long, help: "Print per-frame progress to standard error while streaming the output.")
    var progress = false

    mutating func run() async throws {
        do {
            guard let destination = DicomTransferSyntax(uid: transferSyntax) else {
                throw ValidationError("Unknown transfer syntax UID: \(transferSyntax)")
            }
            let losslessOptions = predictor != nil || pointTransform != nil || restartRows != nil
            let jpegLSOptions = interleave != nil || restartLines != nil
            let jpegXLOptions = distance != nil || effort != nil || !gaborish || !adaptiveQuantization
            guard [quality != nil, near != nil || jpegLSOptions, losslessOptions, jpegXLOptions].filter({ $0 }).count <= 1 else {
                throw ValidationError("Use only one of --quality, the JPEG-LS options (--near/--interleave/--restart-lines), the JPEG lossless options (--predictor/--point-transform/--restart-rows), or the JPEG XL options (--distance/--effort/--no-gaborish/--no-adaptive-quantization).")
            }
            let intent: DicomEncodingIntent
            if let quality {
                intent = .irreversible(quality: quality)
            } else if jpegXLOptions {
                intent = .jpegXL(options: DicomJPEGXLEncodingOptions(
                    distance: distance ?? 0, effort: effort ?? 7,
                    gaborish: gaborish, adaptiveQuantization: adaptiveQuantization))
            } else if jpegLSOptions {
                var interleaveMode: DicomJPEGLSInterleave?
                if let interleave {
                    guard let parsed = DicomJPEGLSInterleave(rawValue: interleave.lowercased()) else {
                        throw ValidationError("--interleave must be none, line or sample.")
                    }
                    interleaveMode = parsed
                }
                intent = .jpegLS(options: DicomJPEGLSEncodingOptions(near: near ?? 0, interleave: interleaveMode, restartIntervalLines: restartLines ?? 0))
            } else if let near {
                intent = .jpegLSNearLossless(near: near)
            } else if losslessOptions {
                intent = .jpegLossless(options: DicomJPEGLosslessEncodingOptions(
                    predictor: predictor ?? 1, pointTransform: pointTransform ?? 0, restartIntervalRows: restartRows ?? 0))
            } else {
                intent = .reversible
            }
            var jpeg2000Options: DicomJPEG2000EncodingOptions?
            if j2kLayers != nil || j2kDecompositions != nil || j2kProgression != nil {
                var order: DicomJPEG2000Progression?
                if let j2kProgression {
                    guard let parsed = DicomJPEG2000Progression(rawValue: j2kProgression.lowercased()) else {
                        throw ValidationError("Unknown JPEG 2000 progression: \(j2kProgression)")
                    }
                    order = parsed
                }
                jpeg2000Options = DicomJPEG2000EncodingOptions(qualityLayers: j2kLayers ?? 1,
                    decompositionLevels: j2kDecompositions, progression: order)
            }
            let data = try CodecCommandSupport.read(file)
            if plan {
                let executionPlan = try DicomCodecWorkflowEngine().plan(data, to: destination, intent: intent,
                                                                      jpeg2000Options: jpeg2000Options)
                try CodecCommandSupport.emitPlan(executionPlan, format: format)
                return
            }
            var progressHandler: (@Sendable (DicomTranscodeProgress) -> Void)?
            if progress {
                progressHandler = { update in
                    let line = "frame \(update.framesCompleted)/\(update.frameCount), \(update.bytesWritten) bytes written\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
            let result = try await DicomCodecWorkflowEngine().transcode(
                data,
                to: destination,
                intent: intent,
                jpeg2000Options: jpeg2000Options,
                verifyDecodedPixels: verifyDecodedPixels,
                destinationURL: URL(fileURLWithPath: output),
                progress: progressHandler
            )
            try CodecCommandSupport.emit(result.report, format: format)
        } catch {
            throw CodecCommandSupport.exit(for: error)
        }
    }
}

enum CodecCommandSupport {
    static func read(_ path: String) throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        } catch {
            throw CodecCommandIOError.read(path: path, reason: error.localizedDescription)
        }
    }

    static func write(_ data: Data, to path: String) throws {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw CodecCommandIOError.write(path: path, reason: error.localizedDescription)
        }
    }

    static func frameIndexes(_ value: String?) throws -> [Int]? {
        guard let value else { return nil }
        let indexes = try value.split(separator: ",").map { component -> Int in
            guard let index = Int(component.trimmingCharacters(in: .whitespaces)), index >= 0 else {
                throw ValidationError("Invalid zero-based frame index: \(component)")
            }
            return index
        }
        guard !indexes.isEmpty else {
            throw ValidationError("--frames must contain at least one index.")
        }
        return indexes
    }

    static func emitPlan(_ plan: DicomTranscodeExecutionPlan, format: OutputFormat) throws {
        let steps = plan.steps.map { step -> String in
            switch step {
            case .carryDataset: return "carry-dataset"
            case .copyEncapsulatedRegion(let frames): return "copy-encapsulated-region(\(frames))"
            case .unwrapContainers(let frames): return "unwrap-containers(\(frames))"
            case .decodeFrames(let frames, let codec): return "decode-frames(\(frames), \(codec))"
            case .encodeFrames(let frames, let codec): return "encode-frames(\(frames), \(codec))"
            case .writeNativePixels(let frames): return "write-native-pixels(\(frames))"
            case .encapsulate(let tables): return "encapsulate(\(tables.rawValue)-offset-table)"
            case .deflateDataset: return "deflate-dataset"
            case .assignNewSOPInstanceUID: return "assign-new-sop-instance-uid"
            case .recordLossHistory(let method): return "record-loss-history(\(method))"
            }
        }
        var object: [String: Any] = [
            "source": plan.source.rawValue, "destination": plan.destination.rawValue, "kind": plan.kind.rawValue, "steps": steps,
            "streamable": plan.isStreamable, "assignsNewSOPInstanceUID": plan.assignsNewSOPInstanceUID, "diagnostics": plan.diagnostics,
            "cost": ["inputBytes": plan.cost.inputBytes, "frameCount": plan.cost.frameCount, "decodedFrameBytes": plan.cost.decodedFrameBytes,
                     "workingSetBytes": plan.cost.workingSetBytes, "sourceFrameByteCounts": plan.cost.sourceFrameByteCounts]
        ]
        if let format = plan.frameFormat {
            object["frameFormat"] = ["transferSyntaxUID": format.transferSyntaxUID, "rows": format.rows, "columns": format.columns,
                                     "bitsAllocated": format.bitsAllocated, "bitsStored": format.bitsStored, "samplesPerPixel": format.samplesPerPixel,
                                     "photometricInterpretation": format.photometricInterpretation, "encapsulated": format.isEncapsulated]
        }
        if let options = plan.jpeg2000Options {
            object["jpeg2000"] = ["qualityLayers": options.qualityLayers,
                                  "decompositionLevels": options.decompositionLevels ?? 0,
                                  "progression": options.progression?.rawValue ?? "lrcp"]
        }
        switch format {
        case .json:
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]))
        case .text:
            var lines = ["plan: \(plan.kind.rawValue) \(plan.source.rawValue) -> \(plan.destination.rawValue)"]
            if let options = plan.jpeg2000Options {
                lines.append("  JPEG 2000: \(options.qualityLayers) resolution-detail layers, \(options.decompositionLevels ?? 0) decompositions, \(options.progression?.rawValue ?? "lrcp")")
            }
            lines += steps.map { "  step: \($0)" }
            lines.append("  frames: \(plan.cost.frameCount), decoded frame bytes: \(plan.cost.decodedFrameBytes), working set: \(plan.cost.workingSetBytes), streamable: \(plan.isStreamable)")
            if plan.assignsNewSOPInstanceUID { lines.append("  identity: new SOP Instance UID (lossy derivation)") }
            lines += plan.diagnostics.map { "  note: \($0)" }
            FileHandle.standardOutput.write(Data(lines.joined(separator: "\n").utf8))
        }
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func emit(_ report: DicomCodecStructuredReport, format: OutputFormat) throws {
        let data: Data
        switch format {
        case .json:
            data = try DicomCodecCanonicalRenderer.jsonData(report)
        case .text:
            data = Data(DicomCodecCanonicalRenderer.text(report).utf8)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func exit(for error: Error) -> Error {
        if let exitCode = error as? ExitCode {
            return exitCode
        }
        let code: Int32
        switch error {
        case let workflow as DicomCodecWorkflowError:
            switch workflow.category {
            case .invalidInput, .corruptFrame, .validation: code = 65
            case .unsupported: code = 64
            case .backendUnavailable: code = 69
            }
        case is CodecCommandIOError:
            code = 74
        case is ValidationError, is DicomJPEG2000EncodingError:
            code = 64
        default:
            code = 70
        }
        FileHandle.standardError.write(Data("codec: \(error.localizedDescription)\n".utf8))
        return ExitCode(code)
    }
}

private enum CodecCommandIOError: Error, LocalizedError {
    case read(path: String, reason: String)
    case write(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .read(let path, let reason): return "Cannot read \(path): \(reason)"
        case .write(let path, let reason): return "Cannot write \(path): \(reason)"
        }
    }
}
