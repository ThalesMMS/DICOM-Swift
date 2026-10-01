import Foundation

extension DCMWindowingProcessor {
    // MARK: - Statistical Analysis

    /// Result structure containing histogram and statistical values
    /// computed in a single pass through the pixel array.
    private struct HistogramAndStats {
        let minValue: Double
        let maxValue: Double
        let meanValue: Double
        let variance: Double
        let stdDev: Double
        let histogram: [Int]
    }

    /// Computes histogram and all statistical values in a single pass
    /// through the pixel array.  This method performs better than
    /// calling ``calculateHistogram(pixels16:minValue:maxValue:meanValue:)``
    /// and ``calculateQualityMetrics(pixels16:)`` separately, as it
    /// reduces memory bandwidth usage and cache misses.
    ///
    /// The single‑pass algorithm computes:
    /// - Minimum and maximum pixel values
    /// - Sum of pixel values (for mean calculation)
    /// - Sum of squared differences (for variance calculation)
    /// - 256‑bin histogram spanning the observed value range
    ///
    /// - Parameter pixels16: An array of unsigned 16‑bit pixel values.
    /// - Returns: A structure containing all computed statistics, or
    /// Compute a 256‑bin histogram and basic statistics from a 16‑bit pixel array.
    /// 
    /// The returned statistics include `minValue`, `maxValue`, `meanValue`, `variance`, `stdDev`, and a 256‑element `histogram`. If all pixels have the same value, all counts are placed in bin 0 and variance/stdDev are zero.
    /// - Returns: A `HistogramAndStats` with computed values, or `nil` if `pixels16` is empty.
    private static func calculateHistogramAndStats(pixels16: [UInt16]) -> HistogramAndStats? {
        guard !pixels16.isEmpty else { return nil }

        // First pass: compute min, max, and sum
        var minVal: UInt16 = UInt16.max
        var maxVal: UInt16 = 0
        var sum: Double = 0

        for v in pixels16 {
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
            sum += Double(v)
        }

        let minValue = Double(minVal)
        let maxValue = Double(maxVal)
        let meanValue = sum / Double(pixels16.count)

        // Second pass: compute histogram and variance simultaneously
        let numBins = 256
        var histogram = [Int](repeating: 0, count: numBins)
        var sumOfSquaredDiffs: Double = 0

        let range = Double(maxVal) - Double(minVal)

        if range > 0 {
            // Non‑uniform pixel values: build histogram and compute variance
            for v in pixels16 {
                // Histogram binning
                let normalized = (Double(v) - Double(minVal)) / range
                var bin = Int(normalized * Double(numBins - 1))
                if bin < 0 { bin = 0 }
                if bin >= numBins { bin = numBins - 1 }
                histogram[bin] += 1

                // Variance accumulation
                let diff = Double(v) - meanValue
                sumOfSquaredDiffs += diff * diff
            }
        } else {
            // All pixels have the same value: all go in first bin, zero variance
            histogram[0] = pixels16.count
            sumOfSquaredDiffs = 0
        }

        let variance = sumOfSquaredDiffs / Double(pixels16.count)
        let stdDev = sqrt(variance)

        return HistogramAndStats(
            minValue: minValue,
            maxValue: maxValue,
            meanValue: meanValue,
            variance: variance,
            stdDev: stdDev,
            histogram: histogram
        )
    }

    /// Calculates a histogram of the input 16‑bit pixel values using
    /// 256 bins spanning the range from the minimum to maximum
    /// intensity.  The function also computes the minimum,
    /// maximum and mean values. The histogram counts are returned
    /// as an array of `Int` rather than `NSNumber` to avoid
    /// boxing overhead.  This corresponds to the Objective‑C
    /// `calculateHistogram:length:minValue:maxValue:meanValue:`.
    ///
    /// This method uses an optimized single‑pass implementation that
    /// computes all statistics simultaneously, reducing memory
    /// bandwidth usage and cache misses.
    ///
    /// Computes a 256-bin histogram from 16-bit pixel data and outputs the observed minimum, maximum, and mean pixel values.
    /// - Parameters:
    ///   - pixels16: Array of 16-bit pixel samples to analyze.
    ///   - minValue: Assigned the observed minimum pixel value from `pixels16`.
    ///   - maxValue: Assigned the observed maximum pixel value from `pixels16`.
    ///   - meanValue: Assigned the arithmetic mean of the pixel values.
    /// - Returns: A 256-element histogram where each index counts pixels mapped into that normalized bin; returns an empty array if `pixels16` is empty.
    public static func calculateHistogram(pixels16: [UInt16],
                                          minValue: inout Double,
                                          maxValue: inout Double,
                                          meanValue: inout Double) -> [Int] {
        guard let stats = calculateHistogramAndStats(pixels16: pixels16) else {
            minValue = 0
            maxValue = 0
            meanValue = 0
            return []
        }

        // Set output parameters
        minValue = stats.minValue
        maxValue = stats.maxValue
        meanValue = stats.meanValue

        // Return histogram
        return stats.histogram
    }

