//
//  VDSPProcessor.swift
//  MetalBenchmark
//
//  vDSP-based window/level processor for CPU baseline benchmarking. This implementation extracts
//  the exact vDSP windowing logic from DCMWindowingProcessor.swift to provide accurate performance
//  comparison against Metal GPU implementation.
//
//  vDSP leverages hand-tuned ARM NEON assembly instructions on Apple Silicon and SSE/AVX on Intel,
//  representing optimal CPU SIMD performance without custom assembly optimization.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import Accelerate

/// CPU-based window/level processor using Apple's vDSP framework.
/// Provides baseline performance metrics for Metal GPU comparison.
public struct VDSPProcessor {

    // MARK: - Core Window/Level Operation

    /// Applies a linear window/level transformation to a 16-bit
    /// grayscale pixel buffer using vDSP vectorized operations.
    /// The resulting pixels are scaled to the 0-255 range and
    /// returned as Data.
    ///
    /// This is a direct copy of DCMWindowingProcessor.applyWindowLevel
    /// to ensure identical algorithm and accurate benchmark comparison.
    ///
    /// - Parameters:
    ///   - pixels16: An array of unsigned 16-bit pixel intensities.
    ///   - center: The centre of the window.
    ///   - width: The width of the window.
    /// - Returns: A Data object containing 8-bit pixel values or
    ///   nil if the input is invalid.
    public static func applyWindowLevel(
        pixels16: [UInt16],
        center: Double,
        width: Double
    ) -> Data? {
        guard !pixels16.isEmpty, width > 0 else { return nil }

        let length = vDSP_Length(pixels16.count)

        // Calculate min and max levels
        let minLevel = center - width / 2.0
        let maxLevel = center + width / 2.0
        let range = maxLevel - minLevel
        let rangeInv: Double = range > 0 ? 255.0 / range : 1.0

        // Convert UInt16 to Double for processing
        var doubles = pixels16.map { Double($0) }

        // Subtract min level using vDSP
        var minLevelScalar = minLevel
        var tempDoubles = [Double](repeating: 0, count: pixels16.count)
        vDSP_vsaddD(&doubles, 1, &minLevelScalar, &tempDoubles, 1, length)

        // Multiply by scaling factor using vDSP
        var scale = rangeInv
        vDSP_vsmulD(&tempDoubles, 1, &scale, &doubles, 1, length)

        // Allocate output buffer
        var bytes = [UInt8](repeating: 0, count: pixels16.count)

        // Clamp and convert to UInt8
        for i in 0..<pixels16.count {
            var value = doubles[i]
            // Clamp between 0 and 255
            value = max(0.0, min(255.0, value))
            bytes[i] = UInt8(value)
        }

        return Data(bytes)
    }

    // MARK: - Float Variant

    /// Float variant for API compatibility with MetalWindowingProcessor.
    /// Internally converts to Double for vDSP processing.
    ///
    /// - Parameters:
    ///   - pixels16: An array of unsigned 16-bit pixel intensities.
    ///   - center: The centre of the window (Float).
    ///   - width: The width of the window (Float).
    /// - Returns: A Data object containing 8-bit pixel values or nil.
    public static func applyWindowLevel(
        pixels16: [UInt16],
        center: Float,
        width: Float
    ) -> Data? {
        return applyWindowLevel(
            pixels16: pixels16,
            center: Double(center),
            width: Double(width)
        )
    }

    // MARK: - Utility Methods

    /// Calculates an optimal window centre and width based on the
    /// 1st and 99th percentiles of the pixel value distribution.
    ///
    /// - Parameter pixels16: Array of 16-bit pixel values.
    /// - Returns: A tuple (center, width) representing the
    ///   calculated window centre and width.
    public static func calculateOptimalWindowLevel(
        pixels16: [UInt16]
    ) -> (center: Double, width: Double) {
        guard !pixels16.isEmpty else { return (0.0, 0.0) }

        // Compute basic stats
        var minValue: Double = 0
        var maxValue: Double = 0
        var meanValue: Double = 0
        let histogram = calculateHistogram(
            pixels16: pixels16,
            minValue: &minValue,
            maxValue: &maxValue,
            meanValue: &meanValue
        )

        guard !histogram.isEmpty else {
            // Ensure minimum width of 1.0 for edge cases
            let width = max(maxValue - minValue, 1.0)
            return (center: meanValue, width: width)
        }

        // Determine thresholds for 1st and 99th percentiles
        let totalPixels = pixels16.count
        let p1Threshold = Int(Double(totalPixels) * 0.01)
        let p99Threshold = Int(Double(totalPixels) * 0.99)

        var cumulativeCount = 0
        var p1Value = minValue
        var p99Value = maxValue
        let binWidth = (maxValue - minValue) / Double(histogram.count)

        for (i, count) in histogram.enumerated() {
            cumulativeCount += count
            let binValue = minValue + (Double(i) + 0.5) * binWidth

            if cumulativeCount >= p1Threshold && p1Value == minValue {
                p1Value = binValue
            }
            if cumulativeCount >= p99Threshold {
                p99Value = binValue
                break
            }
        }

        let center = (p1Value + p99Value) / 2.0
        let width = p99Value - p1Value

        // Ensure minimum width of 1.0 for edge cases
        let finalWidth = max(width, 1.0)
        return (center, finalWidth)
    }

    // MARK: - Statistical Analysis

    /// Calculates a histogram of the input 16-bit pixel values using
    /// 256 bins spanning the range from the minimum to maximum
    /// intensity.
    ///
    /// - Parameters:
    ///   - pixels16: An array of unsigned 16-bit pixel values.
    ///   - minValue: Output parameter receiving the minimum value.
    ///   - maxValue: Output parameter receiving the maximum value.
    ///   - meanValue: Output parameter receiving the mean value.
    /// - Returns: A histogram array with 256 bins.
    public static func calculateHistogram(
        pixels16: [UInt16],
        minValue: inout Double,
        maxValue: inout Double,
        meanValue: inout Double
    ) -> [Int] {
        guard !pixels16.isEmpty else { return [] }

        var minVal: UInt16 = UInt16.max
        var maxVal: UInt16 = 0
        var sum: Double = 0

        for v in pixels16 {
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
            sum += Double(v)
        }

        minValue = Double(minVal)
        maxValue = Double(maxVal)
        meanValue = sum / Double(pixels16.count)

        // Histogram with 256 bins
        let numBins = 256
        var histogram = [Int](repeating: 0, count: numBins)
        let range = Double(maxVal) - Double(minVal)

        guard range > 0 else { return histogram }

        for v in pixels16 {
            let normalized = (Double(v) - Double(minVal)) / range
            var bin = Int(normalized * Double(numBins - 1))
            if bin < 0 { bin = 0 }
            if bin >= numBins { bin = numBins - 1 }
            histogram[bin] += 1
        }

        return histogram
    }
}
