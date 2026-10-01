import DicomCore
import Foundation

/// Files are durable; the shared toolkit supplies matching and representation handling.
actor WebDirectoryStorage: DicomWebStorageProviding {
    private let directory: URL
    private let index: DicomWebInMemoryStorage
    private let conflictFileSystem: any DicomIngestFileSystem

    init(directory: URL, conflictFileSystem: any DicomIngestFileSystem = DicomLocalIngestFileSystem()) throws {
        self.directory = directory
        self.conflictFileSystem = conflictFileSystem
        index = DicomWebInMemoryStorage()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in try NetCommand.files([directory.path]) {
            // Keep retained conflicts out of the canonical index after restart (issue #2529).
            let relativeComponents = file.pathComponents.dropFirst(directory.pathComponents.count)
            guard !relativeComponents.contains(".conflicts") else { continue }
            do {
                let data = try Data(contentsOf: file)
                let meta = try DicomPart10FileMetaParser.parse(data)
                guard let syntax = DicomTransferSyntax(rawValue: meta.transferSyntaxUID ?? "") else {
                    throw DicomWebError(kind: .unsupportedMediaType)
                }
                try index.add(part10Data: data, transferSyntax: syntax)
            } catch {
                FileHandle.standardError.write(Data("warning: skipped \(file.lastPathComponent): \(error.localizedDescription)\n".utf8))
            }
        }
    }

    func searchStudies(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] {
        try await index.searchStudies(parameters: parameters)
    }
    func searchSeries(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] {
        try await index.searchSeries(parameters: parameters)
    }
    func searchInstances(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] {
        try await index.searchInstances(parameters: parameters)
    }
    func metadata(study: String, series: String?, instance: String?) async throws -> [DicomDataSet] {
        try await index.metadata(study: study, series: series, instance: instance)
    }
    func instance(study: String, series: String, instance: String) async throws -> DicomWebStoredInstance {
        try await index.instance(study: study, series: series, instance: instance)
    }
    func bulkData(uri: String) async throws -> Data { try await index.bulkData(uri: uri) }
    func store(instances: [DicomWebStoredInstance]) async throws -> [DicomWebStorageResult] {
        var results: [DicomWebStorageResult] = []
        for instance in instances {
            try Task.checkCancellation()
            do {
                // Encode the UID without interpreting any remote identifier as a path.
                guard instance.sopInstanceUID.utf8.count <= 64 else { throw DicomWebError(kind: .badRequest) }
                let filename = instance.sopInstanceUID.utf8.map { String(format: "%02x", $0) }.joined()
                if let prior = index.allInstances().first(where: { $0.sopInstanceUID == instance.sopInstanceUID }) {
                    let differs = prior.part10Data != instance.part10Data
                    if differs {
                        // Preserve the submitted bytes without replacing the retrievable original (issue #2529).
                        let conflicts = directory.appendingPathComponent(".conflicts", isDirectory: true)
                        try FileManager.default.createDirectory(at: conflicts, withIntermediateDirectories: true)
                        let hash = DicomArchiveRepresentation.hash(instance.part10Data)
                        let archived = conflicts.appendingPathComponent("\(filename)~\(hash).dcm")
                        try instance.part10Data.write(to: archived, options: .atomic)
                        DicomConflictRetention.enforce(in: conflicts, preserving: [archived],
                                                      fileSystem: conflictFileSystem)
                    }
                    results.append(.init(sopClassUID: instance.sopClassUID, sopInstanceUID: instance.sopInstanceUID,
                                         warningReason: differs ? 0xB000 : nil))
                    continue
                }
                let file = directory.appendingPathComponent(filename + ".dcm")
                try instance.part10Data.write(to: file, options: .atomic)
                results += try await index.store(instances: [instance])
            } catch is CancellationError { throw CancellationError() }
            catch {
                results.append(.init(sopClassUID: instance.sopClassUID, sopInstanceUID: instance.sopInstanceUID,
                                     failureReason: 0xA700))
            }
        }
        return results
    }
}
