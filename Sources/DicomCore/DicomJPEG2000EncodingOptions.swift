import Foundation

/// Single-tile encoding with cumulative layers that add complete wavelet resolutions.
/// Layer `l` includes resolutions whose `resolution * qualityLayers / (decompositionLevels + 1) <= l`.
/// These are resolution-detail layers, not bitrate targets or code-block pass truncation.
/// Omitting these options preserves the existing encoder output. Supplying them requests re-encoding,
/// including when the source and destination transfer syntax UIDs are equal.
public struct DicomJPEG2000EncodingOptions: Equatable, Sendable {
    public let qualityLayers: Int
    /// Nil selects the existing dimension-bounded default; explicit values are never clamped.
    public let decompositionLevels: Int?
    /// Nil selects LRCP, or RPCL for the HTJ2K Lossless RPCL syntax (.202).
    public let progression: DicomJPEG2000Progression?

    public init(qualityLayers: Int = 1, decompositionLevels: Int? = nil,
                progression: DicomJPEG2000Progression? = nil) {
        self.qualityLayers = qualityLayers
        self.decompositionLevels = decompositionLevels
        self.progression = progression
    }

    func resolved(descriptor: DicomCompressedFrameDescriptor, intent: DicomEncodingIntent) throws -> Self {
        func refuse(_ reason: String) -> DicomJPEG2000EncodingError { .unsupportedConfiguration(reason: reason) }
        guard let syntax = DicomTransferSyntax(uid: descriptor.transferSyntaxUID),
              [.jpeg2000Lossless, .jpeg2000, .htj2kLossless, .htj2kLosslessRPCL, .htj2k].contains(syntax) else {
            throw refuse("options require a Part 1 or HTJ2K frame transfer syntax (.90/.91/.201/.202/.203)")
        }
        switch intent {
        case .reversible: break
        case .irreversible(let quality):
            guard [.jpeg2000, .htj2k].contains(syntax), quality.isFinite, quality > 0, quality < 1 else {
                throw refuse("irreversible quality must be between zero and one and target .91 or .203")
            }
        default: throw refuse("only reversible or irreversible JPEG 2000 intent accepts these options")
        }
        guard descriptor.rows > 0, descriptor.columns > 0 else { throw refuse("image dimensions must be positive") }
        guard descriptor.rows <= 32_768, descriptor.columns <= 32_768 else {
            throw refuse("the single-precinct profile requires image sides at most 32768 samples")
        }
        // The current DWT keeps at least two samples on the shortest side and supports at most ten levels.
        let maximum = min(10, max(0, Int(log2(Double(min(descriptor.rows, descriptor.columns)))) - 1))
        let rpcl = syntax == .htj2kLosslessRPCL
        let levels = decompositionLevels ?? (rpcl
            ? min(maximum, DicomHTJ2KProfile.rpclDecompositionLevels(rows: descriptor.rows, columns: descriptor.columns))
            : min(5, maximum))
        guard levels >= 0, levels <= maximum else { throw refuse("decomposition levels must be in 0...\(maximum) for this image") }
        guard qualityLayers >= 1, qualityLayers <= levels + 1 else {
            throw refuse("resolution-detail layers must be in 1...\(levels + 1) for \(levels) decompositions")
        }
        let order = progression ?? (rpcl ? .rpcl : .lrcp)
        if rpcl {
            guard order == .rpcl, qualityLayers == 1,
                  DicomHTJ2KProfile.hasThumbnailResolution(width: descriptor.columns, height: descriptor.rows,
                                                         decompositionLevels: levels) else {
                throw refuse(".202 encoding uses single-layer RPCL and requires a base resolution with width or height at most 64")
            }
        } else {
            guard order == .lrcp || order == .rlcp else { throw refuse("this profile supports LRCP or RLCP only") }
        }
        return Self(qualityLayers: qualityLayers, decompositionLevels: levels, progression: order)
    }
}
