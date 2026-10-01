//
// J2KDWT1D.swift
// J2KSwift
//
// J2KDWT1D.swift
// J2KSwift
//
// Created by J2KSwift on 2026-02-05.
//

import Foundation

/// One-dimensional Discrete Wavelet Transform implementation for JPEG 2000.
///
/// This module implements the 1D DWT using the lifting scheme, supporting both
/// the reversible 5/3 filter (for lossless compression) and the irreversible 9/7
/// filter (for lossy compression) as specified in ISO/IEC 15444-1.
///
/// The lifting scheme provides:
/// - Efficient in-place computation
/// - Integer-to-integer transforms (5/3 filter)
/// - Perfect reconstruction (both filters)
/// - Minimal memory requirements
///
/// ## Usage
///
/// ```swift
/// let signal: [Int32] = [1, 2, 3, 4, 5, 6, 7, 8]
/// let filter = J2KDWTFilter.reversible53
///
/// // Forward transform
/// let (lowpass, highpass) = try J2KDWT1D.forwardTransform(
///     signal: signal,
///     filter: filter,
///     boundaryExtension: .symmetric
/// )
///
/// // Inverse transform
/// let reconstructed = try J2KDWT1D.inverseTransform(
///     lowpass: lowpass,
///     highpass: highpass,
///     filter: filter,
///     boundaryExtension: .symmetric
/// )
/// ```
public struct J2KDWT1D: Sendable {
    @inline(__always)
    private static func saturatingInt32(_ value: Double) -> Int32 {
        j2kClampedInt32(value)
    }
    // MARK: - Filter Types

    /// Lifting step specification for custom filters.
    ///
    /// Defines a single lifting step in the wavelet transform.
    /// The lifting scheme alternates between predict and update steps.
    public struct LiftingStep: Sendable, Equatable {
        /// Coefficients for the lifting step.
        public let coefficients: [Double]

        /// Whether this is a predict step (true) or update step (false).
        public let isPredict: Bool

        /// Creates a lifting step.
        ///
        /// - Parameters:
        ///   - coefficients: Filter coefficients.
        ///   - isPredict: True for predict step, false for update step.
        public init(coefficients: [Double], isPredict: Bool) {
            self.coefficients = coefficients
            self.isPredict = isPredict
        }
    }

    /// Custom filter specification for wavelet transform.
    ///
    /// Allows definition of arbitrary wavelet filters using the lifting scheme.
    /// The filter is defined as a sequence of lifting steps followed by optional scaling.
    public struct CustomFilter: Sendable, Equatable {
        /// Sequence of lifting steps to apply.
        public let steps: [LiftingStep]

        /// Scaling factor for lowpass coefficients (K in CDF 9/7).
        public let lowpassScale: Double

        /// Scaling factor for highpass coefficients (1/K in CDF 9/7).
        public let highpassScale: Double

        /// Whether this filter preserves integers (reversible).
        public let isReversible: Bool

        /// Creates a custom filter.
        ///
        /// - Parameters:
        ///   - steps: Lifting steps to apply.
        ///   - lowpassScale: Scaling for lowpass (default: 1.0).
        ///   - highpassScale: Scaling for highpass (default: 1.0).
        ///   - isReversible: Whether filter is reversible (default: false).
        public init(
            steps: [LiftingStep],
            lowpassScale: Double = 1.0,
            highpassScale: Double = 1.0,
            isReversible: Bool = false
        ) {
            self.steps = steps
            self.lowpassScale = lowpassScale
            self.highpassScale = highpassScale
            self.isReversible = isReversible
        }

        /// Creates a CDF 9/7 custom filter equivalent.
        public static var cdf97: CustomFilter {
            CustomFilter(
                steps: [
                    LiftingStep(coefficients: [-1.586134342], isPredict: true),
                    LiftingStep(coefficients: [-0.05298011854], isPredict: false),
                    LiftingStep(coefficients: [0.8829110762], isPredict: true),
                    LiftingStep(coefficients: [0.4435068522], isPredict: false),
                ],
                lowpassScale: 1.0 / 1.230174105,
                highpassScale: 1.230174105,
                isReversible: false
            )
        }

