//
//  DicomEncodingIntent.swift
//  DicomCore
//

/// Explicit wavelet and quantization intent for compressed pixel encoding.
public enum DicomEncodingIntent: Equatable, Sendable {
    /// Reversible 5/3 wavelet transform without quantization.
    case reversible
    /// Irreversible 9/7 wavelet transform at the requested quality.
    case irreversible(quality: Double)
    /// JPEG-LS near-lossless encoding with the exact codestream NEAR value.
    case jpegLSNearLossless(near: Int)

    var isLossy: Bool {
        switch self {
        case .reversible:
            return false
        case .irreversible, .jpegLSNearLossless:
            return true
        }
    }
}
