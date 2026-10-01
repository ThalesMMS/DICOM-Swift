//
// J2KWaveletKernel.swift
// J2KSwift
//
// J2KWaveletKernel.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-19.
//

import Foundation

/// Wavelet kernel representation for JPEG 2000 Part 2 arbitrary wavelet support.
///
/// This type provides a complete representation of wavelet filter kernels as specified
/// in ISO/IEC 15444-2, including both analysis (forward) and synthesis (inverse) filter
/// coefficients, symmetry properties, and optional lifting scheme representation.
///
/// The kernel supports:
/// - Arbitrary analysis and synthesis filter pairs
/// - Symmetry classification for efficient boundary handling
/// - Reversible (lossless) and irreversible (lossy) filters
/// - Conversion to lifting scheme for efficient in-place computation
/// - Binary serialisation for ADS marker segments
///
/// ## Usage
///
/// ```swift
/// // Use a pre-built kernel from the library
/// let kernel = J2KWaveletKernelLibrary.cdf97
/// try kernel.validate()
///
/// // Convert to CustomFilter for DWT pipeline integration
/// let filter = kernel.toCustomFilter()
/// ```
public struct J2KWaveletKernel: Sendable, Equatable {
    // MARK: - Nested Types

    /// Symmetry classification for wavelet filters.
    ///
    /// Determines the boundary extension strategy used during wavelet transform.
    /// Symmetric filters allow symmetric (mirror) extension, while asymmetric
    /// filters require other strategies.
    public enum FilterSymmetry: Sendable, Equatable {
        /// Whole-sample symmetric filter (e.g., 5/3, 9/7).
        ///
        /// The filter coefficients are symmetric around the center tap.
        case symmetric

        /// Anti-symmetric filter.
        ///
        /// The filter coefficients are anti-symmetric: h[n] = -h[-n].
        case antiSymmetric

        /// Asymmetric filter with no symmetry property.
        case asymmetric
    }

    // MARK: - Properties

    /// Human-readable name for this wavelet kernel.
    public let name: String

    /// Analysis (forward transform) lowpass filter coefficients.
    public let analysisLowpass: [Double]

    /// Analysis (forward transform) highpass filter coefficients.
    public let analysisHighpass: [Double]

    /// Synthesis (inverse transform) lowpass filter coefficients.
    public let synthesisLowpass: [Double]

    /// Synthesis (inverse transform) highpass filter coefficients.
    public let synthesisHighpass: [Double]

    /// Symmetry type of the filter.
    public let symmetry: FilterSymmetry

    /// Whether this filter supports lossless (reversible) coding.
    public let isReversible: Bool

    /// Optional lifting scheme representation for efficient in-place computation.
    public let liftingSteps: [J2KDWT1D.LiftingStep]?

    /// Scaling factor applied to lowpass subband after transform.
    public let lowpassScale: Double

    /// Scaling factor applied to highpass subband after transform.
    public let highpassScale: Double

    // MARK: - Initialisation

    /// Creates a wavelet kernel with the specified filter coefficients and properties.
    ///
    /// - Parameters:
    ///   - name: Human-readable kernel name.
    ///   - analysisLowpass: Analysis lowpass filter coefficients.
    ///   - analysisHighpass: Analysis highpass filter coefficients.
    ///   - synthesisLowpass: Synthesis lowpass filter coefficients.
    ///   - synthesisHighpass: Synthesis highpass filter coefficients.
    ///   - symmetry: Symmetry classification of the filter.
    ///   - isReversible: Whether the filter supports lossless coding.
    ///   - liftingSteps: Optional lifting scheme steps.
    ///   - lowpassScale: Lowpass scaling factor (default: 1.0).
    ///   - highpassScale: Highpass scaling factor (default: 1.0).
    public init(
        name: String,
        analysisLowpass: [Double],
        analysisHighpass: [Double],
        synthesisLowpass: [Double],
        synthesisHighpass: [Double],
        symmetry: FilterSymmetry,
        isReversible: Bool,
        liftingSteps: [J2KDWT1D.LiftingStep]? = nil,
        lowpassScale: Double = 1.0,
        highpassScale: Double = 1.0
    ) {
        self.name = name
        self.analysisLowpass = analysisLowpass
        self.analysisHighpass = analysisHighpass
        self.synthesisLowpass = synthesisLowpass
        self.synthesisHighpass = synthesisHighpass
        self.symmetry = symmetry
        self.isReversible = isReversible
        self.liftingSteps = liftingSteps
        self.lowpassScale = lowpassScale
        self.highpassScale = highpassScale
    }

