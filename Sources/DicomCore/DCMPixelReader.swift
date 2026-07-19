//
//  DCMPixelReader.swift
//
//  Pixel data extraction and decoding for DICOM files.
//  This module handles reading uncompressed pixel buffers for 8‑bit,
//  16‑bit, and 24‑bit RGB images, as well as decoding compressed
//  transfer syntaxes using explicit codec backends.  Supports signed/unsigned pixel
//  representation, MONOCHROME1/MONOCHROME2 photometric interpretation,
//  and memory-mapped optimization for large files.
//
//  Usage:
//
//    let result = DCMPixelReader.readPixels(
//        data: dicomData,
//        width: 512,
//        height: 512,
//        bitDepth: 16,
//        samplesPerPixel: 1,
//        offset: 1024,
//        pixelRepresentation: 0,
//        littleEndian: true,
//        photometricInterpretation: "MONOCHROME2"
//    )
//    if let pixels16 = result.pixels16 {
//        // process 16-bit grayscale pixels
//    }
//

import Foundation
import Accelerate
import CoreGraphics
import ImageIO

/// Result structure for pixel reading operations.
/// Contains pixel buffers and metadata about the pixel data.
internal struct DCMPixelReadResult {
    /// 8-bit grayscale pixel buffer
    var pixels8: [UInt8]?
    /// 16-bit grayscale pixel buffer
    var pixels16: [UInt16]?
    /// 24-bit RGB pixel buffer (interleaved)
    var pixels24: [UInt8]?
    /// True if pixels use signed representation
    var signedImage: Bool
    /// Actual image width (may differ from header for compressed images)
    var width: Int
    /// Actual image height (may differ from header for compressed images)
    var height: Int
    /// Actual bit depth (may differ from header for compressed images)
    var bitDepth: Int
    /// Actual samples per pixel (may differ from header for compressed images)
    var samplesPerPixel: Int
}

/// Reader for DICOM pixel data.
/// Handles extraction of pixel buffers from both uncompressed and
/// compressed DICOM files.  Supports 8‑bit grayscale, 16‑bit grayscale,
/// and 24‑bit RGB images.  Automatically handles endianness, signed/
/// unsigned pixel representation, and photometric interpretation.
///
/// This class is designed to be used by DCMDecoder.  All methods are
/// static and take the necessary parameters explicitly.
internal final class DCMPixelReader {

    // MARK: - Private Constants

    /// Minimum signed 16-bit value used for normalizing signed pixels
    private static let min16: Int = Int(Int16.min)

    /// Maximum allowed image dimension (width or height) in pixels.
    /// Prevents memory bombs from malformed DICOM headers.
    private static let maxImageDimension: Int = 65536

    /// Maximum allowed size for pixel buffer allocation (2 GB).
    /// Protects against excessive memory use and integer overflow.
    private static let maxPixelBufferSize: Int64 = 2 * 1024 * 1024 * 1024

    // MARK: - Pixel Reading Methods

    /// Converts a two's complement encoded 16‑bit value into an
    /// unsigned 16‑bit representation.  This is used when
    /// ``pixelRepresentation`` equals one to map signed pixel values
    /// into the positive range expected by rendering code.  The
    /// algorithm subtracts the minimum short value to shift the
    /// range appropriately.
    ///
    /// - Parameters:
    ///   - b0: Low byte
    ///   - b1: High byte
    /// - Returns: Normalized unsigned 16-bit value
    private static func normaliseSigned16(bytes b0: UInt8, b1: UInt8) -> UInt16 {
        let combined = Int16(bitPattern: UInt16(b1) << 8 | UInt16(b0))
        // Shift negative values up by min16 to make them positive
        let shifted = Int(combined) - min16
        return UInt16(shifted)
    }

    /// Converts signed 16-bit pixels to unsigned representation by
    /// flipping the sign bit. This is equivalent to adding 32768 to
    /// every two's-complement sample, without temporary buffers.
    ///
    /// - Parameters:
    ///   - sourcePtr: Pointer to the raw source bytes containing `count` 16-bit signed samples.
    ///   - outputBuffer: Destination buffer that will receive `count` normalized `UInt16` values. The function writes into the first `count` elements.
    ///   - count: Number of 16-bit samples to normalize.
    ///   - littleEndian: `true` if the source samples are in little-endian byte order; `false` for big-endian.
    static func normaliseSigned16Vectorized(
        sourcePtr: UnsafeRawPointer,
        outputBuffer: inout [UInt16],
        count: Int,
        littleEndian: Bool
    ) {
        guard count > 0 else { return }
        precondition(count <= outputBuffer.count, "buffer overrun")

        outputBuffer.withUnsafeMutableBufferPointer { uint16Buffer in
            writeNormalizedSigned16(
                sourcePtr: sourcePtr,
                outputBuffer: uint16Buffer,
                count: count,
                littleEndian: littleEndian
            )
        }
    }