        /// Creates a Le Gall 5/3 custom filter equivalent.
        public static var leGall53: CustomFilter {
            CustomFilter(
                steps: [
                    LiftingStep(coefficients: [-0.5], isPredict: true),
                    LiftingStep(coefficients: [0.25], isPredict: false),
                ],
                lowpassScale: 1.0,
                highpassScale: 1.0,
                isReversible: true
            )
        }
    }

    /// Wavelet filter types supported by JPEG 2000.
    public enum Filter: Sendable {
        /// Le Gall 5/3 reversible filter for lossless compression.
        ///
        /// This filter uses integer arithmetic and provides perfect reconstruction.
        /// Analysis filters: LP [1/2, 1, 1/2], HP [-1/2, 1, -1/2]
        case reversible53

        /// Cohen-Daubechies-Feauveau 9/7 irreversible filter for lossy compression.
        ///
        /// This filter uses floating-point arithmetic for better compression at the
        /// cost of not being perfectly reversible in integer domain.
        case irreversible97

        /// Custom filter with user-defined lifting steps.
        ///
        /// Allows implementation of arbitrary wavelet filters using the lifting scheme.
        /// The filter specification includes lifting steps and optional scaling factors.
        case custom(CustomFilter)
    }

    /// Boundary extension modes for handling signal edges.
    public enum BoundaryExtension: Sendable {
        /// Symmetric extension (mirror without repeating edge).
        ///
        /// For signal [a, b, c, d], extends as [c, b, a | a, b, c, d | d, c, b]
        case symmetric

        /// Periodic extension (wrap around).
        ///
        /// For signal [a, b, c, d], extends as [c, d | a, b, c, d | a, b]
        case periodic

        /// Zero padding extension.
        ///
        /// For signal [a, b, c, d], extends as [0, 0 | a, b, c, d | 0, 0]
        case zeroPadding
    }

    // MARK: - Transform Functions

    /// Performs 1D forward discrete wavelet transform.
    ///
    /// Decomposes the input signal into lowpass (approximation) and highpass (detail)
    /// subbands using the specified wavelet filter and boundary extension mode.
    ///
    /// - Parameters:
    ///   - signal: Input signal to transform. Must have at least 2 elements.
    ///   - filter: Wavelet filter to use (5/3 or 9/7).
    ///   - boundaryExtension: How to handle signal boundaries (default: symmetric).
    /// - Returns: A tuple containing (lowpass, highpass) subbands.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if signal is too short.
    ///
    /// Example:
    /// ```swift
    /// let signal: [Int32] = [1, 2, 3, 4, 5, 6, 7, 8]
    /// let (low, high) = try J2KDWT1D.forwardTransform(
    ///     signal: signal,
    ///     filter: .reversible53
    /// )
    /// ```
    public static func forwardTransform(
        signal: [Int32],
        filter: Filter,
        boundaryExtension: BoundaryExtension = .symmetric
    ) throws -> (lowpass: [Int32], highpass: [Int32]) {
        guard signal.count >= 2 else {
            throw J2KError.invalidParameter("Signal must have at least 2 elements, got \(signal.count)")
        }

        switch filter {
        case .reversible53:
            return try forwardTransform53(signal: signal, boundaryExtension: boundaryExtension)
        case .irreversible97:
            // Convert Int32 to Double, apply 9/7 filter, then round back to Int32
            let doubleSignal = signal.map { Double($0) }
            let (lowDouble, highDouble) = try forwardTransform97(
                signal: doubleSignal,
                boundaryExtension: boundaryExtension)
            let lowpass = lowDouble.map { saturatingInt32($0) }
            let highpass = highDouble.map { saturatingInt32($0) }
            return (lowpass: lowpass, highpass: highpass)
        case .custom(let customFilter):
            // Convert Int32 to Double, apply custom filter, then round back to Int32
            let doubleSignal = signal.map { Double($0) }
            let (lowDouble, highDouble) = try forwardTransformCustom(
                signal: doubleSignal,
                filter: customFilter,
                boundaryExtension: boundaryExtension
            )
            let lowpass = lowDouble.map { saturatingInt32($0) }
            let highpass = highDouble.map { saturatingInt32($0) }
            return (lowpass: lowpass, highpass: highpass)
        }
    }

