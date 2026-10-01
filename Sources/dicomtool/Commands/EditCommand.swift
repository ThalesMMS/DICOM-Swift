//
//  EditCommand.swift
//
//  Path-addressed edits and identity changes applied through the validated Part 10 rewriter.
//

import ArgumentParser
import DicomCore
import Foundation

/// `dicomtool edit <input> --output <file> [--set PATH[:VR]=VALUE] [--remove PATH] [--replace-uid OLD=NEW] [--new-uid SCOPE]`.
/// The input is never modified; the output is written to a temporary file and published atomically after the
/// rewritten bytes were reopened and checked (transfer syntax, pixel bytes, every UID, every edit).
struct EditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Set or remove attributes by path and replace UIDs with their references",
        discussion: """
            PATH addresses nested elements: (0008,1115)[0]/(0008,1155). Values use \\ between multiple values;
            the VR comes from the existing element or the dictionary unless PATH:VR=VALUE names it. Identity
            UIDs (SOP Instance, Series, Study, Frame of Reference) are changed with --replace-uid or
            --new-uid so every reference in the file follows; --set refuses them. File meta and the pixel
            structure cannot be edited. Replacements performed are printed as OLD -> NEW for reuse on
            related files (--replace-uid).
            """
    )

    @Argument(help: "Part 10 input", completion: .file()) var input: String
    @Option(name: [.short, .long], help: "Output file (must differ from the input)") var output: String
    @Option(name: .long, parsing: .singleValue, help: "PATH[:VR]=VALUE, repeatable") var set: [String] = []
    @Option(name: .long, parsing: .singleValue, help: "PATH to remove (an item path removes the item), repeatable") var remove: [String] = []
    @Option(name: .long, parsing: .singleValue, help: "OLD=NEW UID replacement applied everywhere, repeatable") var replaceUid: [String] = []
    @Option(name: .long, parsing: .singleValue, help: "Regenerate an identity UID: instance, series, study or frameOfReference") var newUid: [String] = []
    @Flag(name: .long, help: "Create missing sequence items when a --set path points at the next index") var createItems = false
    @Flag(name: .long, help: "Overwrite an existing output file") var force = false

    mutating func run() throws {
        let inputURL = URL(fileURLWithPath: input), outputURL = URL(fileURLWithPath: output)
        guard FileManager.default.fileExists(atPath: inputURL.path) else { throw CLIError.fileNotReadable(path: input, reason: "File does not exist") }
        guard inputURL.standardizedFileURL.path != outputURL.standardizedFileURL.path else {
            throw CLIError.invalidPath(path: output, reason: "the output must differ from the input; edits are never applied in place")
        }
        if FileManager.default.fileExists(atPath: outputURL.path), !force { throw CLIError.outputFileExists(path: output) }
        let data = try Data(contentsOf: inputURL, options: .mappedIfSafe)
        guard DicomPart10FileMetaParser.hasPart10Prefix(data) else { throw CLIError.invalidDICOMFile(path: input, reason: "not a Part 10 file") }
        let source = try DicomPart10PixelDataPreserver.dataSet(from: try DCMDecoder(data: data))
        let plan = try Self.plan(set: set, remove: remove, replaceUid: replaceUid, newUid: newUid, createItems: createItems, source: source)
        let (result, edit): (DicomPart10RewriteResult, DicomDataSetEditResult)
        do {
            (result, edit) = try DicomDataSetEditor.apply(plan, toPart10: data)
        } catch let error as DicomDataSetEditError {
            throw CLIError.validationFailed(file: input, errors: [error.description])
        } catch let error as DicomPart10RewriteError {
            throw CLIError.validationFailed(file: input, errors: ["rewrite rejected: \(error)"])
        }
        let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(".\(outputURL.lastPathComponent).partial-\(UUID().uuidString)")
        try result.fileData.write(to: temporary, options: [.atomic])
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: outputURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw CLIError.fileNotWritable(path: output, reason: error.localizedDescription)
        }
        for (old, new) in edit.uidReplacements.sorted(by: { $0.key < $1.key }) { print("\(old) -> \(new)") }
        FileHandle.standardError.write(Data("\(edit.diff.changes.count) change(s) written to \(output)\n".utf8))
    }

    static func plan(set: [String], remove: [String], replaceUid: [String], newUid: [String], createItems: Bool,
                     source: DicomDataSet) throws -> DicomDataSetEdit {
        var operations: [DicomDataSetEdit.Operation] = []
        for scope in newUid {
            guard let value = DicomDataSetEdit.IdentityScope(rawValue: scope) else {
                throw CLIError.invalidArgument(argument: "--new-uid", value: scope, reason: "expected instance, series, study or frameOfReference")
            }
            operations.append(.regenerateUID(value))
        }
        for pair in replaceUid {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw CLIError.invalidArgument(argument: "--replace-uid", value: pair, reason: "expected OLD=NEW") }
            operations.append(.replaceUID(old: parts[0], new: parts[1]))
        }
        for assignment in set {
            guard let equals = assignment.firstIndex(of: "=") else {
                throw CLIError.invalidArgument(argument: "--set", value: assignment, reason: "expected PATH[:VR]=VALUE")
            }
            var pathText = String(assignment[..<equals])
            let valueText = String(assignment[assignment.index(after: equals)...])
            var vr: DicomVR?
            if let colon = pathText.lastIndex(of: ":"), pathText[colon...].count == 3 {
                guard let named = DicomVR(code: String(pathText[pathText.index(after: colon)...])) else {
                    throw CLIError.invalidArgument(argument: "--set", value: assignment, reason: "unknown VR")
                }
                vr = named
                pathText = String(pathText[..<colon])
            }
            let path: DicomTagPath
            do { path = try DicomTagPath(parsing: pathText) } catch {
                throw CLIError.invalidArgument(argument: "--set", value: assignment, reason: "bad path: \(error)")
            }
            let tag = path.last?.tag ?? 0
            let resolvedVR = try vr ?? (try? source.element(at: path))?.vr ?? DCMDictionary().vrCode(forTag: tag).flatMap(DicomVR.init(code:))
                ?? { throw CLIError.invalidArgument(argument: "--set", value: assignment, reason: "VR unknown for this tag; use PATH:VR=VALUE") }()
            operations.append(.set(path, DicomDataElement(tag: tag, vr: resolvedVR, value: try value(valueText, vr: resolvedVR, argument: assignment))))
        }
        for pathText in remove {
            do { operations.append(.remove(try DicomTagPath(parsing: pathText))) } catch {
                throw CLIError.invalidArgument(argument: "--remove", value: pathText, reason: "bad path: \(error)")
            }
        }
        return DicomDataSetEdit(operations: operations, createsItems: createItems)
    }

    /// Parses a command-line value for a VR: `\` separates values; binary VRs take hex; SQ only accepts empty.
    static func value(_ text: String, vr: DicomVR, argument: String) throws -> DicomDataValue {
        if text.isEmpty { return .empty }
        let parts = text.components(separatedBy: "\\")
        func bad(_ reason: String) -> CLIError { CLIError.invalidArgument(argument: "--set", value: argument, reason: reason) }
        switch vr {
        case .US, .UL, .UV, .AT:
            return .unsignedIntegers(try parts.map { part in
                if vr == .AT, let tag = try? DicomTagPath(parsing: part).components.first?.tag { return UInt(tag) }
                guard let value = UInt(part) else { throw bad("expected unsigned integers") }
                return value
            })
        case .SS, .SL, .SV:
            return .signedIntegers(try parts.map { guard let value = Int($0) else { throw bad("expected integers") }; return value })
        case .FL, .FD:
            return .floats(try parts.map { guard let value = Double($0) else { throw bad("expected numbers") }; return value })
        case .OB, .OW, .OD, .OF, .OL, .OV, .unknown:
            let hex = text.replacingOccurrences(of: " ", with: "")
            guard hex.count.isMultiple(of: 2), hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw bad("expected hex bytes") }
            return .bytes(Data(stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }))
        case .SQ:
            throw bad("a sequence is edited through its items; set an empty value to clear it")
        default:
            return .strings(parts)
        }
    }
}
