//
// J2KOptimizedWaveletKernel.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-21.
//

import Foundation
import Synchronization

// MARK: - Pre-computed Filter Properties

/// Pre-computed filter properties for optimised wavelet kernel operations.
///
/// Caches normalisation factors, energy gains, and filter metadata derived from
/// a ``J2KWaveletKernel`` to avoid repeated computation during multi-level
/// wavelet transforms. All properties are computed once at initialisation time.
///
/// ## Usage
///
/// ```swift
/// let kernel = J2KWaveletKernelLibrary.cdf97
/// let properties = J2KFilterProperties(kernel: kernel)
/// print(properties.analysisLowpassDCGain) // DC gain of analysis lowpass
/// ```
public struct J2KFilterProperties: Sendable, Equatable {
    /// DC gain of the analysis lowpass filter (sum of coefficients).
    public let analysisLowpassDCGain: Double

    /// DC gain of the analysis highpass filter (sum of coefficients).
    public let analysisHighpassDCGain: Double

    /// DC gain of the synthesis lowpass filter (sum of coefficients).
    public let synthesisLowpassDCGain: Double

    /// DC gain of the synthesis highpass filter (sum of coefficients).
    public let synthesisHighpassDCGain: Double

    /// L2 norm (energy) of the analysis lowpass filter.
    public let analysisLowpassNorm: Double

    /// L2 norm (energy) of the analysis highpass filter.
    public let analysisHighpassNorm: Double

    /// L2 norm (energy) of the synthesis lowpass filter.
    public let synthesisLowpassNorm: Double

    /// L2 norm (energy) of the synthesis highpass filter.
    public let synthesisHighpassNorm: Double

    /// Pre-computed normalisation factor for the lowpass subband.
    ///
    /// Equals `1.0 / analysisLowpassNorm`, used to normalise subband energies
    /// for quantisation.
    public let lowpassNormalisationFactor: Double

    /// Pre-computed normalisation factor for the highpass subband.
    ///
    /// Equals `1.0 / analysisHighpassNorm`, used to normalise subband energies
    /// for quantisation.
    public let highpassNormalisationFactor: Double

    /// Maximum filter length across all four filter banks.
    public let maxFilterLength: Int

    /// Centre tap index for the analysis lowpass filter.
    public let analysisLowpassCenter: Int

    /// Centre tap index for the analysis highpass filter.
    public let analysisHighpassCenter: Int

    /// Whether the kernel has unit DC gain on the analysis lowpass filter.
    public let hasUnitDCGain: Bool

    /// Creates pre-computed filter properties from a wavelet kernel.
    ///
    /// - Parameter kernel: The wavelet kernel to compute properties for.
    public init(kernel: J2KWaveletKernel) {
        self.analysisLowpassDCGain = kernel.analysisLowpass.reduce(0, +)
        self.analysisHighpassDCGain = kernel.analysisHighpass.reduce(0, +)
        self.synthesisLowpassDCGain = kernel.synthesisLowpass.reduce(0, +)
        self.synthesisHighpassDCGain = kernel.synthesisHighpass.reduce(0, +)

        let alpNorm = sqrt(kernel.analysisLowpass.reduce(0) { $0 + $1 * $1 })
        let ahpNorm = sqrt(kernel.analysisHighpass.reduce(0) { $0 + $1 * $1 })
        let slpNorm = sqrt(kernel.synthesisLowpass.reduce(0) { $0 + $1 * $1 })
        let shpNorm = sqrt(kernel.synthesisHighpass.reduce(0) { $0 + $1 * $1 })

        self.analysisLowpassNorm = alpNorm
        self.analysisHighpassNorm = ahpNorm
        self.synthesisLowpassNorm = slpNorm
        self.synthesisHighpassNorm = shpNorm

        self.lowpassNormalisationFactor = alpNorm > 0 ? 1.0 / alpNorm : 1.0
        self.highpassNormalisationFactor = ahpNorm > 0 ? 1.0 / ahpNorm : 1.0

        self.maxFilterLength = max(
            kernel.analysisLowpass.count,
            kernel.analysisHighpass.count,
            kernel.synthesisLowpass.count,
            kernel.synthesisHighpass.count
        )

        self.analysisLowpassCenter = kernel.analysisLowpass.count / 2
        self.analysisHighpassCenter = kernel.analysisHighpass.count / 2

        self.hasUnitDCGain = abs(analysisLowpassDCGain - 1.0) < 1e-6
    }
}