    // MARK: - Validation

    /// Validates the wavelet kernel for correctness.
    ///
    /// Checks that all filter coefficient arrays are non-empty and that the
    /// analysis and synthesis filter pairs have consistent lengths for their
    /// respective roles.
    ///
    /// - Throws: ``J2KError/invalidParameter(_:)`` if any validation check fails.
    public func validate() throws {
        guard !analysisLowpass.isEmpty else {
            throw J2KError.invalidParameter("Analysis lowpass filter coefficients must not be empty")
        }
        guard !analysisHighpass.isEmpty else {
            throw J2KError.invalidParameter("Analysis highpass filter coefficients must not be empty")
        }
        guard !synthesisLowpass.isEmpty else {
            throw J2KError.invalidParameter("Synthesis lowpass filter coefficients must not be empty")
        }
        guard !synthesisHighpass.isEmpty else {
            throw J2KError.invalidParameter("Synthesis highpass filter coefficients must not be empty")
        }

        // Analysis LP and synthesis HP must have matching lengths
        guard analysisLowpass.count == synthesisHighpass.count else {
            throw J2KError.invalidParameter(
                "Analysis lowpass length (\(analysisLowpass.count)) must match "
                    + "synthesis highpass length (\(synthesisHighpass.count))"
            )
        }

        // Analysis HP and synthesis LP must have matching lengths
        guard analysisHighpass.count == synthesisLowpass.count else {
            throw J2KError.invalidParameter(
                "Analysis highpass length (\(analysisHighpass.count)) must match "
                    + "synthesis lowpass length (\(synthesisLowpass.count))"
            )
        }

        guard lowpassScale != 0.0 else {
            throw J2KError.invalidParameter("Lowpass scale factor must not be zero")
        }
        guard highpassScale != 0.0 else {
            throw J2KError.invalidParameter("Highpass scale factor must not be zero")
        }
    }

    /// Checks whether the kernel satisfies the perfect reconstruction condition.
    ///
    /// Verifies that the product of the analysis and synthesis filter pairs
    /// approximates a delta function, within the specified tolerance. This ensures
    /// the wavelet transform can perfectly reconstruct the original signal.
    ///
    /// - Parameter tolerance: Maximum allowable deviation from perfect reconstruction
    ///   (default: 1e-10).
    /// - Returns: `true` if the kernel satisfies the PR condition within tolerance.
    public func validatePerfectReconstruction(tolerance: Double = 1e-10) -> Bool {
        // Convolve analysis lowpass with synthesis lowpass
        let convLP = convolve(analysisLowpass, synthesisLowpass)
        // Convolve analysis highpass with synthesis highpass
        let convHP = convolve(analysisHighpass, synthesisHighpass)

        // For perfect reconstruction, the sum of these convolutions should
        // produce a delta function (all zeros except center = 2)
        let maxLen = max(convLP.count, convHP.count)
        let center = maxLen / 2

        for i in 0..<maxLen {
            let lpVal = i < convLP.count ? convLP[i] : 0.0
            let hpVal = i < convHP.count ? convHP[i] : 0.0
            let sum = lpVal + hpVal
            let expected = (i == center) ? 2.0 : 0.0

            if abs(sum - expected) > tolerance {
                return false
            }
        }
        return true
    }

    // MARK: - Conversion

