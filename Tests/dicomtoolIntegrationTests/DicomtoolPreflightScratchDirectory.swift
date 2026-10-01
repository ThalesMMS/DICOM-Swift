import Foundation

struct DicomtoolPreflightScratchDirectory: Sendable {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case emptyOverride
        case overrideMustBeAbsolute(String)
        case cannotPrepareRoot(String)
        case cannotCreateChild(String)
        case unsafeCleanupTarget(String)

        var errorDescription: String? {
            switch self {
            case .emptyOverride:
                "\(DicomtoolPreflightScratchDirectory.environmentKey) must not be empty."
            case let .overrideMustBeAbsolute(path):
                "\(DicomtoolPreflightScratchDirectory.environmentKey) must be absolute: \(path)"
            case let .cannotPrepareRoot(path):
                "Cannot prepare dicomtool test scratch root: \(path)"
            case let .cannotCreateChild(path):
                "Cannot create dicomtool preflight scratch directory: \(path)"
            case let .unsafeCleanupTarget(path):
                "Refusing to remove a non-child dicomtool scratch path: \(path)"
            }
        }
    }

    static let environmentKey = "DICOMTOOL_TEST_SCRATCH_ROOT"

    let rootURL: URL
    let url: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        defaultRootURL: URL = FileManager.default.temporaryDirectory,
        identifier: UUID = UUID()
    ) throws {
        let candidateRoot: URL
        if let configuredPath = environment[Self.environmentKey] {
            guard !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.emptyOverride
            }
            guard NSString(string: configuredPath).isAbsolutePath else {
                throw Error.overrideMustBeAbsolute(configuredPath)
            }
            candidateRoot = URL(fileURLWithPath: configuredPath, isDirectory: true)
        } else {
            candidateRoot = defaultRootURL
        }

        let standardizedRoot = candidateRoot.standardizedFileURL
        do {
            try fileManager.createDirectory(at: standardizedRoot, withIntermediateDirectories: true)
        } catch {
            throw Error.cannotPrepareRoot(standardizedRoot.path)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardizedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Error.cannotPrepareRoot(standardizedRoot.path)
        }

        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let child = resolvedRoot.appendingPathComponent(
            "dicomtool-preflight-\(identifier.uuidString)",
            isDirectory: true
        )
        guard child.deletingLastPathComponent() == resolvedRoot else {
            throw Error.cannotCreateChild(child.path)
        }

        do {
            try fileManager.createDirectory(at: child, withIntermediateDirectories: false)
        } catch {
            throw Error.cannotCreateChild(child.path)
        }

        rootURL = resolvedRoot
        url = child
    }

    func remove(fileManager: FileManager = .default) throws {
        guard url.deletingLastPathComponent() == rootURL,
              url.lastPathComponent.hasPrefix("dicomtool-preflight-") else {
            throw Error.unsafeCleanupTarget(url.path)
        }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
