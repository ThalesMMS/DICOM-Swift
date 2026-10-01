//
//  DeidentifyCommand.swift
//
//  PS3.15 Annex E de-identification of Part 10 files with a cohort session, dry-run report and options.
//

import ArgumentParser
import DicomCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `dicomtool deidentify <inputs...> --output DIR [--option NAME ...] [--dry-run] [--report FILE] [--reversal-key FILE]`.
/// Inputs are never modified; every output is staged and published atomically under the output directory
/// with paths relative to the common input directory. One session covers the invocation, so references between inputs keep
/// pointing at each other after their UIDs change. The report lists actions by path and tag, never values.
struct DeidentifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deidentify",
        abstract: "De-identify Part 10 files per PS3.15 Annex E (Basic Profile plus options)",
        discussion: """
            Options (repeatable --option): \(DicomDeidentificationTable.Option.allCases.map(\.rawValue).joined(separator: ", ")).
            Burned-in pixels are not cleaned: an instance whose Burned In Annotation is YES is rejected unless
            --burned-in flag|accept; an unknown annotation is flagged unless --unknown-burned-in reject|accept.
            Exit status 1 when any input was rejected; the report's classification tells deidentifiedPerProfile,
            incomplete and rejected apart. A reversal key (UID map and date shift) is written only when
            --reversal-key names a file; keep it apart from the outputs.
            """
    )

    @Argument(help: "Part 10 inputs (directories are scanned recursively)", completion: .file()) var inputs: [String]
    @Option(name: [.short, .long], help: "Output directory (created; existing files are not overwritten)") var output: String?
    @Option(name: .long, parsing: .singleValue, help: "PS3.15 option to enable, repeatable") var option: [String] = []
    @Option(name: .long, help: "Policy for Burned In Annotation = YES: reject, flag or accept") var burnedIn: String = "reject"
    @Option(name: .long, help: "Policy for absent/unknown Burned In Annotation: reject, flag or accept") var unknownBurnedIn: String = "flag"
    @Option(name: .long, help: "UID root for generated UIDs (default 2.25)") var uidRoot: String = "2.25"
    @Option(name: .long, help: "Date shift in days for the modified-dates option (random when omitted)") var dateShift: Int?
    @Flag(name: .long, help: "Report only; write nothing and keep the session empty") var dryRun = false
    @Option(name: .long, help: "JSON report file (paths and tags only)") var report: String?
    @Option(name: .long, help: "Write the reversal key (UID map, date shift) to this file") var reversalKey: String?
    @Option(name: .long, help: "Resume a session from a reversal key file") var resumeKey: String?

    mutating func run() throws {
        let urls = try DcmdirCommand.expand(inputs)
        guard !urls.isEmpty else { throw CLIError.missingRequiredArgument(argument: "inputs") }
        guard dryRun || output != nil else { throw CLIError.missingRequiredArgument(argument: "--output") }
        if let reversalKey, !dryRun {
            let destination = URL(fileURLWithPath: reversalKey).resolvingSymlinksInPath().standardizedFileURL
            guard !urls.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == destination }) else {
                throw CLIError.invalidPath(path: reversalKey, reason: "reversal key must not replace an input file")
            }
        }
        let options = try Set(option.map { name -> DicomDeidentificationTable.Option in
            guard let value = DicomDeidentificationTable.Option(rawValue: name) else {
                throw CLIError.invalidArgument(argument: "--option", value: name, reason: "unknown option")
            }
            return value
        })
        func policy(_ text: String, argument: String) throws -> DicomDeidentificationProfile.BurnedInPolicy {
            guard let value = DicomDeidentificationProfile.BurnedInPolicy(rawValue: text) else {
                throw CLIError.invalidArgument(argument: argument, value: text, reason: "expected reject, flag or accept")
            }
            return value
        }
        let profile = DicomDeidentificationProfile(options: options, burnedInAnnotationPolicy: try policy(burnedIn, argument: "--burned-in"),
                                                   unknownBurnedInPolicy: try policy(unknownBurnedIn, argument: "--unknown-burned-in"), methodDescription: "dicomtool deidentify")
        let session: DicomDeidentificationSession
        if let resumeKey {
            let key = try JSONDecoder().decode(DicomDeidentificationSession.ReversalKey.self, from: try Data(contentsOf: URL(fileURLWithPath: resumeKey)))
            session = DicomDeidentificationSession(reversalKey: key)
        } else {
            session = DicomDeidentificationSession(uidRoot: uidRoot, dateShiftDays: dateShift)
        }
        let deidentifier: DicomDeidentifier
        do { deidentifier = try DicomDeidentifier(profile: profile, session: session) } catch let error as DicomDeidentificationError {
            throw CLIError.invalidArgument(argument: "--option", value: option.joined(separator: ","), reason: error.description)
        }
        let outputURL = output.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outputURL, !dryRun {
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            for url in urls where url.standardizedFileURL.path.hasPrefix(outputURL.standardizedFileURL.path + "/") {
                throw CLIError.invalidPath(path: url.path, reason: "inputs must not live inside the output directory")
            }
        }
        func publishReversalKey() throws {
            guard let reversalKey, !dryRun else { return }
            let destination = URL(fileURLWithPath: reversalKey)
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".deidentify-key-\(UUID().uuidString)")
            let files = FileManager.default
            try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: staging) }
            let stagedKey = staging.appendingPathComponent("key.json")
            try JSONEncoder().encode(session.reversalKey()).write(to: stagedKey)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedKey.path)
            guard rename(stagedKey.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let inputDirectories = inputs.map { path -> URL in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }
        var commonDirectory = inputDirectories[0]
        for directory in inputDirectories.dropFirst() {
            while commonDirectory.path != "/", directory.path != commonDirectory.path,
                  !directory.path.hasPrefix(commonDirectory.path + "/") {
                commonDirectory.deleteLastPathComponent()
            }
        }
        let prefixLength = commonDirectory.path == "/" ? 1 : commonDirectory.path.count + 1
        var entries: [[String: Any]] = []
        var rejected = 0
        for url in urls {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let relativePath = String(url.standardizedFileURL.path.dropFirst(prefixLength))
            var entry: [String: Any] = ["input": relativePath]
            do {
                let report: DicomDeidentificationReport
                if dryRun {
                    report = try deidentifier.plan(data)
                } else {
                    let (fileData, applied) = try deidentifier.apply(data)
                    report = applied
                    let destination = outputURL!.appendingPathComponent(relativePath)
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw CLIError.outputFileExists(path: destination.path) }
                    let parent = destination.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).partial-\(UUID().uuidString)")
                    do {
                        try fileData.write(to: temporary, options: [.atomic])
                        try publishReversalKey()
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    } catch {
                        try? FileManager.default.removeItem(at: temporary)
                        throw CLIError.fileNotWritable(path: destination.path, reason: error.localizedDescription)
                    }
                    entry["output"] = relativePath
                }
                if report.classification == .rejected { rejected += 1 }
                entry["classification"] = report.classification.rawValue
                if let rejection = report.rejection { entry["rejection"] = rejection.rawValue }
                entry["sopClassUID"] = report.sopClassUID
                entry["counts"] = Dictionary(uniqueKeysWithValues: report.counts.map { ($0.key.rawValue, $0.value) })
                entry["findings"] = report.findings.map { ["kind": $0.kind.rawValue, "path": $0.path, "detail": $0.detail] }
                entry["uidReplacements"] = report.uidReplacements.count
                print("\(relativePath): \(report.classification.rawValue)" + (report.findings.isEmpty ? "" : " (\(report.findings.count) finding(s))"))
            } catch let error as DicomDeidentificationError {
                if case .rejected(let rejection) = error {
                    rejected += 1
                    entry["classification"] = DicomDeidentificationReport.Classification.rejected.rawValue
                    entry["rejection"] = rejection.rawValue
                    print("\(relativePath): rejected (\(rejection.rawValue))")
                } else {
                    throw CLIError.validationFailed(file: url.path, errors: [error.description])
                }
            }
            entries.append(entry)
        }
        if let report {
            let document: [String: Any] = ["profile": ["basic": true, "options": options.map(\.rawValue).sorted(), "table": DicomDeidentificationTable.standard.version],
                                           "dryRun": dryRun, "instances": entries]
            try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: report), options: [.atomic])
        }
        try publishReversalKey()
        if rejected > 0 { throw ExitCode(1) }
    }
}