    /// Converts this kernel to a ``J2KDWT1D/CustomFilter`` for integration with the DWT pipeline.
    ///
    /// If lifting steps are available, they are used directly. Otherwise, a minimal
    /// custom filter is created with the kernel's scaling factors and reversibility flag.
    ///
    /// - Returns: A ``J2KDWT1D/CustomFilter`` representing this kernel.
    public func toCustomFilter() -> J2KDWT1D.CustomFilter {
        let steps = liftingSteps ?? []
        return J2KDWT1D.CustomFilter(
            steps: steps,
            lowpassScale: lowpassScale,
            highpassScale: highpassScale,
            isReversible: isReversible
        )
    }

    /// Converts this kernel to a ``J2KDWT1D/Filter`` enum case for use in DWT operations.
    ///
    /// This provides a convenient way to use arbitrary wavelet kernels with the existing
    /// DWT pipeline infrastructure.
    ///
    /// - Returns: A ``J2KDWT1D/Filter`` enum case wrapping the custom filter.
    public func toDWTFilter() -> J2KDWT1D.Filter {
        .custom(toCustomFilter())
    }

    // MARK: - Serialisation

    /// Serializes the wavelet kernel to binary data for ADS marker segment encoding.
    ///
    /// The binary format stores the kernel name, filter coefficients, symmetry type,
    /// reversibility flag, and scaling factors in a compact representation suitable
    /// for embedding in JPEG 2000 Part 2 codestreams.
    ///
    /// - Returns: Binary representation of the kernel.
    public func encode() -> Data {
        var data = Data()

        // Encode name as length-prefixed UTF-8
        let nameData = Data(name.utf8)
        var nameLength = UInt16(nameData.count)
        data.append(Data(bytes: &nameLength, count: 2))
        data.append(nameData)

        // Encode filter coefficients
        appendCoefficients(analysisLowpass, to: &data)
        appendCoefficients(analysisHighpass, to: &data)
        appendCoefficients(synthesisLowpass, to: &data)
        appendCoefficients(synthesisHighpass, to: &data)

        // Encode symmetry (1 byte)
        let symmetryByte: UInt8
        switch symmetry {
        case .symmetric: symmetryByte = 0
        case .antiSymmetric: symmetryByte = 1
        case .asymmetric: symmetryByte = 2
        }
        data.append(symmetryByte)

        // Encode reversibility flag (1 byte)
        data.append(isReversible ? 1 : 0)

        // Encode scaling factors (16 bytes)
        var lps = lowpassScale
        var hps = highpassScale
        data.append(Data(bytes: &lps, count: 8))
        data.append(Data(bytes: &hps, count: 8))

        return data
    }

