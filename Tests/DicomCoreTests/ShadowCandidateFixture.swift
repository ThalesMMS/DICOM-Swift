import Foundation
@testable import DicomCore

struct ShadowCandidateFixture: DicomFrameCodecBackend {
    enum Failure: Error { case unavailable }
    let capabilities: DicomFrameCodecCapabilities
    let output: Data?
    var cancelled = false

    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
        if cancelled { throw CancellationError() }
        guard let output else { throw Failure.unavailable }
        return DicomCodecDecodedFrame(
            buffer: .owned(output), width: request.descriptor.columns, height: request.descriptor.rows,
            bitsPerSample: request.descriptor.bitsStored, componentCount: request.descriptor.samplesPerPixel
        )
    }
}
