import ArgumentParser
import DicomCore
import Foundation

struct ArchiveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive", abstract: "Package and verify study archives",
        subcommands: [Package.self, Inspect.self, Verify.self, Extract.self, Put.self, Get.self, Recall.self, Resume.self,
                      Backup.self, VerifyBackup.self, Rehearse.self, Evidence.self, Plan.self, ExecutePlan.self])

    struct Package: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "package")
        @Argument var inputs: [String]
        @Option(name: .long) var output: String
        @Option(name: .long) var producer: String = "dicomtool"
        @Flag(name: .long) var dicomdir = false
        mutating func run() throws {
            var members: [DicomStudyPackageWriter.Member] = []
            for input in inputs {
                let root = URL(fileURLWithPath: input).standardizedFileURL
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw ValidationError("Symbolic link input") }
                if values.isDirectory == true {
                    var scanError: (any Error)?
                    guard let enumerator = FileManager.default.enumerator(at: root,
                        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
                        errorHandler: { _, error in scanError = error; return false }) else { throw ValidationError("Cannot enumerate input") }
                    for case let child as URL in enumerator {
                        let childValues = try child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard childValues.isSymbolicLink != true else { throw ValidationError("Symbolic link input") }
                        if childValues.isRegularFile == true {
                            members.append(.init(sourceURL: child, relativePath: String(child.path.dropFirst(root.path.count + 1))))
                        }
                    }
                    if scanError != nil { throw ValidationError("Cannot enumerate input") }
                } else { members.append(.init(sourceURL: root, relativePath: root.lastPathComponent)) }
            }
            let result = try DicomStudyPackageWriter().write(members: members.sorted { $0.relativePath < $1.relativePath },
                to: URL(fileURLWithPath: output), producer: producer, includeDICOMDIR: dicomdir)
            print("Packaged \(result.manifest.totals.entryCount) entries, \(result.byteCount) ZIP bytes")
        }
    }
    struct Inspect: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "inspect")
        @Argument var archive: String
        @Flag(name: .long) var json = false
        mutating func run() throws {
            let manifest = try DicomStudyPackageReader(url: URL(fileURLWithPath: archive)).manifest
            if json { print(String(decoding: try manifest.encode(), as: UTF8.self)) }
            else { print("Study package v\(manifest.formatVersion): \(manifest.studies.count) studies, \(manifest.totals.entryCount) entries, \(manifest.totals.byteCount) bytes") }
        }
    }
    struct Verify: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify")
        @Argument var archive: String
        mutating func run() throws {
            do {
                let report = try DicomStudyPackageReader(url: URL(fileURLWithPath: archive)).verify()
                print("Verified \(report.verifiedEntries) entries; \(report.failures.count) failures")
                for (index, failure) in report.failures.enumerated() {
                    // Paths and UIDs can contain PHI. Report an ordinal and failure category only.
                    let category: String
                    switch failure.reason {
                    case .checksumMismatch: category = "checksumMismatch"
                    case .sizeMismatch: category = "sizeMismatch"
                    default: category = "corruptArchive"
                    }
                    print("Failure \(index + 1): \(category)")
                }
                if report.status == .failed { throw ExitCode(2) }
            } catch { throw ExitCode(2) }
        }
    }
    struct Extract: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "extract")
        @Argument var archive: String
        @Option(name: .long) var member: [String] = []
        @Option(name: .long) var output: String
        mutating func run() throws {
            let result = try DicomStudyPackageReader(url: URL(fileURLWithPath: archive)).extract(
                members: member.isEmpty ? nil : member, to: URL(fileURLWithPath: output))
            print("Extracted \(result.count) entries")
        }
    }
}