    /// Deserializes a wavelet kernel from binary data.
    ///
    /// Reads the kernel specification from a binary representation previously
    /// created by ``encode()``.
    ///
    /// - Parameter data: Binary data containing the serialised kernel.
    /// - Returns: The deserialised wavelet kernel.
    /// - Throws: ``J2KError/invalidData(_:)`` if the data is malformed or truncated.
    public static func decode(from data: Data) throws -> J2KWaveletKernel {
        var offset = 0

        // Decode name
        guard offset + 2 <= data.count else {
            throw J2KError.invalidData("Insufficient data for kernel name length")
        }
        let nameLength = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        offset += 2

        guard offset + nameLength <= data.count else {
            throw J2KError.invalidData("Insufficient data for kernel name")
        }
        guard let name = String(data: data[offset..<offset + nameLength], encoding: .utf8) else {
            throw J2KError.invalidData("Invalid UTF-8 in kernel name")
        }
        offset += nameLength

        // Decode filter coefficients
        let (analysisLP, o1) = try readCoefficients(from: data, at: offset)
        let (analysisHP, o2) = try readCoefficients(from: data, at: o1)
        let (synthesisLP, o3) = try readCoefficients(from: data, at: o2)
        let (synthesisHP, o4) = try readCoefficients(from: data, at: o3)
        offset = o4

        // Decode symmetry
        guard offset + 1 <= data.count else {
            throw J2KError.invalidData("Insufficient data for symmetry type")
        }
        let symmetry: FilterSymmetry
        switch data[offset] {
        case 0: symmetry = .symmetric
        case 1: symmetry = .antiSymmetric
        case 2: symmetry = .asymmetric
        default:
            throw J2KError.invalidData("Unknown symmetry type: \(data[offset])")
        }
        offset += 1

        // Decode reversibility
        guard offset + 1 <= data.count else {
            throw J2KError.invalidData("Insufficient data for reversibility flag")
        }
        let isReversible = data[offset] != 0
        offset += 1

        // Decode scaling factors
        guard offset + 16 <= data.count else {
            throw J2KError.invalidData("Insufficient data for scaling factors")
        }
        let lowpassScale = data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        offset += 8
        let highpassScale = data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: Double.self) }

        return J2KWaveletKernel(
            name: name,
            analysisLowpass: analysisLP,
            analysisHighpass: analysisHP,
            synthesisLowpass: synthesisLP,
            synthesisHighpass: synthesisHP,
            symmetry: symmetry,
            isReversible: isReversible,
            lowpassScale: lowpassScale,
            highpassScale: highpassScale
        )
    }

    // MARK: - Private Helpers

    /// Convolves two sequences.
    private func convolve(_ a: [Double], _ b: [Double]) -> [Double] {
        guard !a.isEmpty && !b.isEmpty else { return [] }
        let resultLength = a.count + b.count - 1
        var result = [Double](repeating: 0.0, count: resultLength)
        for i in 0..<a.count {
            for j in 0..<b.count {
                result[i + j] += a[i] * b[j]
            }
        }
        return result
    }

    /// Appends coefficient array to data as count (UInt16) followed by Double values.
    private func appendCoefficients(_ coefficients: [Double], to data: inout Data) {
        var count = UInt16(coefficients.count)
        data.append(Data(bytes: &count, count: 2))
        for var coeff in coefficients {
            data.append(Data(bytes: &coeff, count: 8))
        }
    }

    /// Reads a coefficient array from data at the given offset.
    private static func readCoefficients(
        from data: Data, at offset: Int
    ) throws -> ([Double], Int) {
        var pos = offset
        guard pos + 2 <= data.count else {
            throw J2KError.invalidData("Insufficient data for coefficient count")
        }
        let count = Int(data[pos]) | (Int(data[pos + 1]) << 8)
        pos += 2

        guard pos + count * 8 <= data.count else {
            throw J2KError.invalidData("Insufficient data for \(count) coefficients")
        }
        var coefficients = [Double]()
        coefficients.reserveCapacity(count)
        for _ in 0..<count {
            let value = data[pos..<pos + 8].withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
            coefficients.append(value)
            pos += 8
        }
        return (coefficients, pos)
    }
}

// MARK: - Wavelet Kernel Library

/// Static library of pre-built wavelet kernels for JPEG 2000.
///
/// Provides standard wavelet kernels including those required by JPEG 2000 Part 1
/// and additional kernels commonly used with Part 2 extensions. All kernels are
/// validated and ready for use.
///
/// ## Usage
///
/// ```swift
/// let kernel = J2KWaveletKernelLibrary.cdf97
/// let filter = kernel.toCustomFilter()
/// ```
public enum J2KWaveletKernelLibrary: Sendable {
    /// Haar wavelet — the simplest orthogonal wavelet.
    ///
    /// Uses a 2-tap filter with coefficients [1/√2, 1/√2]. The Haar wavelet
    /// provides a simple averaging and differencing decomposition.
    public static let haar = J2KWaveletKernel(
        name: "Haar",
        analysisLowpass: [1.0 / sqrt(2.0), 1.0 / sqrt(2.0)],
        analysisHighpass: [-1.0 / sqrt(2.0), 1.0 / sqrt(2.0)],
        synthesisLowpass: [1.0 / sqrt(2.0), 1.0 / sqrt(2.0)],
        synthesisHighpass: [1.0 / sqrt(2.0), -1.0 / sqrt(2.0)],
        symmetry: .symmetric,
        isReversible: true,
        liftingSteps: [
            J2KDWT1D.LiftingStep(coefficients: [-1.0], isPredict: true),
            J2KDWT1D.LiftingStep(coefficients: [0.5], isPredict: false),
        ],
        lowpassScale: sqrt(2.0),
        highpassScale: 1.0 / sqrt(2.0)
    )

