/// Serializes the cursor captured by the source-compatible AsyncThrowingStream API.
actor DicomDecodedFrameStreamCursor {
    private let reader: DicomDecodedFrameReader
    private var nextIndex: Int
    private let endIndex: Int

    init(reader: DicomDecodedFrameReader, range: Range<Int>) {
        self.reader = reader
        nextIndex = range.lowerBound
        endIndex = range.upperBound
    }

    func next() async throws -> DicomDecodedFrame? {
        try Task.checkCancellation()
        guard nextIndex < endIndex else { return nil }
        let index = nextIndex
        nextIndex += 1
        do { return try await reader.frame(at: index) }
        catch { nextIndex = endIndex; throw error }
    }
}