extension ArchiveCommand {
    struct Backup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "backup")
        @Option(name: .long) var sourceRoot: String
        @Option(name: .long) var destinationRoot: String
        @Option(name: .long) var evidence: String
        mutating func run() async throws {
            let sourceURL = URL(fileURLWithPath: sourceRoot)
            let destinationURL = URL(fileURLWithPath: destinationRoot)
            let fs = DicomLocalIngestFileSystem()
            let source = DicomLocalDiskProvider(id: "source", root: sourceURL)
            var objects: [DicomBackupInventory.Object] = []
            // Capture the selection before any transfer; concurrent new arrivals are excluded.
            for info in try await source.list(prefix: "") {
                guard let hash = info.sha256 else { throw ValidationError("Source has no SHA-256") }
                let ref = try DicomObjectReference.read(from: sourceURL.appendingPathComponent(info.locator))
                objects.append(.init(objectKey: info.locator, sourceLocator: info.locator,
                    byteCount: info.byteCount, sha256: hash, references: ref))
            }
            let inventory = DicomBackupInventory(producer: "dicomtool", objects: objects)
            try fs.createDirectory(destinationURL)
            let destination = DicomLocalDiskProvider(id: "destination", root: destinationURL)
            let report = try await DicomBackupCopier().copy(inventory: inventory, from: source, to: destination)
            var result = DicomBackupEvidence(inventoryID: inventory.inventoryID, destinationProviderID: destination.id)
            try result.recordCopied(report: report)
            try DicomBackupEvidenceStore(directory: URL(fileURLWithPath: evidence)).save(result)
            print("\(inventory.inventoryID) \(result.status.rawValue)")
        }
    }
    struct VerifyBackup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "verify-backup")
        @Option(name: .long) var destinationRoot: String
        @Option(name: .long) var evidence: String
        @Option(name: .long) var inventoryId: String
        mutating func run() async throws {
            let store = DicomBackupEvidenceStore(directory: URL(fileURLWithPath: evidence))
            var result = try store.load(inventoryID: inventoryId)
            do {
                let inventory = try ArchiveCommand.backupInventory(destinationRoot, inventoryId)
                let report = try await DicomBackupVerifier().verify(inventory: inventory,
                    at: DicomLocalDiskProvider(id: "destination", root: URL(fileURLWithPath: destinationRoot)),
                    scratch: FileManager.default.temporaryDirectory)
                do { try result.recordVerified(report: report) }
                catch { try store.save(result); throw error }
                try store.save(result)
                print(result.status.rawValue)
            } catch { throw ExitCode(2) }
        }
    }
    struct Rehearse: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rehearse")
        @Option(name: .long) var destinationRoot: String
        @Option(name: .long) var evidence: String
        @Option(name: .long) var inventoryId: String
        @Option(name: .long) var into: String
        mutating func run() async throws {
            let inventory = try ArchiveCommand.backupInventory(destinationRoot, inventoryId)
            let report = try await DicomRestoreRehearsal().rehearse(inventory: inventory,
                from: DicomLocalDiskProvider(id: "destination", root: URL(fileURLWithPath: destinationRoot)),
                into: URL(fileURLWithPath: into))
            let store = DicomBackupEvidenceStore(directory: URL(fileURLWithPath: evidence))
            var result = try store.load(inventoryID: inventoryId)
            guard report.status == .ok else { throw ExitCode(2) }
            try result.recordRehearsed(report: report)
            try store.save(result)
            print(result.status.rawValue)
        }
    }
    struct Evidence: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "evidence")
        @Option(name: .long) var evidence: String
        @Option(name: .long) var inventoryId: String
        mutating func run() throws {
            print(try DicomBackupEvidenceStore(directory: URL(fileURLWithPath: evidence))
                .load(inventoryID: inventoryId).status.rawValue)
        }
    }
    struct Plan: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "plan")
        @Option(name: .long) var root: String
        @Option(name: .long, parsing: .upToNextOption) var key: [String]
        @Flag(name: .long) var json = false
        mutating func run() async throws {
            let provider = DicomLocalDiskProvider(id: "root", root: URL(fileURLWithPath: root))
            var candidates: [DicomDestructivePlan.Action] = []
            var placements: [String: [DicomObjectPlacement]] = [:]
            for key in key {
                guard let info = try await provider.head(key), let hash = info.sha256 else {
                    throw DicomStorageProviderError.notFound(key)
                }
                candidates.append(.init(kind: .delete, objectKey: key, providerID: provider.id,
                    locator: key, byteCount: info.byteCount, reason: "Explicit CLI selection", sha256: hash))
                placements[key] = [.init(objectKey: key, tier: .online, providerID: provider.id,
                    locator: key, byteCount: info.byteCount, sha256: hash)]
            }
            // No backup evidence was supplied: never invent verified copies from a directory listing.
            let plan = DicomDestructivePlanner().plan(candidates: candidates, placements: placements,
                verifiedCopies: [:], protections: [:], graph: .init(parents: [:]), now: Date())
            try ArchiveCommand.printPlan(plan)
        }
    }
    struct ExecutePlan: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "execute-plan")
        @Option(name: .long) var plan: String
        @Option(name: .long) var root: String
        @Option(name: .long) var authorize: String?
        mutating func run() async throws {
            let input = try JSONDecoder().decode(DicomDestructivePlan.self,
                from: Data(contentsOf: URL(fileURLWithPath: plan)))
            guard let authorize, !authorize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try ArchiveCommand.printPlan(input)
                throw ExitCode(3)
            }
            let provider = DicomLocalDiskProvider(id: "root", root: URL(fileURLWithPath: root))
            var placements: [String: [DicomObjectPlacement]] = [:]
            for action in input.actions where action.providerID == provider.id {
                if let info = try await provider.head(action.locator), let hash = info.sha256 {
                    placements[action.objectKey, default: []].append(.init(objectKey: action.objectKey,
                        tier: provider.tier, providerID: provider.id, locator: action.locator,
                        byteCount: info.byteCount, sha256: hash))
                }
            }
            // This command has no trusted backup evidence or protection catalog. It cannot authorize a last-copy delete.
            let result = try await DicomDestructiveExecutor().execute(plan: input,
                authorization: .init(token: authorize, reason: "Explicit CLI plan authorization"),
                providers: [provider.id: provider], placements: placements, verifiedCopies: [:],
                protections: [:], graph: .init(parents: [:]), dryRun: false)
            print("Executed \(result.executed.count); blocked \(result.skipped.count); failed \(result.failed.count)")
            if !result.failed.isEmpty { throw ExitCode(2) }
        }
    }
    private static func backupInventory(_ root: String, _ id: String) throws -> DicomBackupInventory {
        let value = try JSONDecoder().decode(DicomBackupInventory.self,
            from: Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(DicomBackupInventory.fileName)))
        guard value.inventoryID == id else { throw ValidationError("Inventory ID mismatch") }
        return value
    }
    private static func printPlan(_ plan: DicomDestructivePlan) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(plan), as: UTF8.self))
    }
}