    /// Le Gall 5/3 reversible wavelet from JPEG 2000 Part 1.
    ///
    /// This filter is used for lossless compression in JPEG 2000. It uses integer
    /// arithmetic via the lifting scheme and provides perfect reconstruction.
    /// Analysis: 5-tap lowpass, 3-tap highpass.
    public static let leGall53 = J2KWaveletKernel(
        name: "Le Gall 5/3",
        analysisLowpass: [-1.0 / 8.0, 2.0 / 8.0, 6.0 / 8.0, 2.0 / 8.0, -1.0 / 8.0],
        analysisHighpass: [-1.0 / 2.0, 1.0, -1.0 / 2.0],
        synthesisLowpass: [1.0 / 2.0, 1.0, 1.0 / 2.0],
        synthesisHighpass: [-1.0 / 8.0, -2.0 / 8.0, 6.0 / 8.0, -2.0 / 8.0, -1.0 / 8.0],
        symmetry: .symmetric,
        isReversible: true,
        liftingSteps: [
            J2KDWT1D.LiftingStep(coefficients: [-0.5], isPredict: true),
            J2KDWT1D.LiftingStep(coefficients: [0.25], isPredict: false),
        ]
    )

    /// CDF 9/7 irreversible wavelet from JPEG 2000 Part 1.
    ///
    /// The Cohen-Daubechies-Feauveau 9/7 biorthogonal wavelet is the standard filter
    /// for lossy compression in JPEG 2000. It provides excellent energy compaction
    /// and is defined in ISO/IEC 15444-1 Table F.2.
    public static let cdf97: J2KWaveletKernel = {
        // ISO/IEC 15444-1 Table F.2 analysis lowpass (9-tap)
        let aLP: [Double] = [
            0.026748757411,
            -0.016864118443,
            -0.078223266529,
            0.266864118443,
            0.602949018236,
            0.266864118443,
            -0.078223266529,
            -0.016864118443,
            0.026748757411,
        ]
        // ISO/IEC 15444-1 Table F.2 analysis highpass (7-tap)
        let aHP: [Double] = [
            0.091271763114,
            -0.057543526229,
            -0.591271763114,
            1.11508705,
            -0.591271763114,
            -0.057543526229,
            0.091271763114,
        ]
        // Synthesis filters are the time-reversed alternating-sign variants
        let sLP: [Double] = [
            -0.091271763114,
            -0.057543526229,
            0.591271763114,
            1.11508705,
            0.591271763114,
            -0.057543526229,
            -0.091271763114,
        ]
        let sHP: [Double] = [
            0.026748757411,
            0.016864118443,
            -0.078223266529,
            -0.266864118443,
            0.602949018236,
            -0.266864118443,
            -0.078223266529,
            0.016864118443,
            0.026748757411,
        ]
        return J2KWaveletKernel(
            name: "CDF 9/7",
            analysisLowpass: aLP,
            analysisHighpass: aHP,
            synthesisLowpass: sLP,
            synthesisHighpass: sHP,
            symmetry: .symmetric,
            isReversible: false,
            liftingSteps: [
                J2KDWT1D.LiftingStep(coefficients: [-1.586134342], isPredict: true),
                J2KDWT1D.LiftingStep(coefficients: [-0.05298011854], isPredict: false),
                J2KDWT1D.LiftingStep(coefficients: [0.8829110762], isPredict: true),
                J2KDWT1D.LiftingStep(coefficients: [0.4435068522], isPredict: false),
            ],
            lowpassScale: 1.0 / 1.230174105,
            highpassScale: 1.230174105
        )
    }()

