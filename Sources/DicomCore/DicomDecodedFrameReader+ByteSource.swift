import Foundation

extension DicomDecodedFrameReader {
    /// Source-compatible array decoding through the shared bounded index/session path.
    /// Keep a DicomSourceFrameSession when reading multiple frames of the same revision.
    public static func frame(at index: Int, from source: DicomByteSource,
                             metadata: DicomSourceMetadata) async throws -> DicomDecodedFrame {
        let layout = try await DicomSourceFrameIndex.build(from: source, metadata: metadata)
        let session = try DicomSourceFrameSession(source: source, index: layout)
        return try await session.frame(at: index)
    }
}