    /// Performs 1D forward DWT on Double-precision data (no intermediate rounding).
    ///
    /// Used by the irreversible 9-7 path to maintain full floating-point precision
    /// through multi-level decomposition, avoiding accumulated rounding error.
    ///
    /// - Parameters:
    ///   - signal: Input signal as Double-precision values.
    ///   - filter: Wavelet filter to use.
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: A tuple of (lowpass, highpass) subbands in Double precision.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if signal is too short.
    public static func forwardTransformDouble(
        signal: [Double],
        filter: Filter,
        boundaryExtension: BoundaryExtension = .symmetric
    ) throws -> (lowpass: [Double], highpass: [Double]) {
        guard signal.count >= 2 else {
            throw J2KError.invalidParameter("Signal must have at least 2 elements, got \(signal.count)")
        }

        switch filter {
        case .reversible53:
            let int32Signal = signal.map { saturatingInt32($0) }
            let (low, high) = try forwardTransform53(signal: int32Signal, boundaryExtension: boundaryExtension)
            return (lowpass: low.map { Double($0) }, highpass: high.map { Double($0) })
        case .irreversible97:
            return try forwardTransform97(signal: signal, boundaryExtension: boundaryExtension)
        case .custom(let customFilter):
            return try forwardTransformCustom(
                signal: signal,
                filter: customFilter,
                boundaryExtension: boundaryExtension
            )
        }
    }

    /// Performs 1D inverse discrete wavelet transform.
    ///
    /// Reconstructs the original signal from lowpass and highpass subbands using
    /// the specified wavelet filter and boundary extension mode.
    ///
    /// - Parameters:
    ///   - lowpass: Lowpass (approximation) coefficients.
    ///   - highpass: Highpass (detail) coefficients.
    ///   - filter: Wavelet filter to use (must match forward transform).
    ///   - boundaryExtension: How to handle signal boundaries (default: symmetric).
    /// - Returns: Reconstructed signal.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if subbands have incompatible sizes.
    ///
    /// Example:
    /// ```swift
    /// let reconstructed = try J2KDWT1D.inverseTransform(
    ///     lowpass: low,
    ///     highpass: high,
    ///     filter: .reversible53
    /// )
    /// ```
    public static func inverseTransform(
        lowpass: [Int32],
        highpass: [Int32],
        filter: Filter,
        boundaryExtension: BoundaryExtension = .symmetric
    ) throws -> [Int32] {
        guard !lowpass.isEmpty else {
            throw J2KError.invalidParameter("Lowpass subband cannot be empty")
        }
        // Edge tiles may have dimension=1, producing empty highpass
        if highpass.isEmpty {
            return lowpass
        }

        // For typical dyadic decomposition, lowpass and highpass should have equal
        // or nearly equal lengths (differ by at most 1)
        guard abs(lowpass.count - highpass.count) <= 1 else {
            throw J2KError.invalidParameter(
                "Incompatible subband sizes: lowpass=\(lowpass.count), highpass=\(highpass.count)"
            )
        }

        switch filter {
        case .reversible53:
            return try inverseTransform53(lowpass: lowpass, highpass: highpass, boundaryExtension: boundaryExtension)
        case .irreversible97:
            // Convert Int32 to Double, apply inverse 9/7 filter, then round back to Int32
            let lowDouble = lowpass.map { Double($0) }
            let highDouble = highpass.map { Double($0) }
            let resultDouble = try inverseTransform97(
                lowpass: lowDouble, highpass: highDouble,
                boundaryExtension: boundaryExtension)
            return resultDouble.map { saturatingInt32($0) }
        case .custom(let customFilter):
            // Convert Int32 to Double, apply inverse custom filter, then round back to Int32
            let lowDouble = lowpass.map { Double($0) }
            let highDouble = highpass.map { Double($0) }
            let resultDouble = try inverseTransformCustom(
                lowpass: lowDouble,
                highpass: highDouble,
                filter: customFilter,
                boundaryExtension: boundaryExtension
            )
            return resultDouble.map { saturatingInt32($0) }
        }
    }

    // MARK: - 5/3 Reversible Filter Implementation

