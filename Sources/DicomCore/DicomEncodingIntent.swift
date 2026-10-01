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
    /// JPEG lossless (SOF3) encoding with explicit predictor, point transform and restart interval; reversible
    /// unless the point transform is non-zero.
    case jpegLossless(options: DicomJPEGLosslessEncodingOptions)
    /// JPEG-LS (ISO/IEC 14495-1) encoding with explicit NEAR, interleave mode and restart interval; reversible
    /// unless NEAR is non-zero.
    case jpegLS(options: DicomJPEGLSEncodingOptions)
    /// JPEG XL with an explicit configuration: `distance == 0` is the
    /// reversible Modular route (both JPEG XL syntaxes), `distance > 0`
    /// the irreversible VarDCT route (JPEG XL, `.112` only). Lossy coding
    /// is never implied; it has to be requested through the distance.
    case jpegXL(options: DicomJPEGXLEncodingOptions)

    var isLossy: Bool {
        switch self {
        case .reversible:
            return false
        case .irreversible, .jpegLSNearLossless:
            return true
        case .jpegLossless(let options):
            return options.pointTransform > 0
        case .jpegLS(let options):
            return options.near > 0
        case .jpegXL(let options):
            return options.distance > 0
        }
    }
}

/// JPEG-LS scan interleave (ISO/IEC 14495-1 ILV): one scan per component (ILV 0, "none"), line-interleaved (1)
/// or sample-interleaved (2). The raw values are the `dicomtool --interleave` spellings.
public enum DicomJPEGLSInterleave: String, CaseIterable, Sendable {
    case perComponent = "none"
    case line
    case sample
}

/// Options of the own JPEG-LS encoder.
public struct DicomJPEGLSEncodingOptions: Equatable, Sendable {
    /// NEAR (maximum absolute reconstruction error per sample): 0 for 1.2.840.10008.1.2.4.80, 1...255 for .81.
    public var near: Int
    /// Interleave of colour scans; single-component frames always use `.none`. `nil` keeps the default
    /// (`.sample` for colour, `.none` for grayscale).
    public var interleave: DicomJPEGLSInterleave?
    /// Restart interval in lines (DRI, 0 = none); qualified for lossless non-interleaved scans only.
    public var restartIntervalLines: Int

    public init(near: Int = 0, interleave: DicomJPEGLSInterleave? = nil, restartIntervalLines: Int = 0) {
        self.near = near
        self.interleave = interleave
        self.restartIntervalLines = restartIntervalLines
    }
}

/// Options of the own JPEG lossless (ITU-T T.81 Annex H) encoder.
/// Configuration of the own JPEG XL encoder (issue #2333).
///
/// - `distance`: Butteraugli distance of the VarDCT route, `0` for the
///   reversible Modular route; the irreversible route accepts
///   `0 < distance <= 25` (libjxl's range; `1.0` is visually lossless).
/// - `effort`: 1...9 (libjxl scale). The Modular route uses it for its
///   tree/predictor search; the VarDCT route currently runs a single
///   effort level and keeps the value for the derivation record.
/// - `gaborish`: the Gaborish deblocking pre-filter of the VarDCT route.
/// - `adaptiveQuantization`: per-block quantisation field of the VarDCT
///   route (`adaptiveQF`).
public struct DicomJPEGXLEncodingOptions: Equatable, Sendable {
    public var distance: Double
    public var effort: Int
    public var gaborish: Bool
    public var adaptiveQuantization: Bool

    public init(distance: Double = 0, effort: Int = 7, gaborish: Bool = true, adaptiveQuantization: Bool = true) {
        self.distance = distance
        self.effort = effort
        self.gaborish = gaborish
        self.adaptiveQuantization = adaptiveQuantization
    }

    /// libjxl's upper bound for the Butteraugli distance.
    public static let maximumDistance: Double = 25
}

public struct DicomJPEGLosslessEncodingOptions: Equatable, Sendable {
    /// Predictor selection value 1...7 (Table H.1); transfer syntax 1.2.840.10008.1.2.4.70 accepts 1 only.
    public var predictor: Int
    /// Point transform 0...(Bits Stored − 1): the low bits discarded before prediction. Non-zero is lossy.
    public var pointTransform: Int
    /// Restart interval in MCU rows (0 = none); the DRI value is `rows × Columns`.
    public var restartIntervalRows: Int

    public init(predictor: Int = 1, pointTransform: Int = 0, restartIntervalRows: Int = 0) {
        self.predictor = predictor
        self.pointTransform = pointTransform
        self.restartIntervalRows = restartIntervalRows
    }
}