// MARK: - Fast-Path Kernel Recognition

/// Recognised standard kernel types for fast-path dispatch.
///
/// When a ``J2KWaveletKernel`` matches a known standard filter, the optimised
/// wavelet engine can dispatch to dedicated lifting-based implementations
/// instead of generic convolution.
public enum J2KKnownKernelType: Sendable, Equatable {
    /// Le Gall 5/3 reversible filter (JPEG 2000 Part 1 lossless).
    case leGall53

    /// CDF 9/7 irreversible filter (JPEG 2000 Part 1 lossy).
    case cdf97

    /// Haar wavelet (2-tap orthogonal).
    case haar

    /// Unrecognised custom kernel requiring generic convolution.
    case custom
}

/// Identifies whether a wavelet kernel matches a known standard filter type.
///
/// Compares the kernel's filter coefficients against known standard kernels
/// to enable fast-path dispatch to optimised implementations.
///
/// - Parameter kernel: The kernel to identify.
/// - Returns: The recognised kernel type, or `.custom` if unrecognised.
public func identifyKernelType(_ kernel: J2KWaveletKernel) -> J2KKnownKernelType {
    // Check lifting steps for fast identification
    if let steps = kernel.liftingSteps {
        // Le Gall 5/3: 2 steps, [-0.5] predict + [0.25] update
        if steps.count == 2,
           kernel.isReversible,
           steps[0].isPredict,
           steps[0].coefficients.count == 1,
           abs(steps[0].coefficients[0] - (-0.5)) < 1e-10,
           !steps[1].isPredict,
           steps[1].coefficients.count == 1,
           abs(steps[1].coefficients[0] - 0.25) < 1e-10 {
            return .leGall53
        }

        // CDF 9/7: 4 steps with known coefficients
        if steps.count == 4,
           !kernel.isReversible,
           steps[0].isPredict,
           steps[0].coefficients.count == 1,
           abs(steps[0].coefficients[0] - (-1.586134342)) < 1e-6 {
            return .cdf97
        }

        // Haar: 2 steps, [-1.0] predict + [0.5] update
        if steps.count == 2,
           kernel.isReversible,
           steps[0].isPredict,
           steps[0].coefficients.count == 1,
           abs(steps[0].coefficients[0] - (-1.0)) < 1e-10,
           !steps[1].isPredict,
           steps[1].coefficients.count == 1,
           abs(steps[1].coefficients[0] - 0.5) < 1e-10 {
            return .haar
        }
    }

    // Fallback: check coefficient counts
    if kernel.analysisLowpass.count == 5,
       kernel.analysisHighpass.count == 3,
       kernel.isReversible {
        return .leGall53
    }

    if kernel.analysisLowpass.count == 9,
       kernel.analysisHighpass.count == 7,
       !kernel.isReversible {
        return .cdf97
    }

    if kernel.analysisLowpass.count == 2,
       kernel.analysisHighpass.count == 2 {
        return .haar
    }

    return .custom
}

// MARK: - SIMD-Optimized Convolution