    private static func writeNormalizedSigned16(
        sourcePtr: UnsafeRawPointer,
        outputBuffer: UnsafeMutableBufferPointer<UInt16>,
        count: Int,
        littleEndian: Bool,
        inverted: Bool = false
    ) {
        guard count > 0, let destination = outputBuffer.baseAddress else { return }
        let transformMask: UInt16 = inverted ? 0x7FFF : 0x8000
        let sourceAddress = UInt(bitPattern: sourcePtr)

        if sourceAddress.isMultiple(of: UInt(MemoryLayout<UInt16>.alignment)) {
            let source = sourcePtr.assumingMemoryBound(to: UInt16.self)
            if littleEndian {
                for index in 0..<count {
                    destination[index] = source[index] ^ transformMask
                }
            } else {
                for index in 0..<count {
                    destination[index] = source[index].byteSwapped ^ transformMask
                }
            }
        } else {
            let source = sourcePtr.assumingMemoryBound(to: UInt8.self)
            for index in 0..<count {
                let byteOffset = index * 2
                let raw: UInt16
                if littleEndian {
                    raw = UInt16(source[byteOffset + 1]) << 8 | UInt16(source[byteOffset])
                } else {
                    raw = UInt16(source[byteOffset]) << 8 | UInt16(source[byteOffset + 1])
                }
                destination[index] = raw ^ transformMask
            }
        }
    }

    /// Vectorized inversion of 16‑bit pixels for MONOCHROME1 photometric
    /// interpretation using Accelerate vDSP operations.  This function
    /// performs the operation: output[i] = 65535 - input[i] using SIMD
    /// operations for optimal performance on large pixel buffers.
    ///
    /// - Parameters:
    ///   - buffer: Buffer of UInt16 pixels to invert in-place
    /// Inverts the first `count` samples in a 16-bit monochrome buffer for MONOCHROME1 images.
    ///
    /// Converts each value v to (65535 - v) in place for the first `count` elements of `buffer`.
    /// - Parameters:
    ///   - buffer: In-out array of 16-bit pixel samples; the first `count` elements are replaced with their inverted values.
    ///   - count: Number of samples to process from the start of `buffer`.
    static func invertMonochrome1Vectorized(
        buffer: inout [UInt16],
        count: Int
    ) {
        guard count > 0 else { return }
        precondition(count <= buffer.count, "buffer overrun")

        // Acquire temporary buffer from pool
        var floatPixels = BufferPool.shared.acquire(type: [Float].self, count: count)

        // Ensure buffer is released back to pool when done
        defer {
            BufferPool.shared.release(floatPixels)
        }

        // Convert UInt16 to Float for vDSP processing
        buffer.withUnsafeBufferPointer { uint16Buffer in
            vDSP_vfltu16(uint16Buffer.baseAddress!, 1, &floatPixels, 1, vDSP_Length(count))
        }

        // Negate values: -input
        vDSP_vneg(floatPixels, 1, &floatPixels, 1, vDSP_Length(count))

        // Add 65535: 65535 + (-input) = 65535 - input
        var offset: Float = 65535.0
        vDSP_vsadd(floatPixels, 1, &offset, &floatPixels, 1, vDSP_Length(count))

        // Clamp to valid range [0, 65535] to handle any edge cases
        var lowerBound: Float = 0.0
        var upperBound: Float = 65535.0
        vDSP_vclip(floatPixels, 1, &lowerBound, &upperBound, &floatPixels, 1, vDSP_Length(count))

        // Convert back to UInt16
        floatPixels.withUnsafeBufferPointer { floatBuffer in
            buffer.withUnsafeMutableBufferPointer { uint16Buffer in
                vDSP_vfixu16(floatBuffer.baseAddress!, 1, uint16Buffer.baseAddress!, 1, vDSP_Length(count))
            }
        }
    }

