import Foundation

/// One encoded value with the Waveform Sample Interpretation that gives it meaning.
public struct DicomWaveformSampleValue: Equatable, Sendable {
    public let rawValue: Int
    public let interpretation: DicomWaveformSampleInterpretation

    public init(rawValue: Int, interpretation: DicomWaveformSampleInterpretation) throws {
        guard interpretation.contains(rawValue) else {
            throw DicomWaveformError.sampleOutOfRange(value: rawValue, interpretation: interpretation.rawValue)
        }
        self.rawValue = rawValue
        self.interpretation = interpretation
    }
}

extension DicomWaveformSampleInterpretation {
    /// G.711 reconstruction levels scaled to signed PCM16 (mu-law ×4, A-law ×8).
    /// DICOM C.10.9.1.5 omits A-law's alternate-bit transmission inversion (XOR 0x55).
    /// Mu-law retains the complemented character code specified by G.711 Table 2.
    /// Returns nil for non-companded interpretations or an invalid encoded byte.
    public func linearPCM16(from value: Int) -> Int16? {
        guard (0...255).contains(value) else { return nil }
        switch self {
        case .muLaw8:
            let code = value ^ 0xFF
            let magnitude = (((code & 15) << 3) + 132) << ((code >> 4) & 7)
            return Int16(code & 128 == 0 ? magnitude - 132 : 132 - magnitude)
        case .aLaw8:
            let segment = (value >> 4) & 7
            let magnitude = segment == 0 ? (value & 15) * 16 + 8
                : ((value & 15) * 16 + 264) << (segment - 1)
            return Int16(value & 128 == 0 ? -magnitude : magnitude)
        default:
            return nil
        }
    }
}
