import Foundation

/// Pull-based raw frames for import, thumbnail decode and export consumers sharing a session.
/// Advancing the iterator is the only operation that requests or materializes a frame.
public struct DicomSourceFrameSequence: AsyncSequence, Sendable {
    public struct Element: Sendable {
        public let index: Int
        public let data: Data
        public let packedBitOffset: Int
    }

    private let session: DicomSourceFrameSession
    private let range: Range<Int>

    init(session: DicomSourceFrameSession, range: Range<Int>) {
        self.session = session
        self.range = range
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(session: session, nextIndex: range.lowerBound, endIndex: range.upperBound)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let session: DicomSourceFrameSession
        private var nextIndex: Int
        private let endIndex: Int

        init(session: DicomSourceFrameSession, nextIndex: Int, endIndex: Int) {
            self.session = session
            self.nextIndex = nextIndex
            self.endIndex = endIndex
        }

        public mutating func next() async throws -> Element? {
            guard nextIndex < endIndex else { return nil }
            do {
                try Task.checkCancellation()
                let data = try await session.frameData(at: nextIndex)
                let result = Element(index: nextIndex, data: data,
                                     packedBitOffset: try session.index.packedBitOffset(forFrame: nextIndex))
                nextIndex += 1
                return result
            } catch {
                nextIndex = endIndex
                throw error
            }
        }
    }
}