    /// Computes a set of quality metrics for the given 16‑bit pixel
    /// data.  The metrics include mean, standard deviation,
    /// minimum, maximum, Michelson contrast, signal‑to‑noise ratio
    /// and dynamic range.  Results are returned in a dictionary
    /// keyed by descriptive strings.  This corresponds to the
    /// Objective‑C `calculateQualityMetrics:length:`.
    ///
    /// This method uses an optimized two-pass implementation that
    /// computes all statistics via the internal
    /// `calculateHistogramAndStats(pixels16:)` helper, reducing memory
    /// bandwidth usage and cache misses.
    ///
    /// Computes a set of image-quality metrics from a 16-bit pixel array.
    /// - Returns: A dictionary mapping metric names to values. Keys:
    ///   - "mean": average pixel value.
    ///   - "std_deviation": standard deviation of pixel values.
    ///   - "min_value": minimum pixel value.
    ///   - "max_value": maximum pixel value.
    ///   - "contrast": Michelson contrast computed as (max - min) / (max + min).
    ///   - "snr": simplified signal-to-noise ratio computed as mean / std_deviation.
    ///   - "dynamic_range": dynamic range in decibels (20 * log10(max / (min + 1))).
    ///   Returns an empty dictionary if `pixels16` is empty.
    public static func calculateQualityMetrics(pixels16: [UInt16]) -> [String: Double] {
        guard let stats = calculateHistogramAndStats(pixels16: pixels16) else {
            return [:]
        }

        // Extract pre-computed values from single-pass algorithm
        let minValue = stats.minValue
        let maxValue = stats.maxValue
        let meanValue = stats.meanValue
        let stdDev = stats.stdDev

        // Michelson contrast
        let contrast = (maxValue - minValue) / (maxValue + minValue + Double.ulpOfOne)
        // Simplified signal‑to‑noise ratio (mean / stdDev)
        let snr = meanValue / (stdDev + Double.ulpOfOne)
        // Dynamic range in decibels
        let rawDynamicRange = 20.0 * log10(maxValue / (minValue + 1.0))
        let dynamicRange = rawDynamicRange.isFinite ? rawDynamicRange : 0.0
        return [
            "mean": meanValue,
            "std_deviation": stdDev,
            "min_value": minValue,
            "max_value": maxValue,
            "contrast": contrast,
            "snr": snr,
            "dynamic_range": dynamicRange
        ]
    }

    // MARK: - Utility Methods

    /// Converts a value in Hounsfield Units (HU) to a raw pixel
    /// value given the DICOM rescale slope and intercept.  The
    /// relationship is HU = slope × pixel + intercept.  If
    /// `rescaleSlope` is zero the function returns zero to avoid
    /// division by zero.
    ///
    /// Convert a Hounsfield Unit (HU) value to the corresponding raw pixel value using DICOM rescale parameters.
    /// - Parameters:
    ///   - hu: The Hounsfield Unit to convert.
    ///   - rescaleSlope: The rescale slope (DICOM RescaleSlope). If `0`, the function returns `0` to avoid division by zero.
    ///   - rescaleIntercept: The rescale intercept (DICOM RescaleIntercept).
    /// - Returns: The raw pixel value corresponding to `hu`; `0` if `rescaleSlope` is `0`.
    public static func huToPixelValue(hu: Double,
                                      rescaleSlope: Double,
                                      rescaleIntercept: Double) -> Double {
        guard rescaleSlope != 0 else { return 0 }
        return (hu - rescaleIntercept) / rescaleSlope
    }

    /// Converts a raw pixel value to Hounsfield Units (HU) given
    /// the DICOM rescale slope and intercept.  The relationship is
    /// HU = slope × pixel + intercept.
    ///
    /// Converts a raw pixel value to Hounsfield Units (HU) using the DICOM rescale parameters.
    /// - Parameters:
    ///   - pixelValue: Raw pixel value to convert.
    ///   - rescaleSlope: Rescale slope (DICOM Rescale Slope).
    ///   - rescaleIntercept: Rescale intercept (DICOM Rescale Intercept).
    /// - Returns: The Hounsfield Unit (HU) corresponding to the input pixel value, computed as `rescaleSlope * pixelValue + rescaleIntercept`.
    public static func pixelValueToHU(pixelValue: Double,
                                      rescaleSlope: Double,
                                      rescaleIntercept: Double) -> Double {
        return rescaleSlope * pixelValue + rescaleIntercept
    }
}