    /// Forward transform using 5/3 reversible filter with lifting scheme.
    ///
    /// Implements the Le Gall 5/3 wavelet using integer arithmetic:
    /// 1. Split into even and odd samples
    /// 2. Predict: d[n] = odd[n] - floor((even[n] + even[n+1]) / 2)
    /// 3. Update: s[n] = even[n] + floor((d[n-1] + d[n]) / 4)
    private static func forwardTransform53(
        signal: [Int32],
        boundaryExtension: BoundaryExtension
    ) throws -> (lowpass: [Int32], highpass: [Int32]) {
        let n = signal.count

        // Calculate output sizes (dyadic decomposition)
        let lowpassSize = (n + 1) / 2
        let highpassSize = n / 2

        var lowpass = [Int32](repeating: 0, count: lowpassSize)
        var highpass = [Int32](repeating: 0, count: highpassSize)

        // Split into even and odd samples
        var even = [Int32](repeating: 0, count: lowpassSize)
        var odd = [Int32](repeating: 0, count: highpassSize)

        for i in 0..<lowpassSize {
            even[i] = signal[i * 2]
        }

        for i in 0..<highpassSize {
            odd[i] = signal[i * 2 + 1]
        }

        // Predict step: d[n] = odd[n] - floor((even[n] + even[n+1]) / 2)
        for i in 0..<highpassSize {
            let left = even[i]
            let right = getExtendedValue(even, index: i + 1, extension: boundaryExtension)
            highpass[i] = odd[i] - ((left + right) >> 1) // >> 1 is floor division by 2
        }

        // Update step: s[n] = even[n] + floor((d[n-1] + d[n]) / 4)
        for i in 0..<lowpassSize {
            let left = getExtendedValue(highpass, index: i - 1, extension: boundaryExtension)
            let right = i < highpassSize
                ? highpass[i]
                : getExtendedValue(highpass, index: i, extension: boundaryExtension)

            // Addition for rounding: (a + b + 2) / 4 for floor((a + b) / 4)
            lowpass[i] = even[i] + ((left + right + 2) >> 2) // >> 2 is floor division by 4
        }

        return (lowpass: lowpass, highpass: highpass)
    }

    /// Inverse transform using 5/3 reversible filter with lifting scheme.
    ///
    /// Reconstructs the signal by reversing the lifting steps:
    /// 1. Undo update: even[n] = s[n] - floor((d[n-1] + d[n]) / 4)
    /// 2. Undo predict: odd[n] = d[n] + floor((even[n] + even[n+1]) / 2)
    /// 3. Merge even and odd samples
    private static func inverseTransform53(
        lowpass: [Int32],
        highpass: [Int32],
        boundaryExtension: BoundaryExtension
    ) throws -> [Int32] {
        let lowpassSize = lowpass.count
        let highpassSize = highpass.count
        let n = lowpassSize + highpassSize

        var even = lowpass
        var odd = [Int32](repeating: 0, count: highpassSize)

        // Undo update step: even[n] = s[n] - floor((d[n-1] + d[n]) / 4)
        for i in 0..<lowpassSize {
            let left = getExtendedValue(highpass, index: i - 1, extension: boundaryExtension)
            let right = i < highpassSize
                ? highpass[i]
                : getExtendedValue(highpass, index: i, extension: boundaryExtension)

            even[i] = lowpass[i] - ((left + right + 2) >> 2)
        }

        // Undo predict step: odd[n] = d[n] + floor((even[n] + even[n+1]) / 2)
        for i in 0..<highpassSize {
            let left = even[i]
            let right = getExtendedValue(even, index: i + 1, extension: boundaryExtension)

            odd[i] = highpass[i] + ((left + right) >> 1)
        }

        // Merge even and odd samples
        var result = [Int32](repeating: 0, count: n)
        for i in 0..<lowpassSize {
            result[i * 2] = even[i]
        }
        for i in 0..<highpassSize {
            result[i * 2 + 1] = odd[i]
        }

        return result
    }

    // MARK: - Boundary Extension Helpers