extension ArchiveCommand {
    struct Put: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "put")
        @Option(name: .long) var root: String
        @Option(name: .long) var key: String
        @Argument var file: String
        mutating func run() async throws {
            let directory = URL(fileURLWithPath: root)
            try DicomLocalIngestFileSystem().createDirectory(directory)
            let source = URL(fileURLWithPath: file)
            let hash = try DicomLocalIngestFileSystem().checksum(source)
            let result = try await DicomDirectoryObjectStore(root: directory).putObject(key: key, from: source, sha256: hash)
            print("Stored \(result.byteCount) bytes; SHA-256 \(hash)")
        }
    }
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "get")
        @Option(name: .long) var root: String
        @Option(name: .long) var key: String
        @Option(name: .long) var output: String
        mutating func run() async throws {
            let provider = DicomObjectStoreProvider(id: "source",
                store: DicomDirectoryObjectStore(root: URL(fileURLWithPath: root)))
            guard let info = try await provider.head(key), let hash = info.sha256 else {
                throw DicomStorageProviderError.notFound(key)
            }
            _ = try await provider.get(key, to: URL(fileURLWithPath: output), expectedSHA256: hash)
            print("Verified SHA-256 \(hash)")
        }
    }
    struct Recall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "recall")
        @Option(name: .long) var sourceRoot: String
        @Option(name: .long) var destinationRoot: String
        @Option(name: .long) var journal: String
        @Option(name: .long, parsing: .upToNextOption) var key: [String]
        mutating func run() async throws {
            let (coordinator, source) = try ArchiveCommand.coordinator(sourceRoot, destinationRoot, journal)
            var items: [DicomTransferManifest.Item] = []
            for key in key {
                guard let info = try await source.head(key), let hash = info.sha256 else {
                    throw DicomStorageProviderError.notFound(key)
                }
                items.append(.init(objectKey: key, sourceLocator: key, destinationLocator: key,
                                   byteCount: info.byteCount, sha256: hash))
            }
            let manifest = try await coordinator.recall(items: items, from: "source", to: "destination")
            try ArchiveCommand.printManifest(manifest)
        }
    }
    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "resume")
        @Option(name: .long) var journal: String
        @Option(name: .long) var sourceRoot: String
        @Option(name: .long) var destinationRoot: String
        mutating func run() async throws {
            let (coordinator, _) = try ArchiveCommand.coordinator(sourceRoot, destinationRoot, journal)
            let results = try await coordinator.resume()
            var failed = false
            for result in results {
                print(String(decoding: try result.encode(), as: UTF8.self))
                if result.items.contains(where: { if case .failed = $0.state { return true }; return false }) { failed = true }
            }
            if failed { throw ExitCode(2) }
        }
    }
    private static func coordinator(_ sourceRoot: String, _ destinationRoot: String, _ journal: String) throws
        -> (DicomRecallCoordinator, DicomObjectStoreProvider) {
        let destination = URL(fileURLWithPath: destinationRoot)
        try DicomLocalIngestFileSystem().createDirectory(destination)
        let source = DicomObjectStoreProvider(id: "source",
            store: DicomDirectoryObjectStore(root: URL(fileURLWithPath: sourceRoot)))
        let coordinator = DicomRecallCoordinator(providers: ["source": source,
            "destination": DicomLocalDiskProvider(id: "destination", root: destination)],
            journal: .init(directory: URL(fileURLWithPath: journal)))
        return (coordinator, source)
    }
    private static func printManifest(_ manifest: DicomTransferManifest) throws {
        print(String(decoding: try manifest.encode(), as: UTF8.self))
        if manifest.items.contains(where: { if case .failed = $0.state { return true }; return false }) { throw ExitCode(2) }
    }
}
