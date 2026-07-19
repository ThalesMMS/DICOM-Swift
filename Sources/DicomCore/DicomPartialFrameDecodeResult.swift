import Foundation

/// Decoded pixels plus the execution and coordinate metadata of a partial request.
public struct DicomPartialFrameDecodeResult: Sendable, Equatable {
    /// Backend operation used to produce the returned pixels.
    public enum Execution: String, Sendable, Equatable {
        case fullFrame
        case directRegion
        case directResolution
        case directRegionAndResolution
        case directQualityLayer
    }

    /// Refinement status of the returned pixel values.
    public enum QualityState: Sendable, Equatable {
        case preview
        case refinement(layer: Int)
        case final
    }

    /// Mapping metadata between source pixels and returned output pixels.
    public struct CoordinateTransform: Sendable, Equatable {
        /// Source-space region represented by the output.
        public let sourceRegion: DicomFrameRegion
        /// Width of the returned pixel grid.
        public let outputWidth: Int
        /// Height of the returned pixel grid.
        public let outputHeight: Int

        /// Creates mapping metadata for a decoded output grid.
        public init(sourceRegion: DicomFrameRegion, outputWidth: Int, outputHeight: Int) {
            self.sourceRegion = sourceRegion
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
        }
    }

    /// Typed decoded pixels and renderer-facing DICOM metadata.
    public let frame: DicomDecodedFrame
    /// Clipped source-space region represented by the result.
    public let decodedSourceRegion: DicomFrameRegion
    /// Mapping between source and output coordinates.
    public let coordinateTransform: CoordinateTransform
    /// Highest delivered cumulative quality layer, if quality was constrained.
    public let deliveredQualityLayer: Int?
    /// Whether the pixels are a preview, refinement, or final quality.
    public let qualityState: QualityState
    /// Direct operation used by the backend.
    public let execution: Execution

    /// Creates a partial frame result.
    public init(
        frame: DicomDecodedFrame,
        decodedSourceRegion: DicomFrameRegion,
        coordinateTransform: CoordinateTransform,
        deliveredQualityLayer: Int?,
        qualityState: QualityState,
        execution: Execution
    ) {
        self.frame = frame
        self.decodedSourceRegion = decodedSourceRegion
        self.coordinateTransform = coordinateTransform
        self.deliveredQualityLayer = deliveredQualityLayer
        self.qualityState = qualityState
        self.execution = execution
    }

    /// Whether the result is safe for final display or export.
    public var isFinalQuality: Bool {
        qualityState == .final
    }
}