    /// Gets a value from an array with boundary extension.
    ///
    /// - Parameters:
    ///   - array: The array to access.
    ///   - index: The index (may be out of bounds).
    ///   - extension: The boundary extension mode.
    /// - Returns: The extended value.
    private static func getExtendedValue(
        _ array: [Int32],
        index: Int,
        extension: BoundaryExtension
    ) -> Int32 {
        let n = array.count

        guard n > 0 else { return 0 }

        if index >= 0 && index < n {
            return array[index]
        }

        switch `extension` {
        case .symmetric:
            // Mirror extension without repeating edge
            // For [a, b, c, d]: ... c b | a b c d | d c b ...
            if index < 0 {
                let mirrorIndex = -index - 1
                return array[min(mirrorIndex, n - 1)]
            } else {
                let mirrorIndex = 2 * n - index - 1
                return array[max(mirrorIndex, 0)]
            }

        case .periodic:
            // Wrap around
            var wrappedIndex = index % n
            if wrappedIndex < 0 {
                wrappedIndex += n
            }
            return array[wrappedIndex]

        case .zeroPadding:
            return 0
        }
    }
}

// MARK: - Floating-Point Transform for 9/7 Filter

extension J2KDWT1D {
    /// Performs 1D forward DWT using 9/7 irreversible filter.
    ///
    /// - Parameters:
    ///   - signal: Input signal as floating-point values.
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: A tuple containing (lowpass, highpass) subbands.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if signal is too short.
    public static func forwardTransform97(
        signal: [Double],
        boundaryExtension: BoundaryExtension = .symmetric
    ) throws -> (lowpass: [Double], highpass: [Double]) {
        guard signal.count >= 2 else {
            throw J2KError.invalidParameter("Signal must have at least 2 elements, got \(signal.count)")
        }

        let n = signal.count
        let lowpassSize = (n + 1) / 2
        let highpassSize = n / 2

        var even = [Double](repeating: 0, count: lowpassSize)
        var odd = [Double](repeating: 0, count: highpassSize)

        // Split
        for i in 0..<lowpassSize {
            even[i] = signal[i * 2]
        }
        for i in 0..<highpassSize {
            odd[i] = signal[i * 2 + 1]
        }

        // CDF 9/7 lifting coefficients (from ISO/IEC 15444-1)
        let alpha = -1.586134342
        let beta = -0.05298011854
        let gamma = 0.8829110762
        let delta = 0.4435068522
        let k = 1.230174105

        // Predict 1: odd[n] += alpha * (even[n] + even[n+1])
        for i in 0..<highpassSize {
            let left = even[i]
            let right = getExtendedValue(even, index: i + 1, extension: boundaryExtension)
            odd[i] += alpha * (left + right)
        }

        // Update 1: even[n] += beta * (odd[n-1] + odd[n])
        for i in 0..<lowpassSize {
            let left = getExtendedValue(odd, index: i - 1, extension: boundaryExtension)
            let right = i < highpassSize ? odd[i] : getExtendedValue(odd, index: i, extension: boundaryExtension)
            even[i] += beta * (left + right)
        }

        // Predict 2: odd[n] += gamma * (even[n] + even[n+1])
        for i in 0..<highpassSize {
            let left = even[i]
            let right = getExtendedValue(even, index: i + 1, extension: boundaryExtension)
            odd[i] += gamma * (left + right)
        }

        // Update 2: even[n] += delta * (odd[n-1] + odd[n])
        for i in 0..<lowpassSize {
            let left = getExtendedValue(odd, index: i - 1, extension: boundaryExtension)
            let right = i < highpassSize ? odd[i] : getExtendedValue(odd, index: i, extension: boundaryExtension)
            even[i] += delta * (left + right)
        }

        // Scaling: lowpass /= K, highpass *= K (per ISO/IEC 15444-1)
        for i in 0..<lowpassSize {
            even[i] /= k
        }
        for i in 0..<highpassSize {
            odd[i] *= k
        }

        return (lowpass: even, highpass: odd)
    }

