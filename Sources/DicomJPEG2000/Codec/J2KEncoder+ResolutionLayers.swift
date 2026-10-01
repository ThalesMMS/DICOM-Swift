import Foundation

extension J2KEncoder {
    /// DICOM's bounded, single-tile resolution-detail profile. The normal encode entry retains its defaults
    /// and rate-control behavior; this entry writes the explicitly requested layer count and packet order.
    package func encodeResolutionLayers(_ image: J2KImage) async throws -> Data {
        try Task.checkCancellation()
        let config = encodingConfiguration
        guard config.tileSize.width == 0, config.tileSize.height == 0,
              config.qualityLayers >= 1, config.qualityLayers <= config.decompositionLevels + 1,
              config.progressionOrder == .lrcp || config.progressionOrder == .rlcp
                || (config.progressionOrder == .rpcl && config.qualityLayers == 1) else {
            throw J2KError.encodingError("Unsupported single-tile resolution-layer configuration")
        }
        let output = try await EncoderPipeline(config: config).encode(image, resolutionLayerCount: config.qualityLayers)
        try Task.checkCancellation()
        return output
    }
}
