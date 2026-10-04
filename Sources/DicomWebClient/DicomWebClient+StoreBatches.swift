import Foundation
import DicomData

/// How `DicomWebClient.storeFiles` splits files into STOW-RS requests.
public struct DicomWebStoreBatchOptions: Equatable, Sendable {
    public var maximumFilesPerBatch: Int
    /// A file larger than this goes alone in its batch.
    public var maximumBytesPerBatch: Int

    public init(maximumFilesPerBatch: Int = 50, maximumBytesPerBatch: Int = 64 * 1024 * 1024) {
        self.maximumFilesPerBatch = max(1, maximumFilesPerBatch)
        self.maximumBytesPerBatch = max(1, maximumBytesPerBatch)
    }
}

/// The outcome of one file of `DicomWebClient.storeFiles`.
public struct DicomWebStoreFileResult: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case stored, warning, failed
        /// The server answered without naming this instance, so its storage is not confirmed.
        case unknown
        /// A fatal error or cancellation stopped the store before this file's batch.
        case notSent
    }

    public let url: URL
    public let sopInstanceUID: String?
    public let state: State
    public let reason: String?
    /// Warning or Failure Reason (PS3.18 Annex I), such as 0xB000, 0xA700 or 0xC000.
    public let dicomStatus: UInt16?
    public let httpStatus: Int?
    /// The URL loading error that failed the batch, when there was one. It tells a request that never reached the
    /// server (certificate refused, host unreachable) from one that ended after the upload began.
    public let transportErrorCode: URLError.Code?
    /// The `Warning` header of the answer to this file's batch.
    public var warning: String? = nil

    public init(url: URL, sopInstanceUID: String?, state: State, reason: String? = nil,
                dicomStatus: UInt16? = nil, httpStatus: Int? = nil, transportErrorCode: URLError.Code? = nil) {
        self.url = url
        self.sopInstanceUID = sopInstanceUID
        self.state = state
        self.reason = reason
        self.dicomStatus = dicomStatus
        self.httpStatus = httpStatus
        self.transportErrorCode = transportErrorCode
    }

    /// The outcome of instance `sopInstanceUID` in a STOW-RS answer (PS3.18 Annex I). An instance the answer does
    /// not list is unknown, whatever the status: a response that names nothing confirms nothing.
    public init(url: URL, sopInstanceUID uid: String, in result: DicomWebStoreResult) {
        self.init(url: url, sopInstanceUID: uid, outcomeIn: result)
        warning = result.warning
    }

    private init(url: URL, sopInstanceUID uid: String, outcomeIn result: DicomWebStoreResult) {
        let status = result.statusCode
        let matches = result.storeResponse?.instances.filter { $0.sopInstanceUID == uid } ?? []
        guard matches.count == 1, let instance = matches.first else {
            self.init(url: url, sopInstanceUID: uid, state: .unknown,
                      reason: "The server did not report this instance.", httpStatus: status)
            return
        }
        switch instance.outcome {
        case .accepted:
            self.init(url: url, sopInstanceUID: uid, state: .stored, httpStatus: status)
        case .warning:
            let code = instance.warningReason.flatMap(UInt16.init(exactly:))
            self.init(url: url, sopInstanceUID: uid, state: .warning,
                      reason: code.map(DicomWebClient.reasonDescription), dicomStatus: code, httpStatus: status)
        case .failed, .unknown:
            let code = instance.failureReason.flatMap(UInt16.init(exactly:))
            self.init(url: url, sopInstanceUID: uid, state: .failed,
                      reason: code.map(DicomWebClient.reasonDescription) ?? "The server refused this instance.",
                      dicomStatus: code, httpStatus: status)
        }
    }
}

/// Reported after every batch of `DicomWebClient.storeFiles`.
public struct DicomWebStoreBatchProgress: Equatable, Sendable {
    public let completedBatches: Int
    public let totalBatches: Int
    public let completedFiles: Int
    public let totalFiles: Int
}