    /// Performs 1D inverse DWT using 9/7 irreversible filter.
    ///
    /// - Parameters:
    ///   - lowpass: Lowpass coefficients.
    ///   - highpass: Highpass coefficients.
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: Reconstructed signal.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if subbands have incompatible sizes.
    public static func inverseTransform97(
        lowpass: [Double],
        highpass: [Double],
        boundaryExtension: BoundaryExtension = .symmetric
    ) throws -> [Double] {
        guard !lowpass.isEmpty else {
            throw J2KError.invalidParameter("Lowpass subband cannot be empty")
        }
        // Edge tiles may have dimension=1, producing empty highpass
        if highpass.isEmpty {
            return lowpass
        }

        guard abs(lowpass.count - highpass.count) <= 1 else {
            throw J2KError.invalidParameter(
                "Incompatible subband sizes: lowpass=\(lowpass.count), highpass=\(highpass.count)"
            )
        }

        let lowpassSize = lowpass.count
        let highpassSize = highpass.count
        let n = lowpassSize + highpassSize

        var even = lowpass
        var odd = highpass

        // CDF 9/7 lifting coefficients
        let alpha = -1.586134342
        let beta = -0.05298011854
        let gamma = 0.8829110762
        let delta = 0.4435068522
        let k = 1.230174105

        // Undo scaling: lowpass *= K, highpass /= K (inverse of forward)
        for i in 0..<lowpassSize {
            even[i] *= k
        }
        for i in 0..<highpassSize {
            odd[i] /= k
        }

        // Undo update 2
        for i in 0..<lowpassSize {
            let left = getExtendedValue(odd, index: i - 1, extension: boundaryExtension)
            let right = i < highpassSize ? odd[i] : getExtendedValue(odd, index: i, extension: boundaryExtension)
            even[i] -= delta * (left + right)
        }

        // Undo predict 2
        for i in 0..<highpassSize {
            let left = even[i]
            let right = getExtendedValue(even, index: i + 1, extension: boundaryExtension)
            odd[i] -= gamma * (left + right)
        }

        // Undo update 1
        for i in 0..<lowpassSize {
            let left = getExtendedValue(odd, index: i - 1, extension: boundaryExtension)
            let right = i < highpassSize ? odd[i] : getExtendedValue(odd, index: i, extension: boundaryExtension)
            even[i] -= beta * (left + right)
        }

        // Undo predict 1
        for i in 0..<highpassSize {
            let left = even[i]
            let right = getExtendedValue(even, index: i + 1, extension: boundaryExtension)
            odd[i] -= alpha * (left + right)
        }

        // Merge
        var result = [Double](repeating: 0, count: n)
        for i in 0..<lowpassSize {
            result[i * 2] = even[i]
        }
        for i in 0..<highpassSize {
            result[i * 2 + 1] = odd[i]
        }

        return result
    }

    /// Gets a value from a Double array with boundary extension.
    private static func getExtendedValue(
        _ array: [Double],
        index: Int,
        extension: BoundaryExtension
    ) -> Double {
        let n = array.count

        guard n > 0 else { return 0 }

        if index >= 0 && index < n {
            return array[index]
        }

        switch `extension` {
        case .symmetric:
            if index < 0 {
                let mirrorIndex = -index - 1
                return array[min(mirrorIndex, n - 1)]
            } else {
                let mirrorIndex = 2 * n - index - 1
                return array[max(mirrorIndex, 0)]
            }

        case .periodic:
            var wrappedIndex = index % n
            if wrappedIndex < 0 {
                wrappedIndex += n
            }
            return array[wrappedIndex]

        case .zeroPadding:
            return 0
        }
    }

    // MARK: - Custom Filter Implementation

