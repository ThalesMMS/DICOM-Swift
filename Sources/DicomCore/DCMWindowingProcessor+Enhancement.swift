//
//  DCMWindowingProcessor+Enhancement.swift
//  DicomCore
//
//  Adds enhancement support to DCMWindowingProcessor.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import Accelerate

extension DCMWindowingProcessor {
    // MARK: - Image Enhancement Methods

    private static func safePixelCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let product = width.multipliedReportingOverflow(by: height)
        guard !product.overflow else { return nil }
        return product.partialValue
    }

    /// Performs global 8-bit grayscale histogram equalization using Accelerate/vImage.
    /// - Parameters:
    ///   - imageData: Grayscale pixel bytes in row-major order (length must equal `width * height`).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    /// - Returns: Equalized image pixel data as `Data` on success, or `nil` if inputs are invalid or the vImage operation fails.
    private static func applyVImageHistogramEqualization(imageData: Data,
                                                         width: Int,
                                                         height: Int) -> Data? {
        // Validate input parameters
        guard let pixelCount = safePixelCount(width: width, height: height),
              imageData.count == pixelCount else { return nil }

        // Create mutable copy of input data for vImage processing
        var sourcePixels = [UInt8](imageData)
        var destPixels = [UInt8](repeating: 0, count: imageData.count)

        // Use withUnsafeMutableBytes to ensure pointer lifetime for vImage operations
        let error = sourcePixels.withUnsafeMutableBytes { sourcePtr -> vImage_Error in
            destPixels.withUnsafeMutableBytes { destPtr -> vImage_Error in
                // Create vImage buffer structures for source and destination
                var sourceBuffer = vImage_Buffer(
                    data: sourcePtr.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )

                var destBuffer = vImage_Buffer(
                    data: destPtr.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )

                // Perform histogram equalization using vImage
                return vImageEqualization_Planar8(&sourceBuffer, &destBuffer, vImage_Flags(kvImageNoFlags))
            }
        }

        // Check for errors
        guard error == kvImageNoError else {
            return nil
        }

        // Convert result back to Data
        return Data(destPixels)
    }

    /// Applies a 3×3 Gaussian-based noise reduction and blends the result with the original according to `strength`.
    /// - Parameters:
    ///   - imageData: Raw 8-bit grayscale pixel bytes; length must equal `width * height`.
    ///   - width: Image width in pixels (must be > 0).
    ///   - height: Image height in pixels (must be > 0).
    ///   - strength: Blend factor clamped to `0.0...1.0`. Values ≤ 0.1 return the original unchanged.
    /// - Returns: Processed image bytes as `Data` on success, or `nil` if inputs are invalid or vImage convolution fails.
    private static func applyVImageNoiseReduction(imageData: Data,
                                                   width: Int,
                                                   height: Int,
                                                   strength: Double) -> Data? {
        // Validate input parameters
        guard let pixelCount = safePixelCount(width: width, height: height),
              imageData.count == pixelCount else { return nil }

        // Clamp strength to valid range [0.0, 1.0]
        let strengthClamped = max(0.0, min(1.0, strength))

        // If strength is negligible, return original data unchanged
        guard strengthClamped > 0.1 else { return imageData }

        // Create mutable copy of input data and allocate convolution output buffer
        var sourcePixels = [UInt8](imageData)
        var convolvedPixels = [UInt8](repeating: 0, count: imageData.count)

        // Define 3×3 Gaussian kernel matching the manual implementation:
        // [1, 2, 1]
        // [2, 4, 2]
        // [1, 2, 1]
        // Note: kernel is row-major order
        let kernel: [Int16] = [
            1, 2, 1,
            2, 4, 2,
            1, 2, 1
        ]
        let divisor: Int32 = 16  // Sum of kernel weights

        // Perform convolution using vImage
        let error = sourcePixels.withUnsafeMutableBytes { sourcePtr -> vImage_Error in
            convolvedPixels.withUnsafeMutableBytes { convolvedPtr -> vImage_Error in
                // Create vImage buffer structures
                var sourceBuffer = vImage_Buffer(
                    data: sourcePtr.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )

                var destBuffer = vImage_Buffer(
                    data: convolvedPtr.baseAddress!,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )

                // Perform convolution with edge extension
                // kvImageEdgeExtend replicates border pixels for edge handling
                let backgroundColor: Pixel_8 = 0  // Not used with kvImageEdgeExtend
                return kernel.withUnsafeBufferPointer { kernelPtr in
                    vImageConvolve_Planar8(
                        &sourceBuffer,
                        &destBuffer,
                        nil,  // tempBuffer (nil = vImage allocates internally)
                        0,    // srcOffsetToROI_X
                        0,    // srcOffsetToROI_Y
                        kernelPtr.baseAddress!,
                        3,    // kernel_height
                        3,    // kernel_width
                        divisor,
                        backgroundColor,
                        vImage_Flags(kvImageEdgeExtend)
                    )
                }
            }
        }

        // Check for errors
        guard error == kvImageNoError else {
            return nil
        }

        // Blend convolved result with original based on strength parameter
        // result = original * (1 - strength) + convolved * strength
        let count = imageData.count
        let vectorLength = vDSP_Length(count)
        var sourceValues = [Double](repeating: 0, count: count)
        var convolvedValues = [Double](repeating: 0, count: count)
        var blendedValues = [Double](repeating: 0, count: count)
        var clippedValues = [Double](repeating: 0, count: count)
        var resultPixels = [UInt8](repeating: 0, count: imageData.count)

        vDSP_vfltu8D(sourcePixels, 1, &sourceValues, 1, vectorLength)
        vDSP_vfltu8D(convolvedPixels, 1, &convolvedValues, 1, vectorLength)

        var interpolation = strengthClamped
        vDSP_vintbD(sourceValues, 1, convolvedValues, 1, &interpolation, &blendedValues, 1, vectorLength)

        var lowerBound = 0.0
        var upperBound = 255.0
        vDSP_vclipD(blendedValues, 1, &lowerBound, &upperBound, &clippedValues, 1, vectorLength)
        vDSP_vfixu8D(clippedValues, 1, &resultPixels, 1, vectorLength)

        return Data(resultPixels)
    }

    /// Applies global histogram equalization to an 8-bit grayscale image.
    /// - Parameters:
    ///   - imageData: Raw pixel bytes in row-major order (length must equal `width * height`).
    ///   - width: Image width in pixels (must be > 0).
    ///   - height: Image height in pixels (must be > 0).
    /// - Returns: The equalized image bytes as `Data` on success, or `nil` if input validation fails or processing encounters an error.
    public static func applyHistogramEqualization(imageData: Data,
                                                  width: Int,
                                                  height: Int) -> Data? {
        return applyVImageHistogramEqualization(imageData: imageData, width: width, height: height)
    }

    /// Applies Gaussian noise reduction to an 8-bit grayscale image by blending a 3×3 blurred version with the original.
    ///
    /// Delegates to `applyVImageNoiseReduction`. `strength` is clamped to `0.0...1.0`; values ≤ 0.1 return the original unchanged.
    /// - Parameters:
    ///   - imageData: Raw 8-bit grayscale pixel bytes (row-major).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - strength: Blend factor `0.0` (no effect) to `1.0` (fully blurred).
    /// - Returns: Processed image bytes as `Data` on success, or `nil` on invalid input or processing error.
    public static func applyNoiseReduction(imageData: Data,
                                           width: Int,
                                           height: Int,
                                           strength: Double) -> Data? {
        return applyVImageNoiseReduction(imageData: imageData, width: width, height: height, strength: strength)
    }

}