/// SIMD-optimised 1D convolution for wavelet filter application.
///
/// Uses SIMD vector operations to accelerate the inner convolution loop
/// for arbitrary wavelet filters. The implementation processes multiple
/// output samples simultaneously using SIMD4<Double> operations.
///
/// ## Performance
///
/// For filters with 4+ taps, the SIMD path provides significant speedup
/// over scalar convolution by processing 4 filter taps per SIMD operation.
///
/// - Parameters:
///   - signal: Input signal to convolve.
///   - filter: Filter kernel coefficients.
///   - signalExtender: Closure providing boundary-extended signal values for
///     out-of-bounds indices.
///   - outputCount: Number of output samples to produce.
///   - stride: Downsampling stride (2 for standard wavelet transform).
///   - offset: Starting offset for the first output sample.
///   - filterCenter: Centre tap index of the filter.
/// - Returns: Array of convolved and downsampled output values.
public func simdConvolve1D(
    signal: [Double],
    filter: [Double],
    signalExtender: (Int) -> Double,
    outputCount: Int,
    stride: Int,
    offset: Int,
    filterCenter: Int
) -> [Double] {
    let filterCount = filter.count
    var output = [Double](repeating: 0.0, count: outputCount)

    // SIMD4 path: process 4 filter taps at a time
    let simd4Count = filterCount / 4
    let scalarRemainder = filterCount % 4

    for i in 0..<outputCount {
        let baseIdx = stride * i + offset - filterCenter
        var sum = 0.0

        // Vectorised inner loop
        var k = 0
        for _ in 0..<simd4Count {
            let f = SIMD4<Double>(
                filter[k], filter[k + 1], filter[k + 2], filter[k + 3]
            )
            let s = SIMD4<Double>(
                signalExtender(baseIdx + k),
                signalExtender(baseIdx + k + 1),
                signalExtender(baseIdx + k + 2),
                signalExtender(baseIdx + k + 3)
            )
            sum += (f * s).sum()
            k += 4
        }

        // Scalar tail
        for j in 0..<scalarRemainder {
            sum += filter[k + j] * signalExtender(baseIdx + k + j)
        }

        output[i] = sum
    }

    return output
}

// MARK: - Kernel State Cache

/// Thread-safe cache for pre-computed wavelet kernel state.
///
/// Stores ``J2KFilterProperties``, identified kernel types, and pre-built
/// ``J2KDWT1D/CustomFilter`` instances to avoid repeated computation when
/// the same kernel is used for multiple tiles or decomposition levels.
///
/// The cache uses the kernel name as a key. Thread safety is provided by
/// the Sendable requirement of the stored value type and immutability.
///
/// ## Usage
///
/// ```swift
/// let cache = J2KWaveletKernelCache()
/// let kernel = J2KWaveletKernelLibrary.cdf97
/// let state = cache.getOrCompute(for: kernel)
/// print(state.kernelType)       // .cdf97
/// print(state.properties)       // Pre-computed filter properties
/// ```
public final class J2KWaveletKernelCache: @unchecked Sendable {
    /// Cached state for a single wavelet kernel.
    public struct CachedKernelState: Sendable {
        /// Pre-computed filter properties.
        public let properties: J2KFilterProperties

        /// Identified kernel type for fast-path dispatch.
        public let kernelType: J2KKnownKernelType

        /// Pre-built custom filter for DWT pipeline integration.
        public let customFilter: J2KDWT1D.CustomFilter

        /// Pre-built DWT filter enum for pipeline integration.
        public let dwtFilter: J2KDWT1D.Filter
    }

    private let _state: Mutex<[String: CachedKernelState]>

    /// Creates an empty kernel cache.
    public init() {
        self._state = Mutex([:])
    }

    /// Retrieves or computes cached state for the specified kernel.
    ///
    /// If the kernel has been seen before (matched by name), the cached state
    /// is returned immediately. Otherwise, properties are computed, the kernel
    /// type is identified, and the result is stored for future lookups.
    ///
    /// - Parameter kernel: The wavelet kernel to look up or cache.
    /// - Returns: The cached or newly computed kernel state.
    public func getOrCompute(for kernel: J2KWaveletKernel) -> CachedKernelState {
        _state.withLock { cache in

        if let cached = cache[kernel.name] {
            return cached
        }

        let properties = J2KFilterProperties(kernel: kernel)
        let kernelType = identifyKernelType(kernel)
        let customFilter = kernel.toCustomFilter()
        let dwtFilter = kernel.toDWTFilter()

        let state = CachedKernelState(
            properties: properties,
            kernelType: kernelType,
            customFilter: customFilter,
            dwtFilter: dwtFilter
        )

        cache[kernel.name] = state
        return state

        }
    }

