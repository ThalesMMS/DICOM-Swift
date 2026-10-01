/// Demand-driven decoded-frame sequence that never produces ahead of `next()`.
public struct DicomDataBackedDecodedFrameSequence: AsyncSequence, Sendable {
    /// One Data-backed frame yielded per iterator pull.
    public typealias Element = DicomDataBackedDecodedFrame

    private let reader: DicomDecodedFrameReader
    private let range: Range<Int>

    init(reader: DicomDecodedFrameReader, range: Range<Int>) {
        self.reader = reader
        self.range = range
    }

    /// Creates an iterator whose `next()` method drives frame decoding.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(reader: reader, nextIndex: range.lowerBound, endIndex: range.upperBound)
    }

    /// Mutable pull cursor over a bounded frame range.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private let reader: DicomDecodedFrameReader
        private var nextIndex: Int
        private let endIndex: Int

        init(reader: DicomDecodedFrameReader, nextIndex: Int, endIndex: Int) {
            self.reader = reader
            self.nextIndex = nextIndex
            self.endIndex = endIndex
        }

        /// Decodes the next frame after checking cancellation, or returns nil at the end of the range.
        public mutating func next() async throws -> DicomDataBackedDecodedFrame? {
            try Task.checkCancellation()
            guard nextIndex < endIndex else { return nil }
            let index = nextIndex
            let frame = try await reader.dataBackedFrame(at: index)
            try Task.checkCancellation()
            nextIndex += 1
            return frame
        }
    }
}
