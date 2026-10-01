//
//  SplitMergeCommands.swift
//
//  `dicomtool split` and `dicomtool merge`: frame/instance restructuring with atomic publication.
//

import ArgumentParser
import DicomCore
import Foundation

/// `dicomtool split <multiframe> --output DIR`: one Part 10 file per frame, published atomically as a directory.
struct SplitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Split a multi-frame instance into single-frame instances",
        discussion: """
            Enhanced and Legacy Converted CT/MR are converted through the qualified single-stack profile;
            multi-frame Secondary Capture is split frame by frame with native or encapsulated pixels kept.
            Every derived instance references its source frame in the Source Image Sequence. The output
            directory is staged next to its final name and renamed into place only after every instance was
            reopened and verified; the input is never modified.
            """
    )

    @Argument(help: "Multi-frame Part 10 input", completion: .file()) var input: String
    @Option(name: [.short, .long], help: "Output directory (must not exist)") var output: String

    mutating func run() throws {
        let inputURL = URL(fileURLWithPath: input), outputURL = URL(fileURLWithPath: output, isDirectory: true)
        guard FileManager.default.fileExists(atPath: inputURL.path) else { throw CLIError.fileNotReadable(path: input, reason: "File does not exist") }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw CLIError.outputFileExists(path: output) }
        let result: DicomInstanceSplitter.Result
        do { result = try DicomInstanceSplitter().split(contentsOf: inputURL) } catch let error as DicomInstanceSplitter.SplitError {
            throw CLIError.validationFailed(file: input, errors: [error.description])
        }
        let parent = outputURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(outputURL.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for instance in result.instances {
                try instance.part10Data.write(to: staging.appendingPathComponent(String(format: "%06d.dcm", instance.instanceNumber)), options: [.atomic])
            }
            try FileManager.default.moveItem(at: staging, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw CLIError.fileNotWritable(path: output, reason: error.localizedDescription)
        }
        print("\(result.instances.count) instance(s) of \(result.sopClassUID) in series \(result.seriesInstanceUID) written to \(output)")
    }
}

/// `dicomtool merge <files...> --output FILE`: classic CT/MR instances into one Legacy Converted Enhanced instance.
struct MergeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge classic CT/MR instances into a Legacy Converted Enhanced multi-frame instance",
        discussion: """
            Inputs must share the study, series, frame of reference, pixel structure, orientation and spacing,
            carry native pixels and occupy distinct positions of one stack; anything else is refused with the
            reason. Frames are ordered along the stack normal; attributes that differ per source go to the
            Unassigned Per-Frame Converted Attributes functional group and every frame names its source in the
            Conversion Source functional group. The merged file is reopened and compared frame by frame before
            it is published atomically; inputs are never modified.
            """
    )

    @Argument(help: "Part 10 inputs (directories are scanned recursively)", completion: .file()) var inputs: [String]
    @Option(name: [.short, .long], help: "Output file") var output: String
    @Flag(name: .long, help: "Overwrite an existing output file") var force = false

    mutating func run() throws {
        let urls = try DcmdirCommand.expand(inputs)
        let outputURL = URL(fileURLWithPath: output)
        if FileManager.default.fileExists(atPath: outputURL.path), !force { throw CLIError.outputFileExists(path: output) }
        guard !urls.contains(where: { $0.standardizedFileURL.path == outputURL.standardizedFileURL.path }) else {
            throw CLIError.invalidPath(path: output, reason: "the output must not be one of the inputs")
        }
        let result: DicomInstanceMerger.Result
        do { result = try DicomInstanceMerger().merge(contentsOf: urls) } catch let error as DicomInstanceMerger.MergeError {
            throw CLIError.validationFailed(file: output, errors: [error.description])
        }
        let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".\(outputURL.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try result.part10Data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CLIError.fileNotWritable(path: output, reason: error.localizedDescription)
        }
        print("\(result.frameCount) frame(s) merged into \(result.sopClassUID) \(result.sopInstanceUID) at \(output)")
        if !result.perFrameTags.isEmpty {
            FileHandle.standardError.write(Data("per-frame attributes: \(result.perFrameTags.map { String(format: "%08X", $0) }.joined(separator: " "))\n".utf8))
        }
    }
}