    /// Removes all cached kernel states.
    public func clear() {
        _state.withLock { cache in
        cache.removeAll()
        }
    }

    /// The number of cached kernel states.
    public var count: Int {
        _state.withLock { cache in
        cache.count
        }
    }
}

// MARK: - Optimised Wavelet Transform Engine

/// Optimised wavelet transform engine with fast paths and caching.
///
/// Wraps ``J2KArbitraryWaveletTransform`` with performance optimisations:
/// - **Fast paths**: Recognised standard kernels (5/3, 9/7, Haar) are dispatched
///   to dedicated lifting-based implementations via ``J2KDWT1D``.
/// - **SIMD convolution**: Custom kernels with 4+ taps use SIMD-vectorised
///   inner loops for faster convolution.
/// - **Cached state**: Pre-computed filter properties and kernel identification
///   are cached to avoid repeated computation.
///
/// ## Usage
///
/// ```swift
/// let kernel = J2KWaveletKernelLibrary.cdf97
/// let engine = J2KOptimisedWaveletEngine(kernel: kernel)
///
/// let signal: [Double] = [1, 2, 3, 4, 5, 6, 7, 8]
/// let (low, high) = try engine.forwardTransform1D(signal: signal)
/// let reconstructed = try engine.inverseTransform1D(lowpass: low, highpass: high)
/// ```
public struct J2KOptimisedWaveletEngine: Sendable {
    /// The wavelet kernel used for transforms.
    public let kernel: J2KWaveletKernel

    /// Pre-computed filter properties.
    public let properties: J2KFilterProperties

    /// Identified kernel type for fast-path dispatch.
    public let kernelType: J2KKnownKernelType

    /// Boundary extension mode.
    public let boundaryExtension: J2KDWT1D.BoundaryExtension

    /// Creates an optimised wavelet engine for the specified kernel.
    ///
    /// Pre-computes filter properties and identifies the kernel type at
    /// initialisation time for optimal runtime performance.
    ///
    /// - Parameters:
    ///   - kernel: The wavelet kernel to use for transforms.
    ///   - boundaryExtension: Boundary handling mode (default: symmetric).
    public init(
        kernel: J2KWaveletKernel,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) {
        self.kernel = kernel
        self.boundaryExtension = boundaryExtension
        self.properties = J2KFilterProperties(kernel: kernel)
        self.kernelType = identifyKernelType(kernel)
    }

    /// Creates an optimised wavelet engine from a cached kernel state.
    ///
    /// - Parameters:
    ///   - kernel: The wavelet kernel.
    ///   - cachedState: Pre-computed cached state from ``J2KWaveletKernelCache``.
    ///   - boundaryExtension: Boundary handling mode (default: symmetric).
    public init(
        kernel: J2KWaveletKernel,
        cachedState: J2KWaveletKernelCache.CachedKernelState,
        boundaryExtension: J2KDWT1D.BoundaryExtension = .symmetric
    ) {
        self.kernel = kernel
        self.boundaryExtension = boundaryExtension
        self.properties = cachedState.properties
        self.kernelType = cachedState.kernelType
    }

    // MARK: - Forward Transform

