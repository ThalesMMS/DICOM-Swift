import Foundation

/// The body of a DICOMweb response, read in the blocks URLSession receives rather than a byte at a time, so a large
/// retrieve does not spend one asynchronous step per byte.
public struct DicomWebResponseBody: Sendable {
    /// The data task; cancelling it ends the body with its error.
    public let task: URLSessionDataTask
    let buffer: DicomWebResponseBuffer

    /// The next block of the body, or nil once it has all been read.
    public func next() async throws -> Data? {
        try await buffer.next()
    }
}

extension URLSession {
    /// Starts `request` and returns its response as soon as the headers arrive, with the body still to be read.
    /// `delegate` decides redirects, authentication challenges and resent file bodies, and receives the task so its
    /// deadline can cancel it.
    ///
    /// The request runs on this session, sharing its connections with the session's other requests. No delegate
    /// callback waits for the reader: a body that arrives faster than it is read is held in memory up to 1 MiB and in
    /// a temporary file beyond that, which is deleted as soon as it has been read, when the task is cancelled and when
    /// the body is released. A body whose connection fails still yields every block that arrived before the failure,
    /// and then the error.
    public func dicomWebResponse(
        for request: URLRequest, delegate: DicomWebRedirectDelegate
    ) async throws -> (DicomWebResponseBody, URLResponse) {
        try await dicomWebResponse(for: request, delegate: delegate,
                                   spillDirectory: FileManager.default.temporaryDirectory)
    }

    func dicomWebResponse(
        for request: URLRequest, delegate: DicomWebRedirectDelegate, spillDirectory: URL
    ) async throws -> (DicomWebResponseBody, URLResponse) {
        let buffer = DicomWebResponseBuffer(delegate: delegate, spillDirectory: spillDirectory)
        let task = dataTask(with: request)
        task.delegate = buffer
        delegate.urlSession(self, didCreateTask: task)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                buffer.start(task, continuation: continuation)
            }
        } onCancel: { task.cancel() }
        return (.init(task: task, buffer: buffer), response)
    }
}

/// Task delegate that queues the blocks of a response body for its single reader. Suspending a data task does not
/// stop the blocks arriving, and holding back the delegate callback would stall every other task of the session, so
/// the blocks are always accepted: up to `maximumBufferedBytes` unread wait in memory, and the rest go to a spill file
/// that the reader drains, in order, once the memory is empty. When the task fails, the reader gets what is still
/// queued before the error, so the parts that arrived whole before a dropped connection are not lost. The file is
/// deleted when it has been read, when the task is cancelled and when this buffer is released.
final class DicomWebResponseBuffer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBufferedBytes = 1024 * 1024

    private let delegate: DicomWebRedirectDelegate
    private let spillDirectory: URL
    /// Weak because the task keeps this delegate until it completes.
    private weak var task: URLSessionDataTask?
    private let lock = NSLock()
    private var response: CheckedContinuation<URLResponse, Error>?
    private var reader: CheckedContinuation<Data?, Error>?
    private var blocks: [Data] = []
    private var bufferedBytes = 0
    /// Set only while it holds unread bytes; every block then goes after them.
    private var spill: DicomWebResponseSpillFile?
    private var end: Result<Void, Error>?

    init(delegate: DicomWebRedirectDelegate, spillDirectory: URL) {
        self.delegate = delegate
        self.spillDirectory = spillDirectory
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<URLResponse, Error>) {
        lock.withLock {
            self.task = task
            response = continuation
        }
        task.resume()
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let failed = lock.withLock { () -> Bool in
                    if !blocks.isEmpty {
                        let block = blocks.removeFirst()
                        bufferedBytes -= block.count
                        continuation.resume(returning: block)
                    } else if let spill {
                        do {
                            let block = try spill.readNext(upTo: Self.maximumBufferedBytes)
                            if !spill.hasUnreadBytes { discardSpill() }
                            continuation.resume(returning: block)
                        } catch {
                            fail(error)
                            continuation.resume(throwing: error)
                            return true
                        }
                    } else if let end {
                        continuation.resume(with: end.map { nil })
                    } else {
                        reader = continuation
                    }
                    return false
                }
                if failed { cancelTask() }
            }
        } onCancel: { [weak self] in
            self?.cancelTask()
        }
    }

    private func cancelTask() {
        lock.withLock { task }?.cancel()
    }

    /// Ends the body with `error`, dropping what was not read. Call with the lock held.
    private func fail(_ error: Error) {
        if end == nil { end = .failure(error) }
        blocks = []
        bufferedBytes = 0
        discardSpill()
    }

    /// Call with the lock held.
    private func discardSpill() {
        spill?.remove()
        spill = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let waiter = lock.withLock { () -> CheckedContinuation<URLResponse, Error>? in
            defer { self.response = nil }
            return self.response
        }
        completionHandler(.allow)
        waiter?.resume(returning: response)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failed = lock.withLock { () -> Bool in
            if let reader {
                self.reader = nil
                reader.resume(returning: data)
                return false
            }
            guard end == nil else { return false }
            if spill == nil, bufferedBytes < Self.maximumBufferedBytes {
                blocks.append(data)
                bufferedBytes += data.count
                return false
            }
            do {
                let file = try spill ?? DicomWebResponseSpillFile(in: spillDirectory)
                spill = file
                try file.append(data)
                return false
            } catch {
                fail(error)
                return true
            }
        }
        if failed { dataTask.cancel() }
    }

    /// Responses are never served from the cache (see the transport's request), and DICOM bodies are not written to
    /// it either.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            // A cancelled task has no reader left for the queued blocks; any other failure is reported after them.
            if let error, (error as? URLError)?.code == .cancelled {
                fail(error)
            } else if end == nil {
                end = error.map { .failure($0) } ?? .success(())
            }
            response?.resume(throwing: error ?? URLError(.badServerResponse))
            response = nil
            if let reader, let end {
                self.reader = nil
                reader.resume(with: end.map { nil })
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request,
                            completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        delegate.urlSession(session, task: task, needNewBodyStream: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition,
                                                            URLCredential?) -> Void) {
        delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }
}
