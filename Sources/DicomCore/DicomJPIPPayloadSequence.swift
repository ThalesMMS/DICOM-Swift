import Foundation

/// Single-pass, demand-driven sequence of cumulative JPIP image entities.
public struct DicomJPIPPayloadSequence: AsyncSequence, Sendable {
    public typealias Element = DicomJPIPLayerPayload

    /// Iterator that requests at most one additional entity per call to `next()`.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private let nextElement: @Sendable () async throws -> Element?

        fileprivate init(nextElement: @escaping @Sendable () async throws -> Element?) {
            self.nextElement = nextElement
        }

        /// Requests the next cumulative image entity.
        public mutating func next() async throws -> Element? {
            try await nextElement()
        }
    }

    private let nextElement: @Sendable () async throws -> Element?

    /// Creates a sequence from a serialized asynchronous unfolding operation.
    public init(unfolding nextElement: @escaping @Sendable () async throws -> Element?) {
        self.nextElement = nextElement
    }

    /// Creates an iterator over the sequence's shared single-pass cursor.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(nextElement: nextElement)
    }

    func next() async throws -> Element? {
        try await nextElement()
    }
}