extension DicomWebClient {
    /// Stores `files` with one STOW-RS request per batch, each streamed from disk, and returns one result per file in
    /// the given order (#2892). A file without valid File Meta Information is refused alone. 401, 403, 404, network,
    /// TLS, timeout and cancellation stop the remaining batches, whose files are reported as not sent; any other
    /// failure fails only its batch; a 4xx that carries a store response (a 400 with a Failed SOP Sequence) is mapped
    /// instance by instance with each Failure Reason. Each file is streamed from disk with no copy of the batch when
    /// the transport is a `DicomWebStreamedBodyTransport`, and may be up to `maximumSTOWInstanceBytes`. With a `retryPolicy` that repeats, a batch still refused with 429 or 503 after its
    /// last attempt also stops the remaining batches, rather than sending them to a server that is overloaded. Every answer, including a partial one (202, 409), is mapped instance by instance,
    /// by the SOP Instance UID of each file's File Meta Information or, when given, by `sopInstanceUIDs[i]`.
    public func storeFiles(_ files: [URL], sopInstanceUIDs: [String]? = nil, studyInstanceUID: String? = nil,
                           options: DicomWebStoreBatchOptions = .init(),
                           progress: (@Sendable (DicomWebStoreBatchProgress) async -> Void)? = nil)
        async -> [DicomWebStoreFileResult] {
        var results = [DicomWebStoreFileResult?](repeating: nil, count: files.count)
        var sendable: [(index: Int, uid: String, bytes: Int)] = []
        for (index, file) in files.enumerated() {
            do {
                let (uid, bytes) = try Self.storeCandidate(file, index: index, maximumBytes: maximumStoreFileBytes)
                let known = sopInstanceUIDs.flatMap { index < $0.count ? $0[index] : nil }
                sendable.append((index, known ?? uid, bytes))
            } catch {
                results[index] = .init(url: file, sopInstanceUID: nil, state: .failed, reason: Self.describe(error))
            }
        }
        let batches = Self.batches(sendable, options: options)
        var stop: (reason: String, httpStatus: Int?)?
        var completedFiles = files.count - sendable.count
        for (number, batch) in batches.enumerated() {
            if stop == nil, Task.isCancelled { stop = ("The store was cancelled.", nil) }
            if let stop {
                for item in batch {
                    results[item.index] = .init(url: files[item.index], sopInstanceUID: item.uid, state: .notSent,
                                                reason: stop.reason, httpStatus: stop.httpStatus)
                }
                continue
            }
            do {
                let result = try await storeInstances(files: batch.map { files[$0.index] }, studyInstanceUID: studyInstanceUID)
                for item in batch {
                    results[item.index] = .init(url: files[item.index], sopInstanceUID: item.uid, in: result)
                }
            } catch {
                let httpStatus = (error as? DicomWebError)?.statusCode
                for item in batch {
                    var result = DicomWebStoreFileResult(url: files[item.index], sopInstanceUID: item.uid, state: .failed,
                                                         reason: Self.describe(error), httpStatus: httpStatus,
                                                         transportErrorCode: (error as? URLError)?.code)
                    result.warning = (error as? DicomWebError)?.warning
                    results[item.index] = result
                }
                if isFatal(error) { stop = (Self.describe(error), httpStatus) }
            }
            completedFiles += batch.count
            await progress?(.init(completedBatches: number + 1, totalBatches: batches.count,
                                  completedFiles: completedFiles, totalFiles: files.count))
        }
        return zip(files, results).map { file, result in
            result ?? .init(url: file, sopInstanceUID: nil, state: .notSent, reason: "The store was cancelled.")
        }
    }

    /// The SOP Instance UID and size of a file that can go in a batch.
    private static func storeCandidate(_ file: URL, index: Int, maximumBytes: Int) throws -> (String, Int) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard let length = Int(exactly: size), length <= maximumBytes else {
            throw DicomWebClientError.storeRequestBodyTooLarge(byteCount: Int(clamping: size), limit: maximumBytes)
        }
        let prefix = try fileMetaPrefix(of: handle, length: length, instanceIndex: index)
        _ = try DicomWebSTOWMultipartBodyBuilder.prepare(instances: [.init(data: prefix, transferSyntax: nil)])
        guard let uid = try DicomPart10FileMetaParser.parse(prefix).mediaStorageSOPInstanceUID?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0")), !uid.isEmpty else {
            throw DicomWebClientError.invalidStorePart10FileMeta(instanceIndex: index)
        }
        return (uid, length)
    }

    private static func batches(_ items: [(index: Int, uid: String, bytes: Int)],
                                options: DicomWebStoreBatchOptions) -> [[(index: Int, uid: String, bytes: Int)]] {
        var batches: [[(index: Int, uid: String, bytes: Int)]] = []
        var current: [(index: Int, uid: String, bytes: Int)] = []
        var bytes = 0
        for item in items {
            if !current.isEmpty, current.count == options.maximumFilesPerBatch
                || item.bytes > options.maximumBytesPerBatch - bytes {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(item)
            bytes += item.bytes
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// PS3.18 Annex I reasons, with the code.
    static func reasonDescription(_ code: UInt16) -> String {
        let text: String
        switch code {
        case 0xB000: text = "Coercion of data elements"
        case 0xB006: text = "Elements discarded"
        case 0xB007: text = "Data set does not match SOP class"
        case 0x0110: text = "Processing failure"
        case 0x0122: text = "Referenced SOP Class not supported"
        case 0x0124: text = "Not authorized"
        case 0xA700...0xA7FF: text = "Out of resources"
        case 0xA900...0xA9FF: text = "Data set does not match SOP class"
        case 0xC000...0xCFFF: text = "Cannot understand"
        default: text = "Reason"
        }
        return text + String(format: " (0x%04X)", code)
    }

    private func isFatal(_ error: Error) -> Bool {
        if error is CancellationError || error is URLError { return true }
        guard let error = error as? DicomWebError else { return false }
        if [.unauthorized, .forbidden, .notFound].contains(error.kind) { return true }
        return configuration.retryPolicy.maximumAttempts > 1 && DicomWebRetryPolicy.isTransient(error, for: .store)
    }

    private static func describe(_ error: Error) -> String {
        if error is CancellationError { return "The store was cancelled." }
        if case DicomWebClientError.invalidStorePart10FileMeta = error { return "The file has no valid File Meta Information." }
        if let error = error as? DicomWebError { return "The server answered HTTP \(error.statusCode) (\(error.kind.rawValue))." }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