    static func invertMonochrome1Vectorized(
        buffer: inout [UInt8],
        count: Int
    ) {
        guard count > 0 else { return }
        precondition(count <= buffer.count, "buffer overrun")

        var floatPixels = BufferPool.shared.acquire(type: [Float].self, count: count)
        defer { BufferPool.shared.release(floatPixels) }

        buffer.withUnsafeBufferPointer { source in
            vDSP_vfltu8(source.baseAddress!, 1, &floatPixels, 1, vDSP_Length(count))
        }
        vDSP_vneg(floatPixels, 1, &floatPixels, 1, vDSP_Length(count))
        var offset: Float = 255
        vDSP_vsadd(floatPixels, 1, &offset, &floatPixels, 1, vDSP_Length(count))
        floatPixels.withUnsafeBufferPointer { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                vDSP_vfixu8(source.baseAddress!, 1, destination.baseAddress!, 1, vDSP_Length(count))
            }
        }
    }

    /// Inversion of normalized signed 16-bit pixels for MONOCHROME1.
    /// This function performs the operation:
    /// output[i] = 65535 - input[i], matching the display inversion used
    /// for unsigned normalized pixels.
    ///
    /// - Parameters:
    ///   - buffer: Buffer of UInt16 pixels to invert in-place
    /// Inverts a 16-bit grayscale pixel buffer (after signed-to-unsigned normalization) in-place for MONOCHROME1.
    /// 
    /// The buffer is treated as unsigned 16-bit samples that were produced by normalizing signed Int16 pixels into the unsigned range; this function computes `65535 - value` for each sample, clamps results to [0, 65535], and writes them back.
    /// - Parameters:
    ///   - buffer: The pixel buffer to modify in-place. Each element is an unsigned 16-bit sample representing a previously signed pixel value.
    ///   - count: The number of samples to process from the start of `buffer`. Must be less than or equal to `buffer.count`.
    static func invertMonochrome1SignedVectorized(
        buffer: inout [UInt16],
        count: Int
    ) {
        guard count > 0 else { return }
        precondition(count <= buffer.count, "buffer overrun")

        buffer.withUnsafeMutableBufferPointer { pixels in
            guard let baseAddress = pixels.baseAddress else { return }
            for index in 0..<count {
                baseAddress[index] = UInt16.max - baseAddress[index]
            }
        }
    }

    /// Validates dimensions and computes pixel counts and byte sizes safely.
    /// Validate image dimensions and compute the total number of pixels and required byte count.
    /// - Parameters:
    ///   - bytesPerPixel: Number of bytes used to store a single pixel.
    ///   - context: Short textual context included in log messages to identify the caller or operation.
    /// - Returns: A tuple `(numPixels, numBytes)` with the total pixel count and total byte count, or `nil` if dimensions are invalid, arithmetic overflow occurs, or the computed buffer size exceeds configured limits.
    static func computePixelMetrics(
        width: Int,
        height: Int,
        bytesPerPixel: Int64,
        context: String,
        logger: LoggerProtocol?
    ) -> (numPixels: Int, numBytes: Int)? {
        guard width > 0, height > 0 else {
            logger?.warning("Invalid image dimensions: width=\(width), height=\(height)")
            return nil
        }
        if width > maxImageDimension || height > maxImageDimension {
            logger?.warning("Image dimensions exceed maximum allowed: \(width)x\(height) (max \(maxImageDimension))")
            return nil
        }

        let width64 = Int64(width)
        let height64 = Int64(height)
        let (pixelCount64, pixelOverflow) = width64.multipliedReportingOverflow(by: height64)
        if pixelOverflow || pixelCount64 <= 0 {
            logger?.warning("Pixel count overflow for \(context): width=\(width), height=\(height)")
            return nil
        }
        if pixelCount64 > Int64(Int.max) {
            logger?.warning("Pixel count exceeds addressable range for \(context): \(pixelCount64)")
            return nil
        }

        let (byteCount64, byteOverflow) = pixelCount64.multipliedReportingOverflow(by: bytesPerPixel)
        if byteOverflow || byteCount64 <= 0 {
            logger?.warning("Pixel buffer size overflow for \(context): pixels=\(pixelCount64), bytesPerPixel=\(bytesPerPixel)")
            return nil
        }
        if byteCount64 > maxPixelBufferSize {
            logger?.warning("Pixel buffer size \(byteCount64) bytes exceeds maximum allowed \(maxPixelBufferSize) bytes for \(context)")
            return nil
        }
        if byteCount64 > Int64(Int.max) {
            logger?.warning("Pixel buffer size exceeds addressable range for \(context): \(byteCount64)")
            return nil
        }

        return (numPixels: Int(pixelCount64), numBytes: Int(byteCount64))
    }

    /// Reads uncompressed pixel data from the DICOM file.  This method
    /// allocates new buffers and supports 8‑bit grayscale, 16‑bit
    /// grayscale and 8‑bit 3‑channel RGB images.  Other values of
    /// ``samplesPerPixel`` or ``bitDepth`` result in empty buffers.
    ///
    /// - Parameters:
    ///   - data: Raw DICOM file data
    ///   - width: Image width in pixels
    ///   - height: Image height in pixels
    ///   - bitDepth: Bits per sample (8 or 16)
    ///   - samplesPerPixel: Number of color channels (1 for grayscale, 3 for RGB)
    ///   - offset: Byte offset to pixel data
    ///   - pixelRepresentation: 0 for unsigned, 1 for two's complement signed
    ///   - littleEndian: True for little endian byte order
    ///   - photometricInterpretation: MONOCHROME1 or MONOCHROME2
    ///   - logger: Optional logger for performance metrics
    /// Reads pixel data from a DICOM data buffer and produces a DCMPixelReadResult containing decoded pixel arrays and metadata.
    /// - Parameters:
    ///   - data: Source data containing pixel bytes.
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - bitDepth: Bits per sample (e.g., 8 or 16).
    ///   - samplesPerPixel: Number of samples per pixel (1 for grayscale, 3 for RGB).
    ///   - offset: Byte offset within `data` where the pixel codestream begins.
    ///   - pixelRepresentation: Pixel value representation: `0` = unsigned, `1` = two's-complement signed.
    ///   - littleEndian: `true` if pixel bytes are in little-endian order, `false` for big-endian.
    ///   - photometricInterpretation: Photometric interpretation string (e.g., "MONOCHROME1" or "MONOCHROME2"); when "MONOCHROME1" grayscale samples are inverted.
    /// - Returns: A DCMPixelReadResult with one of these populated depending on format:
    ///            - `pixels8` for 8-bit grayscale,
    ///            - `pixels16` for 16-bit grayscale (with `signedImage` set when pixelRepresentation == 1),
    ///            - `pixels24` for 24-bit RGB (3 bytes per pixel).
    ///          If the input combination is unsupported or validation fails, the result contains nil buffers and the provided metadata.
    internal static func readPixels(
        data: Data,
        width: Int,
        height: Int,
        bitDepth: Int,
        samplesPerPixel: Int,
        offset: Int,
        pixelRepresentation: Int,
        littleEndian: Bool,
        photometricInterpretation: String,
        logger: LoggerProtocol? = nil
    ) -> DCMPixelReadResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        var result = DCMPixelReadResult(
            pixels8: nil,
            pixels16: nil,
            pixels24: nil,
            signedImage: false,
            width: width,
            height: height,
            bitDepth: bitDepth,
            samplesPerPixel: samplesPerPixel
        )

        // Grayscale 8‑bit
        if samplesPerPixel == 1 && bitDepth == 8 {
            guard let metrics = computePixelMetrics(
                width: width,
                height: height,
                bytesPerPixel: 1,
                context: "8-bit grayscale",
                logger: logger
            ) else {
                return result
            }
            let numPixels = metrics.numPixels
            guard offset > 0, offset <= data.count, numPixels <= data.count - offset else {
                logger?.warning("Invalid offset or insufficient data. offset=\(offset), needed=\(numPixels), available=\(max(0, data.count - offset))")
                return result
            }
            result.pixels8 = Array(data[offset..<offset + numPixels])

            // Handle MONOCHROME1 (white is zero) - common for X-rays
            if photometricInterpretation == "MONOCHROME1" {
                if var p8 = result.pixels8 {
                    invertMonochrome1Vectorized(buffer: &p8, count: numPixels)
                    result.pixels8 = p8
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger?.debug("[PERF] readPixels (8-bit): \(String(format: "%.2f", elapsed))ms | size: \(width)x\(height)")
            return result
        }

        // Grayscale 16‑bit
        if samplesPerPixel == 1 && bitDepth == 16 {
            guard let metrics = computePixelMetrics(
                width: width,
                height: height,
                bytesPerPixel: 2,
                context: "16-bit grayscale",
                logger: logger
            ) else {
                return result
            }
            let numPixels = metrics.numPixels
            let numBytes = metrics.numBytes

            guard offset > 0, offset <= data.count, numBytes <= data.count - offset else {
                logger?.warning("Invalid offset or insufficient data. offset=\(offset), needed=\(numBytes), available=\(data.count - offset)")
                return result
            }

            var pixels = data.withUnsafeBytes { dataBytes in
                let basePtr = dataBytes.baseAddress!.advanced(by: offset)

                return [UInt16](unsafeUninitializedCapacity: numPixels) { pixelBuffer, initializedCount in
                    guard let destination = pixelBuffer.baseAddress else {
                        initializedCount = 0
                        return
                    }

                    if pixelRepresentation == 0 {
                        // Unsigned pixels - most common for CR/DX
                        _ = memcpy(destination, basePtr, numBytes)
                        if !littleEndian {
                            for index in 0..<numPixels {
                                destination[index] = destination[index].byteSwapped
                            }
                        }
                        result.signedImage = false
                    } else {
                        // Signed pixels (less common) - normalize directly into the final buffer.
                        result.signedImage = true
                        writeNormalizedSigned16(
                            sourcePtr: basePtr,
                            outputBuffer: pixelBuffer,
                            count: numPixels,
                            littleEndian: littleEndian,
                            inverted: photometricInterpretation == "MONOCHROME1"
                        )
                    }

                    initializedCount = numPixels
                }
            }

            if photometricInterpretation == "MONOCHROME1" {
                if !result.signedImage {
                    invertMonochrome1Vectorized(buffer: &pixels, count: numPixels)
                }
            }

            result.pixels16 = pixels

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger?.debug("[PERF] readPixels (16-bit): \(String(format: "%.2f", elapsed))ms | size: \(width)x\(height)")
            return result
        }

        // Colour 8‑bit RGB
        if samplesPerPixel == 3 && bitDepth == 8 {
            result.signedImage = false
            guard let metrics = computePixelMetrics(
                width: width,
                height: height,
                bytesPerPixel: 3,
                context: "24-bit RGB",
                logger: logger
            ) else {
                return result
            }
            let numBytes = metrics.numBytes
            guard offset > 0, offset <= data.count, numBytes <= data.count - offset else {
                logger?.warning("Invalid offset or insufficient data. offset=\(offset), needed=\(numBytes), available=\(max(0, data.count - offset))")
                return result
            }
            result.pixels24 = Array(data[offset..<offset + numBytes])

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            logger?.debug("[PERF] readPixels (24-bit RGB): \(String(format: "%.2f", elapsed))ms | size: \(width)x\(height)")
            return result
        }

        // Fallback: leave buffers nil
        return result
    }

    // MARK: - Range-Based Pixel Reading Methods

    /// Reads a range of 16-bit grayscale pixels from uncompressed DICOM data.
    /// This method enables streaming access by reading only the requested
    /// pixel range instead of the entire image buffer.
    ///
    /// - Parameters:
    ///   - data: Raw DICOM file data
    ///   - range: Range of pixel indices to read (e.g., 0..<100 for first 100 pixels)
    ///   - width: Image width in pixels
    ///   - height: Image height in pixels
    ///   - offset: Byte offset to start of pixel data in file
    ///   - pixelRepresentation: 0 for unsigned, 1 for two's complement signed
    ///   - littleEndian: True for little endian byte order
    ///   - photometricInterpretation: MONOCHROME1 or MONOCHROME2
    ///   - logger: Optional logger for performance metrics
    /// Reads a contiguous range of 16-bit grayscale pixels from DICOM pixel data.
    /// - Parameters:
    ///   - data: The raw pixel data buffer.
    ///   - range: The pixel index range (0-based) to read from the image (inclusive lower bound, exclusive upper bound).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - offset: Byte offset in `data` where pixel data starts.
    ///   - pixelRepresentation: 0 for unsigned pixel samples, 1 for signed pixel samples; used to determine interpretation and normalization.
    ///   - littleEndian: `true` if stored pixel pairs are little-endian, `false` for big-endian.
    ///   - photometricInterpretation: Photometric interpretation string (e.g., `"MONOCHROME1"` or `"MONOCHROME2"`); affects value inversion for `MONOCHROME1`.
    ///   - logger: Optional logger for warnings and performance debug messages (may be omitted).
    /// - Returns: A `DCMPixelReadResult` whose `pixels16` contains the requested 16-bit pixel values and whose metadata (width, height, bitDepth=16, samplesPerPixel=1, `signedImage`) reflects the read; returns `nil` if dimensions, range, or data bounds are invalid.
}