    /// Performs 1D forward DWT using a custom filter.
    ///
    /// - Parameters:
    ///   - signal: Input signal as floating-point values.
    ///   - filter: Custom filter specification.
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: A tuple containing (lowpass, highpass) subbands.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if signal is too short.
    public static func forwardTransformCustom(
        signal: [Double],
        filter: CustomFilter,
        boundaryExtension: BoundaryExtension = .symmetric
    ) throws -> (lowpass: [Double], highpass: [Double]) {
        guard signal.count >= 2 else {
            throw J2KError.invalidParameter("Signal must have at least 2 elements, got \(signal.count)")
        }

        let n = signal.count
        let lowpassSize = (n + 1) / 2
        let highpassSize = n / 2

        var even = [Double](repeating: 0, count: lowpassSize)
        var odd = [Double](repeating: 0, count: highpassSize)

        // Split
        for i in 0..<lowpassSize {
            even[i] = signal[i * 2]
        }
        for i in 0..<highpassSize {
            odd[i] = signal[i * 2 + 1]
        }

        // Apply lifting steps
        for step in filter.steps {
            if step.isPredict {
                // Predict step: update odd samples
                for i in 0..<highpassSize {
                    var sum = 0.0
                    for (idx, coef) in step.coefficients.enumerated() {
                        let offset = idx - step.coefficients.count / 2
                        let left = getExtendedValue(even, index: i + offset, extension: boundaryExtension)
                        let right = getExtendedValue(even, index: i + offset + 1, extension: boundaryExtension)
                        sum += coef * (left + right)
                    }
                    odd[i] += sum
                }
            } else {
                // Update step: update even samples
                for i in 0..<lowpassSize {
                    var sum = 0.0
                    for (idx, coef) in step.coefficients.enumerated() {
                        let offset = idx - step.coefficients.count / 2
                        let left = getExtendedValue(odd, index: i + offset - 1, extension: boundaryExtension)
                        let right = i + offset < highpassSize ?
                            odd[i + offset] :
                            getExtendedValue(odd, index: i + offset, extension: boundaryExtension)
                        sum += coef * (left + right)
                    }
                    even[i] += sum
                }
            }
        }

        // Scaling
        for i in 0..<lowpassSize {
            even[i] *= filter.lowpassScale
        }
        for i in 0..<highpassSize {
            odd[i] *= filter.highpassScale
        }

        return (lowpass: even, highpass: odd)
    }

    /// Performs 1D inverse DWT using a custom filter.
    ///
    /// - Parameters:
    ///   - lowpass: Lowpass coefficients.
    ///   - highpass: Highpass coefficients.
    ///   - filter: Custom filter specification.
    ///   - boundaryExtension: How to handle signal boundaries.
    /// - Returns: Reconstructed signal.
    /// - Throws: ``J2KError/invalidParameter(_:)`` if subbands have incompatible sizes.
    public static func inverseTransformCustom(
        lowpass: [Double],
        highpass: [Double],
        filter: CustomFilter,
        boundaryExtension: BoundaryExtension = .symmetric
    ) throws -> [Double] {
        guard !lowpass.isEmpty && !highpass.isEmpty else {
            throw J2KError.invalidParameter("Subbands cannot be empty")
        }

        guard abs(lowpass.count - highpass.count) <= 1 else {
            throw J2KError.invalidParameter(
                "Incompatible subband sizes: lowpass=\(lowpass.count), highpass=\(highpass.count)"
            )
        }

        let lowpassSize = lowpass.count
        let highpassSize = highpass.count
        let n = lowpassSize + highpassSize

        var even = lowpass
        var odd = highpass

        // Undo scaling
        for i in 0..<lowpassSize {
            even[i] /= filter.lowpassScale
        }
        for i in 0..<highpassSize {
            odd[i] /= filter.highpassScale
        }

        // Undo lifting steps in reverse order
        for step in filter.steps.reversed() {
            if step.isPredict {
                // Undo predict step
                for i in 0..<highpassSize {
                    var sum = 0.0
                    for (idx, coef) in step.coefficients.enumerated() {
                        let offset = idx - step.coefficients.count / 2
                        let left = getExtendedValue(even, index: i + offset, extension: boundaryExtension)
                        let right = getExtendedValue(even, index: i + offset + 1, extension: boundaryExtension)
                        sum += coef * (left + right)
                    }
                    odd[i] -= sum
                }
            } else {
                // Undo update step
                for i in 0..<lowpassSize {
                    var sum = 0.0
                    for (idx, coef) in step.coefficients.enumerated() {
                        let offset = idx - step.coefficients.count / 2
                        let left = getExtendedValue(odd, index: i + offset - 1, extension: boundaryExtension)
                        let right = i + offset < highpassSize ?
                            odd[i + offset] :
                            getExtendedValue(odd, index: i + offset, extension: boundaryExtension)
                        sum += coef * (left + right)
                    }
                    even[i] -= sum
                }
            }
        }

        // Merge
        var result = [Double](repeating: 0, count: n)
        for i in 0..<lowpassSize {
            result[i * 2] = even[i]
        }
        for i in 0..<highpassSize {
            result[i * 2 + 1] = odd[i]
        }

        return result
    }
}
