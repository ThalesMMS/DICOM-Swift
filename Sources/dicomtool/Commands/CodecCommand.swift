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

    func run() throws {
        try CodecCommandSupport.emit(
            DicomCodecWorkflowEngine().capabilities(),
            format: format
        )
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

    mutating func run() async throws {
        do {
            let result = try await DicomCodecWorkflowEngine().decode(
                try CodecCommandSupport.read(file),
                frameIndexes: try CodecCommandSupport.frameIndexes(frames)
            )
            try CodecCommandSupport.write(result.data, to: output)
            try CodecCommandSupport.emit(result.report, format: format)
        } catch {
            throw CodecCommandSupport.exit(for: error)
        }
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

    @Option(name: .long, help: "JPEG-LS NEAR value; selects near-lossless encoding.")
    var near: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Compare decoded source/output pixels.")
    var verifyDecodedPixels = true

    @Option(name: [.short, .long], help: "Report format: text or json.")
    var format: OutputFormat = .text

    mutating func run() async throws {
        do {
            guard let destination = DicomTransferSyntax(uid: transferSyntax) else {
                throw ValidationError("Unknown transfer syntax UID: \(transferSyntax)")
            }
            guard quality == nil || near == nil else {
                throw ValidationError("Use either --quality or --near, not both.")
            }
            let intent: DicomEncodingIntent
            if let quality {
                intent = .irreversible(quality: quality)
            } else if let near {
                intent = .jpegLSNearLossless(near: near)
            } else {
                intent = .reversible
            }
            let result = try await DicomCodecWorkflowEngine().transcode(
                try CodecCommandSupport.read(file),
                to: destination,
                intent: intent,
                verifyDecodedPixels: verifyDecodedPixels
            )
            try CodecCommandSupport.write(result.data, to: output)
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
        case is ValidationError:
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
