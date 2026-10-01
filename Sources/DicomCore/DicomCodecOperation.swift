import Foundation

/// Independent operations; recognized storage formats do not imply executable pixel codecs.
public enum DicomCodecOperation: String, Codable, Hashable, Sendable {
    /// Carry existing bytes; this does not require a pixel decoder.
    case preserve
    case decode
    case encode
}
