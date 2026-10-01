import CryptoKit
import Foundation

/// Decode throughput over an explicit corpus. Every result names the corpus files with their SHA-256,
/// the toolkit version and the machine, and carries a fixed disclaimer: timings describe this build on
/// this corpus and are not evidence of clinical or diagnostic quality.
public struct DicomDecodeBenchmarkResult: Codable, Equatable, Sendable {
    public struct FileResult: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let bytes: Int
        public let frames: Int
        public let transferSyntaxUID: String?
        public let iterations: Int
        public let medianSeconds: Double?
        public let minimumSeconds: Double?
        public let error: String?
    }
    public let corpus: String
    public let toolkitVersion: String
    public let hostDescription: String
    public let iterations: Int
    public let files: [FileResult]
    public let disclaimer: String
    public let cancelled: Bool
    public static let disclaimer = "Timings describe this build on the listed corpus and host only; they are not a clinical, diagnostic or quality claim."
}

public enum DicomDecodeBenchmark {
    public struct Options: Sendable {
        public var iterations: Int
        public var maximumFiles: Int
        public var toolkitVersion: String
        public init(iterations: Int = 3, maximumFiles: Int = 500, toolkitVersion: String) {
            self.iterations = max(1, iterations)
            self.maximumFiles = maximumFiles
            self.toolkitVersion = toolkitVersion
        }
    }
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case corpusNotFound(String)
        case emptyCorpus(String)
        case tooManyFiles(Int, limit: Int)
        public var errorDescription: String? {
            switch self {
            case .corpusNotFound(let path): return "Corpus \(path) does not exist"
            case .emptyCorpus(let path): return "Corpus \(path) contains no files"
            case .tooManyFiles(let count, let limit): return "Corpus has \(count) files; limit is \(limit)"
            }
        }
    }

    public static func corpusFiles(at root: URL, fileManager: FileManager = .default) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else { throw Failure.corpusNotFound(root.path) }
        guard isDirectory.boolValue else { return [root] }
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
        }
        guard !files.isEmpty else { throw Failure.emptyCorpus(root.path) }
        return files.sorted { $0.path < $1.path }
    }

    public static func run(corpus root: URL, options: Options, isCancelled: () -> Bool = { false }) throws -> DicomDecodeBenchmarkResult {
        let files = try corpusFiles(at: root)
        guard files.count <= options.maximumFiles else { throw Failure.tooManyFiles(files.count, limit: options.maximumFiles) }
        var results: [DicomDecodeBenchmarkResult.FileResult] = []
        var cancelled = false
        for file in files {
            if isCancelled() { cancelled = true; break }
            let data: Data
            do { data = try Data(contentsOf: file) } catch {
                results.append(.init(path: file.path, sha256: "", bytes: 0, frames: 0, transferSyntaxUID: nil, iterations: 0, medianSeconds: nil, minimumSeconds: nil, error: error.localizedDescription))
                continue
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var timings: [Double] = []
            var frames = 0
            var syntax: String?
            var failure: String?
            for _ in 0..<options.iterations {
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    let decoder = try DCMDecoder(data: data)
                    syntax = decoder.dataSet.string(for: .transferSyntaxUID)
                    let reader = DicomDecodedFrameReader(decoder: decoder)
                    frames = reader.frameCount
                    for index in 0..<frames { _ = try reader.frame(at: index) }
                } catch { failure = String(describing: error); break }
                let elapsed = clock.now - start
                timings.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
            }
            let sorted = timings.sorted()
            results.append(.init(path: file.path, sha256: digest, bytes: data.count, frames: frames, transferSyntaxUID: syntax, iterations: timings.count,
                                 medianSeconds: sorted.isEmpty ? nil : sorted[sorted.count / 2], minimumSeconds: sorted.first, error: failure))
        }
        let host = ProcessInfo.processInfo.operatingSystemVersionString + ", " + String(ProcessInfo.processInfo.activeProcessorCount) + " cores"
        return DicomDecodeBenchmarkResult(corpus: root.path, toolkitVersion: options.toolkitVersion, hostDescription: host, iterations: options.iterations,
                                          files: results, disclaimer: DicomDecodeBenchmarkResult.disclaimer, cancelled: cancelled)
    }
}
