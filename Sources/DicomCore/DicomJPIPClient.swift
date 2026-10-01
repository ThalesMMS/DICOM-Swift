import Foundation

/// Decodes demand-driven JPIP image entities into progressive volume updates.
public struct DicomJPIPClient: Sendable {
    private let transport: any DicomJPIPTransport

    /// Creates a client over an injected JPIP transport.
    ///
    /// `bufferingPolicy` remains source-compatible with the former producer stream. The
    /// demand-driven implementation does not allocate an intermediate update buffer.
    public init(
        transport: any DicomJPIPTransport,
        bufferingPolicy: AsyncThrowingStream<DicomProgressiveVolumeUpdate, Error>.Continuation.BufferingPolicy =
            .bufferingNewest(1)
    ) {
        self.transport = transport
        _ = bufferingPolicy
    }

    /// Streams decoded updates for referenced DICOM pixel data.
    public func volumeUpdates(
        for reference: DicomJPIPReferencedPixelData,
        decode: @escaping @Sendable (DicomJPIPLayerPayload) async throws -> DicomSeriesVolume
    ) -> AsyncThrowingStream<DicomProgressiveVolumeUpdate, Error> {
        guard reference.numberOfFrames == 1 else {
            return AsyncThrowingStream(unfolding: {
                throw DicomJPIPTransportError.multiFrameVolumeRequiresFrameRequests(
                    frameCount: reference.numberOfFrames
                )
            })
        }
        return volumeUpdates(for: reference.makeVolumeRequest(), decode: decode)
    }

    /// Streams decoded updates for an explicit JPIP request without producer run-ahead.
    public func volumeUpdates(
        for request: DicomJPIPRequest,
        decode: @escaping @Sendable (DicomJPIPLayerPayload) async throws -> DicomSeriesVolume
    ) -> AsyncThrowingStream<DicomProgressiveVolumeUpdate, Error> {
        let cursor = Cursor(
            payloads: transport.payloads(for: request),
            decode: decode
        )
        return AsyncThrowingStream(unfolding: {
            try await cursor.next()
        })
    }
}

private extension DicomJPIPClient {
    actor Cursor {
        private let payloads: DicomJPIPPayloadSequence
        private let decode: @Sendable (DicomJPIPLayerPayload) async throws -> DicomSeriesVolume

        init(
            payloads: DicomJPIPPayloadSequence,
            decode: @escaping @Sendable (DicomJPIPLayerPayload) async throws -> DicomSeriesVolume
        ) {
            self.payloads = payloads
            self.decode = decode
        }

        func next() async throws -> DicomProgressiveVolumeUpdate? {
            try Task.checkCancellation()
            guard let payload = try await payloads.next() else { return nil }
            try Task.checkCancellation()
            let volume = try await decode(payload)
            try Task.checkCancellation()
            return DicomProgressiveVolumeUpdate(layer: payload.layer, volume: volume)
        }
    }
}

/// Byte accounting uses unique cached data, rather than the sum of cumulative HTTP entities.
public struct DicomJPIPPerformanceReport: Sendable, Equatable {
    public let usefulBytes: Int
    public let redundantBytes: Int
    public let firstPreviewTimestamp: Date?
    public let finalTimestamp: Date?
    public let peakCacheBytes: Int

    public init(cache: DicomJPIPDatabinCache, firstPreviewTimestamp: Date? = nil, finalTimestamp: Date? = nil) {
        usefulBytes = cache.usefulBytes
        redundantBytes = cache.redundantBytes
        peakCacheBytes = cache.peakBytes
        self.firstPreviewTimestamp = firstPreviewTimestamp
        self.finalTimestamp = finalTimestamp
    }
}