    /// Performs an optimised 1D forward wavelet transform.
    ///
    /// Dispatches to the fastest available implementation based on the
    /// identified kernel type:
    /// - `.leGall53` and `.cdf97`: Uses ``J2KDWT1D`` lifting-based transforms.
    /// - `.haar` and `.custom`: Uses SIMD-optimised convolution via
    ///   ``J2KArbitraryWaveletTransform``.
    ///
    /// - Parameter signal: Input signal to transform. Must have at least 2 elements.
    /// - Returns: A tuple containing (lowpass, highpass) subbands.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if the signal is too short.
    public func forwardTransform1D(
        signal: [Double]
    ) throws -> (lowpass: [Double], highpass: [Double]) {
        switch kernelType {
        case .leGall53:
            return try J2KDWT1D.forwardTransformCustom(
                signal: signal,
                filter: .leGall53,
                boundaryExtension: boundaryExtension
            )

        case .cdf97:
            return try J2KDWT1D.forwardTransform97(
                signal: signal,
                boundaryExtension: boundaryExtension
            )

        case .haar, .custom:
            return try forwardTransformSIMD(signal: signal)
        }
    }

    /// Performs an optimised 1D inverse wavelet transform.
    ///
    /// Dispatches to the fastest available implementation based on the
    /// identified kernel type.
    ///
    /// - Parameters:
    ///   - lowpass: Lowpass (approximation) coefficients.
    ///   - highpass: Highpass (detail) coefficients.
    /// - Returns: Reconstructed signal.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if subbands are empty or incompatible.
    public func inverseTransform1D(
        lowpass: [Double],
        highpass: [Double]
    ) throws -> [Double] {
        switch kernelType {
        case .leGall53:
            return try J2KDWT1D.inverseTransformCustom(
                lowpass: lowpass,
                highpass: highpass,
                filter: .leGall53,
                boundaryExtension: boundaryExtension
            )

        case .cdf97:
            return try J2KDWT1D.inverseTransform97(
                lowpass: lowpass,
                highpass: highpass,
                boundaryExtension: boundaryExtension
            )

        case .haar, .custom:
            let transform = J2KArbitraryWaveletTransform(
                kernel: kernel,
                boundaryExtension: boundaryExtension
            )
            return try transform.inverseTransform1D(
                lowpass: lowpass,
                highpass: highpass
            )
        }
    }

    // MARK: - SIMD-Optimised Convolution Path

    /// Forward transform using SIMD-optimised convolution for custom kernels.
    private func forwardTransformSIMD(
        signal: [Double]
    ) throws -> (lowpass: [Double], highpass: [Double]) {
        guard signal.count >= 2 else {
            throw J2KError.invalidParameter(
                "Signal must have at least 2 elements, got \(signal.count)"
            )
        }

        let n = signal.count
        let lowpassSize = (n + 1) / 2
        let highpassSize = n / 2

        let lpFilter = kernel.analysisLowpass
        let hpFilter = kernel.analysisHighpass

        let signalExtender: (Int) -> Double = { index in
            self.extendedValue(signal, index: index)
        }

        let lowpass = simdConvolve1D(
            signal: signal,
            filter: lpFilter,
            signalExtender: signalExtender,
            outputCount: lowpassSize,
            stride: 2,
            offset: 0,
            filterCenter: self.properties.analysisLowpassCenter
        )

        let highpass = simdConvolve1D(
            signal: signal,
            filter: hpFilter,
            signalExtender: { index in
                self.extendedValue(signal, index: index)
            },
            outputCount: highpassSize,
            stride: 2,
            offset: 1,
            filterCenter: self.properties.analysisHighpassCenter
        )

        return (lowpass: lowpass, highpass: highpass)
    }

    /// Gets a value from a signal array with boundary extension.
    private func extendedValue(_ signal: [Double], index: Int) -> Double {
        let n = signal.count
        guard n > 0 else { return 0 }

        if index >= 0 && index < n {
            return signal[index]
        }

        switch boundaryExtension {
        case .symmetric:
            if index < 0 {
                let mirrorIndex = -index - 1
                return signal[min(mirrorIndex, n - 1)]
            } else {
                let mirrorIndex = 2 * n - index - 1
                return signal[max(mirrorIndex, 0)]
            }

        case .periodic:
            var wrappedIndex = index % n
            if wrappedIndex < 0 {
                wrappedIndex += n
            }
            return signal[wrappedIndex]

        case .zeroPadding:
            return 0
        }
    }
}
