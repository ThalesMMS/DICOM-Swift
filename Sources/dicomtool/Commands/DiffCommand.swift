//
//  DiffCommand.swift
//
//  Recursive comparison of two data sets (Part 10, JSON or XML).
//

import ArgumentParser
import DicomCore
import Foundation

/// `dicomtool diff <a> <b>`: every element at every nesting level, matched by tag and item position.
/// Exit 1 when the data sets differ (like `diff`), 0 when they agree.
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare two DICOM data sets element by element, sequences included",
        discussion: """
            Inputs may be Part 10, DICOM JSON or Native DICOM XML (detected from the bytes). The file meta
            group is ignored unless --include-file-meta is given; --ignore-uids compares derived instances
            without their identities. Exit status 1 means the data sets differ.
            """
    )

    enum Format: String, ExpressibleByArgument { case text, json }

    @Argument(help: "First data set", completion: .file()) var first: String
    @Argument(help: "Second data set", completion: .file()) var second: String
    @Flag(name: .long, help: "Ignore every UI element") var ignoreUids = false
    @Flag(name: .long, help: "Ignore private elements") var ignorePrivate = false
    @Flag(name: .long, help: "Compare the file meta group (0002,xxxx) too") var includeFileMeta = false
    @Flag(name: .long, help: "Compare text verbatim (padding and empty forms are significant)") var exact = false
    @Option(name: .long, help: "Tag to ignore, repeatable (ggggeeee)") var ignore: [String] = []
    @Option(name: .long, help: "Output format: text or json") var format: Format = .text

    mutating func run() throws {
        let ignored = try Set(ignore.map { text -> Int in
            guard let tag = try? DicomTagPath(parsing: text).components.first?.tag else {
                throw CLIError.invalidArgument(argument: "--ignore", value: text, reason: "expected ggggeeee or (gggg,eeee)")
            }
            return tag
        })
        let options = DicomDataSetDiff.Options(ignoredTags: ignored, ignoresUIDs: ignoreUids, ignoresPrivate: ignorePrivate,
                                               ignoresFileMeta: !includeFileMeta, normalizesText: !exact)
        let diff = DicomDataSetDiff.compare(try Self.load(first), try Self.load(second), options: options)
        switch format {
        case .text:
            for change in diff.changes { print(change.description) }
        case .json:
            let objects = diff.changes.map { change -> [String: Any] in
                var object: [String: Any] = ["path": change.path.description, "kind": change.kind.rawValue]
                if let before = change.before { object["before"] = ["vr": before.vr.code, "value": DicomDataSetDiff.Change.summary(before)] }
                if let after = change.after { object["after"] = ["vr": after.vr.code, "value": DicomDataSetDiff.Change.summary(after)] }
                return object
            }
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["changes": objects], options: [.prettyPrinted, .sortedKeys]))
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        if !diff.isEmpty { throw ExitCode(1) }
    }

    static func load(_ path: String) throws -> DicomDataSet {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.fileNotReadable(path: path, reason: "File does not exist") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try ConvertCommand.decode(data, limits: .init()).dataSet
    }
}