    /// Daubechies-4 wavelet with 4-tap filter.
    ///
    /// The DB4 wavelet provides two vanishing moments and is suitable for
    /// signals with piecewise-linear trends. Coefficients are orthonormal.
    public static let daubechies4: J2KWaveletKernel = {
        // DB4 scaling function coefficients (analysis lowpass)
        let h0 = (1.0 + sqrt(3.0)) / (4.0 * sqrt(2.0))
        let h1 = (3.0 + sqrt(3.0)) / (4.0 * sqrt(2.0))
        let h2 = (3.0 - sqrt(3.0)) / (4.0 * sqrt(2.0))
        let h3 = (1.0 - sqrt(3.0)) / (4.0 * sqrt(2.0))
        let aLP = [h0, h1, h2, h3]
        // Analysis highpass via alternating flip
        let aHP = [h3, -h2, h1, -h0]
        // Synthesis filters are time-reversed
        let sLP = [h3, h2, h1, h0]
        let sHP = [-h0, h1, -h2, h3]
        return J2KWaveletKernel(
            name: "Daubechies-4",
            analysisLowpass: aLP,
            analysisHighpass: aHP,
            synthesisLowpass: sLP,
            synthesisHighpass: sHP,
            symmetry: .asymmetric,
            isReversible: false
        )
    }()

    /// Daubechies-6 wavelet with 6-tap filter.
    ///
    /// The DB6 wavelet provides three vanishing moments and better frequency
    /// selectivity than DB4, at the cost of longer filter support.
    public static let daubechies6: J2KWaveletKernel = makeDaubechies6()

    private static func makeDaubechies6() -> J2KWaveletKernel {
        // DB6 scaling function coefficients
        let coeffs: [Double] = [
            0.33267055295008261,
            0.80689150931109257,
            0.45987750211849154,
            -0.13501102001025458,
            -0.08544127388202666,
            0.03522629188570953,
        ]
        let n = coeffs.count
        // Analysis highpass via alternating flip: g[n] = (-1)^n * h[N-1-n]
        var aHP = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            aHP[i] = (i.isMultiple(of: 2) ? 1.0 : -1.0) * coeffs[n - 1 - i]
        }
        // Synthesis lowpass is time-reversed analysis lowpass
        let sLP = Array(coeffs.reversed())
        // Synthesis highpass via alternating flip
        var sHP = [Double](repeating: 0.0, count: n)
        for i in 0..<n {
            sHP[i] = (i.isMultiple(of: 2) ? -1.0 : 1.0) * coeffs[i]
        }
        return J2KWaveletKernel(
            name: "Daubechies-6",
            analysisLowpass: coeffs,
            analysisHighpass: aHP,
            synthesisLowpass: sLP,
            synthesisHighpass: sHP,
            symmetry: .asymmetric,
            isReversible: false
        )
    }

    /// CDF 5/3 wavelet with proper normalisation factors.
    ///
    /// This is equivalent to ``leGall53`` but includes explicit scaling factors
    /// for normalised subband energies. Suitable for use with quantization.
    public static let cdf53 = J2KWaveletKernel(
        name: "CDF 5/3",
        analysisLowpass: [-1.0 / 8.0, 2.0 / 8.0, 6.0 / 8.0, 2.0 / 8.0, -1.0 / 8.0],
        analysisHighpass: [-1.0 / 2.0, 1.0, -1.0 / 2.0],
        synthesisLowpass: [1.0 / 2.0, 1.0, 1.0 / 2.0],
        synthesisHighpass: [-1.0 / 8.0, -2.0 / 8.0, 6.0 / 8.0, -2.0 / 8.0, -1.0 / 8.0],
        symmetry: .symmetric,
        isReversible: true,
        liftingSteps: [
            J2KDWT1D.LiftingStep(coefficients: [-0.5], isPredict: true),
            J2KDWT1D.LiftingStep(coefficients: [0.25], isPredict: false),
        ],
        lowpassScale: 1.0,
        highpassScale: 1.0
    )

    /// All available pre-built wavelet kernels.
    public static let allKernels: [J2KWaveletKernel] = [
        haar, leGall53, cdf97, daubechies4, daubechies6, cdf53,
    ]
}
