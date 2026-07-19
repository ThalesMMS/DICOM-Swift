//
//  DCMPixelReader+Range.swift
//
//  Range-based pixel access helpers for DCMPixelReader.
//

import Foundation

extension DCMPixelReader {

    /// Validates a pixel range and computes byte-level offsets for pixel reading.
    /// - Parameters:
    ///   - range: Half-open range of pixel indices to read.
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - bytesPerPixel: Bytes per pixel (1, 2, or 3).
    ///   - offset: Byte offset in data where pixel data begins.
    ///   - dataCount: Total byte count of the data buffer.
    ///   - logger: Optional logger for diagnostic messages.
    /// - Returns: A tuple (rangeCount, rangeBytes, rangeByteOffset) on success, nil if any check fails.
    private static func validatePixelRange(
        range: Range<Int>,
        width: Int,
        height: Int,
        bytesPerPixel: Int64,
        offset: Int,
        dataCount: Int,
        logger: LoggerProtocol?
    ) -> (rangeCount: Int, rangeBytes: Int, rangeByteOffset: Int)? {
        let width64 = Int64(width)
        let height64 = Int64(height)
        let (totalPixels64, totalOverflow) = width64.multipliedReportingOverflow(by: height64)
        guard !totalOverflow && totalPixels64 > 0 else {
            logger?.warning("Pixel count overflow for range: width=\(width), height=\(height)")
            return nil
        }
        guard totalPixels64 <= Int64(Int.max) else {
            logger?.warning("Pixel count exceeds addressable range for range: \(totalPixels64)")
            return nil
        }

        let lower64 = Int64(range.lowerBound)
        let upper64 = Int64(range.upperBound)
        guard lower64 >= 0, upper64 <= totalPixels64 else {
            logger?.warning("Range out of bounds: \(range) (total pixels: \(totalPixels64))")
            return nil
        }
        guard upper64 > lower64 else {
            logger?.warning("Empty range requested")
            return nil
        }

        let rangeCount64 = upper64 - lower64
        guard rangeCount64 <= Int64(Int.max) else {
            logger?.warning("Range size exceeds addressable range: \(range)")
            return nil
        }

        let (rangeBytes64, rangeBytesOverflow) = rangeCount64.multipliedReportingOverflow(by: bytesPerPixel)
        let (pixelOffset64, pixelOffsetOverflow) = lower64.multipliedReportingOverflow(by: bytesPerPixel)
        let (rangeByteOffset64, offsetOverflow) = Int64(offset).addingReportingOverflow(pixelOffset64)
        guard !rangeBytesOverflow && !pixelOffsetOverflow && !offsetOverflow else {
            logger?.warning("Byte offset overflow for range: \(range)")
            return nil
        }
        guard rangeBytes64 <= Int64(Int.max), rangeByteOffset64 <= Int64(Int.max) else {
            logger?.warning("Byte offset exceeds addressable range for range: \(range)")
            return nil
        }

        let dataCount64 = Int64(dataCount)
        guard rangeByteOffset64 >= 0,
              rangeByteOffset64 <= dataCount64,
              rangeBytes64 <= dataCount64 - rangeByteOffset64 else {
            let available = max(Int64(0), dataCount64 - rangeByteOffset64)
            logger?.warning("Invalid range offset or insufficient data. offset=\(rangeByteOffset64), needed=\(rangeBytes64), available=\(available)")
            return nil
        }

        return (Int(rangeCount64), Int(rangeBytes64), Int(rangeByteOffset64))
    }

    internal static func readPixels16(
        data: Data,
        range: Range<Int>,
        width: Int,
        height: Int,
        offset: Int,
        pixelRepresentation: Int,
        littleEndian: Bool,
        photometricInterpretation: String,
        logger: LoggerProtocol? = nil
    ) -> DCMPixelReadResult? {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard computePixelMetrics(
            width: width,
            height: height,
            bytesPerPixel: 2,
            context: "16-bit grayscale (range)",
            logger: logger
        ) != nil else {
            return nil
        }

        guard let (rangeCount, rangeBytes, rangeByteOffset) = validatePixelRange(
            range: range,
            width: width,
            height: height,
            bytesPerPixel: 2,
            offset: offset,
            dataCount: data.count,
            logger: logger
        ) else {
            return nil
        }

        var result = DCMPixelReadResult(
            pixels8: nil,
            pixels16: nil,
            pixels24: nil,
            signedImage: pixelRepresentation == 1,
            width: width,
            height: height,
            bitDepth: 16,
            samplesPerPixel: 1
        )

        var pixels = Array(repeating: UInt16(0), count: rangeCount)

        data.withUnsafeBytes { dataBytes in
            let basePtr = dataBytes.baseAddress!.advanced(by: rangeByteOffset)

            if pixelRepresentation == 0 {
                if littleEndian {
                    pixels.withUnsafeMutableBufferPointer { pixelBuffer in
                        _ = memcpy(pixelBuffer.baseAddress!, basePtr, rangeBytes)
                    }
                    if photometricInterpretation == "MONOCHROME1" {
                        invertMonochrome1Vectorized(buffer: &pixels, count: rangeCount)
                    }
                } else {
                    pixels.withUnsafeMutableBufferPointer { pixelBuffer in
                        _ = memcpy(pixelBuffer.baseAddress!, basePtr, rangeBytes)
                        let pixelPtr = pixelBuffer.baseAddress!
                        for i in 0..<rangeCount {
                            pixelPtr[i] = pixelPtr[i].byteSwapped
                        }
                    }
                    if photometricInterpretation == "MONOCHROME1" {
                        invertMonochrome1Vectorized(buffer: &pixels, count: rangeCount)
                    }
                }
            } else {
                normaliseSigned16Vectorized(
                    sourcePtr: basePtr,
                    outputBuffer: &pixels,
                    count: rangeCount,
                    littleEndian: littleEndian
                )
                if photometricInterpretation == "MONOCHROME1" {
                    invertMonochrome1SignedVectorized(buffer: &pixels, count: rangeCount)
                }
            }
        }

        result.pixels16 = pixels

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger?.debug("[PERF] readPixels16 (range): \(String(format: "%.2f", elapsed))ms | range: \(range.lowerBound)..<\(range.upperBound) | size: \(width)x\(height)")
        return result
    }

