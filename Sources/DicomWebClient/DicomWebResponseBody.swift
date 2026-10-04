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
    /// The request runs on a session of its own with this session's configuration. Holding back a body that is read
    /// slowly stalls its session's delegate queue, and a queue of its own keeps that from delaying any other task.
    public func dicomWebResponse(
        for request: URLRequest, delegate: DicomWebRedirectDelegate
    ) async throws -> (DicomWebResponseBody, URLResponse) {
        let buffer = DicomWebResponseBuffer(delegate: delegate)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: buffer, delegateQueue: queue)
        let task = session.dataTask(with: request)
        delegate.urlSession(session, didCreateTask: task)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                buffer.start(task, in: session, continuation: continuation)
            }
        } onCancel: { task.cancel() }
        return (.init(task: task, buffer: buffer), response)
    }
}

/// Session delegate that queues the blocks of a response body for its single reader. Suspending a data task does not
/// stop the blocks arriving, so once `maximumBufferedBytes` wait unread the delegate callback itself waits for the
/// reader; URLSession then reads no further and TCP flow control holds the server back instead of the body piling up
/// in memory. A cancelled task releases the wait.
final class DicomWebResponseBuffer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumBufferedBytes = 1024 * 1024

    private let delegate: DicomWebRedirectDelegate
    /// Weak because the task's session keeps this delegate until the task completes.
    private weak var task: URLSessionDataTask?
    private let condition = NSCondition()
    private var response: CheckedContinuation<URLResponse, Error>?
    private var reader: CheckedContinuation<Data?, Error>?
    private var blocks: [Data] = []
    private var bufferedBytes = 0
    private var end: Result<Void, Error>?

    init(delegate: DicomWebRedirectDelegate) {
        self.delegate = delegate
    }

    /// Resumes `task`; `session` is released once the task completes.
    func start(_ task: URLSessionDataTask, in session: URLSession,
               continuation: CheckedContinuation<URLResponse, Error>) {
        condition.withLock {
            self.task = task
            response = continuation
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                condition.withLock {
                    if !blocks.isEmpty {
                        let block = blocks.removeFirst()
                        bufferedBytes -= block.count
                        condition.signal()
                        continuation.resume(returning: block)
                    } else if let end {
                        continuation.resume(with: end.map { nil })
                    } else {
                        reader = continuation
                    }
                }
            }
        } onCancel: { [weak self] in
            guard let self else { return }
            condition.withLock {
                task?.cancel()
                condition.signal()
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let waiter = condition.withLock { () -> CheckedContinuation<URLResponse, Error>? in
            defer { self.response = nil }
            return self.response
        }
        completionHandler(.allow)
        waiter?.resume(returning: response)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.withLock {
            if let reader {
                self.reader = nil
                reader.resume(returning: data)
                return
            }
            blocks.append(data)
            bufferedBytes += data.count
            // The task state is checked again every 100 ms, so a cancellation from elsewhere, such as the deadline,
            // also releases the wait.
            while bufferedBytes >= Self.maximumBufferedBytes, dataTask.state == .running {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let ending: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        condition.withLock {
            end = ending
            response?.resume(throwing: error ?? URLError(.badServerResponse))
            response = nil
            reader?.resume(with: ending.map { nil })
            reader = nil
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
