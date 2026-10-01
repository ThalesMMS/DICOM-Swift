@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Serializes segment callbacks and rejects each block before it reaches disk.
final class DicomVideoRemuxOutput: NSObject, AVAssetWriterDelegate, Sendable {
    private struct State {
        let handle: FileHandle
        var written: Int64 = 0
        var failure: (any Error)?
    }

    private let state: Mutex<State>
    private let maximumBytes: Int64
    private let reserveBytes: @Sendable (Int64) throws -> Void

    init(url: URL, maximumBytes: Int64, reserveBytes: @escaping @Sendable (Int64) throws -> Void) throws {
        guard maximumBytes >= 0 else {
            throw DicomVideoRemuxError.outputBudgetExceeded(maximumBytes: maximumBytes)
        }
        try Data().write(to: url, options: .withoutOverwriting)
        state = Mutex(State(handle: try FileHandle(forWritingTo: url)))
        self.maximumBytes = maximumBytes
        self.reserveBytes = reserveBytes
    }

    var count: Int64 { state.withLock { $0.written } }

    func append(_ data: Data) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            do {
                let bytes = Int64(data.count)
                guard bytes <= maximumBytes - state.written else {
                    throw DicomVideoRemuxError.outputBudgetExceeded(maximumBytes: maximumBytes)
                }
                try reserveBytes(bytes)
                try state.handle.write(contentsOf: data)
                state.written += bytes
            } catch {
                state.failure = error
                throw error
            }
        }
    }

    func checkError() throws {
        try state.withLock { if let failure = $0.failure { throw failure } }
    }

    func close() throws {
        try state.withLock { try $0.handle.close() }
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType) {
        // append retains the first error for the async producer to propagate.
        do { try append(segmentData) } catch { }
    }
}
