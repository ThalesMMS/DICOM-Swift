//
//  DcmdirCommand.swift
//
//  DICOMDIR / file-set operations: build, add, validate, list.
//

import ArgumentParser
import DicomCore
import Foundation

/// `dicomtool dcmdir build|add|validate|list`.
struct DcmdirCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dcmdir",
        abstract: "Build, update, validate and list DICOMDIR file-sets",
        subcommands: [Build.self, Add.self, Validate.self, List.self]
    )

    struct Build: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "build", abstract: "Create a file-set directory with a DICOMDIR from Part 10 files")

        @Argument(help: "Part 10 files (directories are scanned recursively)", completion: .file()) var files: [String]
        @Option(name: [.short, .long], help: "Destination directory (must not exist)") var output: String
        @Option(name: .long, help: "File-set ID (1–16 uppercase letters, digits, underscores)") var id: String = "DICOM"

        mutating func run() async throws {
            let sources = try DcmdirCommand.expand(files)
            let result = try await DicomFileSet.build(files: sources, destination: URL(fileURLWithPath: output, isDirectory: true), fileSetID: id)
            print("\(result.instanceCount) instance(s) in \(result.rootURL.path): " + result.recordTypes.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Add Part 10 files to an existing file-set, swapping the DICOMDIR atomically")

        @Argument(help: "File-set root directory (contains DICOMDIR)", completion: .directory) var fileSet: String
        @Argument(help: "Part 10 files to add", completion: .file()) var files: [String]

        mutating func run() async throws {
            let sources = try DcmdirCommand.expand(files)
            let result = try await DicomFileSet.add(files: sources, toFileSetAt: URL(fileURLWithPath: fileSet, isDirectory: true))
            print("\(result.instanceCount) instance(s) now referenced by \(result.directoryFileURL.path)")
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "validate", abstract: "Check a DICOMDIR's structure and every reference against the files in the root")

        @Argument(help: "DICOMDIR file or file-set root", completion: .file()) var path: String

        mutating func run() throws {
            let report = try DicomFileSet.validate(directoryFileURL: DcmdirCommand.directoryFile(path))
            for issue in report.issues {
                print("\(issue.code.rawValue)\(issue.fileID.isEmpty ? "" : " " + issue.fileID.joined(separator: "/")): \(issue.detail)")
            }
            print("\(report.referencedInstanceCount) referenced instance(s), \(report.issues.count) issue(s), \(report.isConsistent ? "consistent" : "INCONSISTENT")")
            if !report.isConsistent { throw ExitCode(1) }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Print the record hierarchy of a DICOMDIR with structural diagnostics")

        @Argument(help: "DICOMDIR file or file-set root", completion: .file()) var path: String

        mutating func run() throws {
            let read = try DicomDirectoryReader.readWithDiagnostics(from: DcmdirCommand.directoryFile(path))
            print("File-set ID: \(read.directory.fileSetID ?? "")")
            for patient in read.directory.patients {
                print("PATIENT \(patient.patientID ?? "") \(patient.patientName ?? "")")
                for study in patient.studies {
                    print("  STUDY \(study.studyInstanceUID ?? "") \(study.studyDescription ?? "")")
                    for series in study.series {
                        print("    SERIES \(series.seriesInstanceUID ?? "") \(series.modality ?? "")")
                        for leaf in series.images {
                            print("      \(leaf.recordType) \(leaf.referencedFileID.joined(separator: "/")) \(leaf.referencedSOPInstanceUID ?? "")")
                        }
                    }
                }
            }
            for diagnostic in read.diagnostics { print("diagnostic: \(diagnostic.code.rawValue) at \(diagnostic.offset): \(diagnostic.detail)") }
            if !read.isStructurallyConsistent { throw ExitCode(1) }
        }
    }

    static func directoryFile(_ path: String) throws -> URL {
        var url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw CLIError.fileNotReadable(path: path, reason: "File does not exist") }
        if isDirectory.boolValue { url.appendPathComponent("DICOMDIR") }
        return url
    }

    static func expand(_ paths: [String]) throws -> [URL] {
        var urls: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw CLIError.fileNotReadable(path: path, reason: "File does not exist") }
            if isDirectory.boolValue {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
                    throw CLIError.invalidArgument(argument: "input", value: path, reason: "directory cannot be enumerated")
                }
                for case let child as URL in enumerator
                    where (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    urls.append(child)
                }
            } else {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path < $1.path }
    }
}
