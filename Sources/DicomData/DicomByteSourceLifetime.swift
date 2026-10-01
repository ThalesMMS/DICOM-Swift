import Synchronization

package final class DicomByteSourceLifetime: Sendable {
    private struct State {
        var closed = false
        var copiedBytes = 0
    }
    private let state = Mutex(State())

    package func checkOpen() throws {
        try state.withLock { state in
            if state.closed { throw DicomByteSource.Failure.closed }
        }
    }

    package func close() { state.withLock { $0.closed = true } }
    package var copiedBytes: Int { state.withLock { $0.copiedBytes } }
    package func recordCopy(_ count: Int) {
        state.withLock {
            let (total, overflow) = $0.copiedBytes.addingReportingOverflow(count)
            $0.copiedBytes = overflow ? Int.max : total
        }
    }
}