    internal static func readPixels8(
        data: Data,
        range: Range<Int>,
        width: Int,
        height: Int,
        offset: Int,
        photometricInterpretation: String,
        logger: LoggerProtocol? = nil
    ) -> DCMPixelReadResult? {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard computePixelMetrics(
            width: width,
            height: height,
            bytesPerPixel: 1,
            context: "8-bit grayscale (range)",
            logger: logger
        ) != nil else {
            return nil
        }

        guard let (rangeCount, rangeBytes, rangeByteOffset) = validatePixelRange(
            range: range,
            width: width,
            height: height,
            bytesPerPixel: 1,
            offset: offset,
            dataCount: data.count,
            logger: logger
        ) else {
            return nil
        }

        var result = DCMPixelReadResult(
            pixels8: nil,
            pixels16: nil,
            pixels24: nil,
            signedImage: false,
            width: width,
            height: height,
            bitDepth: 8,
            samplesPerPixel: 1
        )

        var pixels: [UInt8]
        var pooledBuffer: [UInt8]? = nil
        if rangeCount <= 4194304 {
            pooledBuffer = BufferPool.shared.acquire(type: [UInt8].self, count: rangeCount)
            pixels = pooledBuffer!
        } else {
            pixels = Array(repeating: 0, count: rangeCount)
        }
        defer {
            if let buffer = pooledBuffer {
                BufferPool.shared.release(buffer)
            }
        }

        data.withUnsafeBytes { dataBytes in
            let basePtr = dataBytes.baseAddress!.advanced(by: rangeByteOffset)
            let uint8Ptr = basePtr.assumingMemoryBound(to: UInt8.self)
            pixels.withUnsafeMutableBufferPointer { pixelBuffer in
                guard let destination = pixelBuffer.baseAddress else { return }
                _ = memcpy(destination, uint8Ptr, rangeBytes)
            }
        }
        if photometricInterpretation == "MONOCHROME1" {
            invertMonochrome1Vectorized(buffer: &pixels, count: rangeCount)
        }

        result.pixels8 = pooledBuffer == nil ? pixels : Array(pixels[0..<min(rangeCount, pixels.count)])

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger?.debug("[PERF] readPixels8 (range): \(String(format: "%.2f", elapsed))ms | range: \(range.lowerBound)..<\(range.upperBound) | size: \(width)x\(height)")
        return result
    }

    internal static func readPixels24(
        data: Data,
        range: Range<Int>,
        width: Int,
        height: Int,
        offset: Int,
        logger: LoggerProtocol? = nil
    ) -> DCMPixelReadResult? {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard computePixelMetrics(
            width: width,
            height: height,
            bytesPerPixel: 3,
            context: "24-bit RGB (range)",
            logger: logger
        ) != nil else {
            return nil
        }

        guard let (_, rangeBytes, rangeByteOffset) = validatePixelRange(
            range: range,
            width: width,
            height: height,
            bytesPerPixel: 3,
            offset: offset,
            dataCount: data.count,
            logger: logger
        ) else {
            return nil
        }

        var result = DCMPixelReadResult(
            pixels8: nil,
            pixels16: nil,
            pixels24: nil,
            signedImage: false,
            width: width,
            height: height,
            bitDepth: 8,
            samplesPerPixel: 3
        )

        var pixels: [UInt8]
        var pooledBuffer: [UInt8]? = nil
        if rangeBytes <= 4_194_304 {
            pooledBuffer = BufferPool.shared.acquire(type: [UInt8].self, count: rangeBytes)
            pixels = pooledBuffer!
        } else {
            pixels = Array(repeating: 0, count: rangeBytes)
        }
        defer {
            if let buffer = pooledBuffer {
                BufferPool.shared.release(buffer)
            }
        }

        data.withUnsafeBytes { dataBytes in
            let basePtr = dataBytes.baseAddress!.advanced(by: rangeByteOffset)
            let uint8Ptr = basePtr.assumingMemoryBound(to: UInt8.self)
            pixels.withUnsafeMutableBufferPointer { pixelBuffer in
                _ = memcpy(pixelBuffer.baseAddress!, uint8Ptr, rangeBytes)
            }
        }

        result.pixels24 = pooledBuffer == nil ? pixels : Array(pixels[0..<min(rangeBytes, pixels.count)])

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        logger?.debug("[PERF] readPixels24 (range): \(String(format: "%.2f", elapsed))ms | range: \(range.lowerBound)..<\(range.upperBound) | size: \(width)x\(height)")
        return result
    }
}
