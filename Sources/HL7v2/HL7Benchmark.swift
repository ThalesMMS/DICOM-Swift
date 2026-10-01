import CryptoKit
import Foundation

/// Parse and serialize timings over an explicit HL7 v2 corpus with file digests and versions.
/// Results carry a fixed disclaimer: they describe this build on this corpus only.
public struct HL7BenchmarkResult: Codable, Equatable, Sendable {
    public struct FileResult: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let bytes: Int
        public let messageType: String?
        public let segments: Int
        public let iterations: Int
        public let parseMedianSeconds: Double?
        public let serializeMedianSeconds: Double?
        public let error: String?
    }
    public let corpus: String
    public let toolkitVersion: String
    public let hostDescription: String
    public let iterations: Int
    public let files: [FileResult]
    public let disclaimer: String
    public let cancelled: Bool
    public static let disclaimer = "Timings describe this build on the listed corpus and host only; they are not a conformance or interoperability claim."
}

public enum HL7Benchmark {
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
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, url.pathExtension.lowercased() == "hl7" { files.append(url) }
        }
        guard !files.isEmpty else { throw Failure.emptyCorpus(root.path) }
        return files.sorted { $0.path < $1.path }
    }

    public static func run(corpus root: URL, iterations: Int = 3, maximumFiles: Int = 1000, toolkitVersion: String,
                           parserOptions: HL7ParserOptions = .init(), isCancelled: () -> Bool = { false }) throws -> HL7BenchmarkResult {
        let files = try corpusFiles(at: root)
        guard files.count <= maximumFiles else { throw Failure.tooManyFiles(files.count, limit: maximumFiles) }
        let rounds = max(1, iterations)
        var results: [HL7BenchmarkResult.FileResult] = []
        var cancelled = false
        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
        for file in files {
            if isCancelled() { cancelled = true; break }
            let data: Data
            do { data = try Data(contentsOf: file) } catch {
                results.append(.init(path: file.path, sha256: "", bytes: 0, messageType: nil, segments: 0, iterations: 0, parseMedianSeconds: nil, serializeMedianSeconds: nil, error: error.localizedDescription))
                continue
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var parseTimes: [Double] = [], serializeTimes: [Double] = []
            var type: String?
            var segments = 0
            var failure: String?
            for _ in 0..<rounds {
                do {
                    let start = clock.now
                    let message = try HL7Parser(options: parserOptions).parse(data)
                    parseTimes.append(seconds(clock.now - start))
                    let serializeStart = clock.now
                    _ = try HL7Serializer().serialize(message)
                    serializeTimes.append(seconds(clock.now - serializeStart))
                    type = [message.messageType.code, message.messageType.triggerEvent].compactMap { $0 }.joined(separator: "^")
                    segments = message.segments.count
                } catch { failure = String(describing: error); break }
            }
            let parse = parseTimes.sorted(), serialize = serializeTimes.sorted()
            results.append(.init(path: file.path, sha256: digest, bytes: data.count, messageType: type, segments: segments, iterations: parse.count,
                                 parseMedianSeconds: parse.isEmpty ? nil : parse[parse.count / 2], serializeMedianSeconds: serialize.isEmpty ? nil : serialize[serialize.count / 2], error: failure))
        }
        let host = ProcessInfo.processInfo.operatingSystemVersionString + ", " + String(ProcessInfo.processInfo.activeProcessorCount) + " cores"
        return HL7BenchmarkResult(corpus: root.path, toolkitVersion: toolkitVersion, hostDescription: host, iterations: rounds, files: results,
                                  disclaimer: HL7BenchmarkResult.disclaimer, cancelled: cancelled)
    }
}
