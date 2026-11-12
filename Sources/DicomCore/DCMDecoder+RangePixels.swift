//
//  DCMDecoder+RangePixels.swift
//  DicomCore
//
//  Range-based and downsampled pixel access for DCMDecoder.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

extension DCMDecoder {

    /// Computes aspect-preserving thumbnail dimensions and sampling steps.
    /// - Parameters:
    ///   - sourceWidth: Original image width in pixels.
    ///   - sourceHeight: Original image height in pixels.
    ///   - maxDimension: Maximum allowed width or height for the thumbnail.
    /// - Returns: Tuple with thumbWidth, thumbHeight, xStep, yStep.
    private func thumbnailDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        maxDimension: Int
    ) -> (thumbWidth: Int, thumbHeight: Int, xStep: Double, yStep: Double) {
        let aspectRatio = Double(sourceWidth) / Double(sourceHeight)
        var thumbWidth: Int
        var thumbHeight: Int

        if sourceWidth > sourceHeight {
            thumbWidth = min(sourceWidth, maxDimension)
            thumbHeight = Int(Double(thumbWidth) / aspectRatio)
        } else {
            thumbHeight = min(sourceHeight, maxDimension)
            thumbWidth = Int(Double(thumbHeight) * aspectRatio)
        }

        thumbWidth = max(1, thumbWidth)
        thumbHeight = max(1, thumbHeight)

        let xStep = Double(sourceWidth) / Double(thumbWidth)
        let yStep = Double(sourceHeight) / Double(thumbHeight)
        return (thumbWidth, thumbHeight, xStep, yStep)
    }

    private func canReadRawPixelsForDownsampling(
        expectedBitDepth: Int,
        bytesPerPixel: Int,
        maxDimension: Int,
        context: String
    ) -> Bool {
        guard fileReadSucceeded else {
            logger.warning("\(context) requires a successfully loaded DICOM file")
            return false
        }
        guard !compressedImage else {
            logger.warning("\(context) requires uncompressed pixel data")
            return false
        }
        guard maxDimension > 0 else {
            logger.warning("\(context) requires maxDimension > 0")
            return false
        }
        guard samplesPerPixel == 1 && bitDepth == expectedBitDepth else {
            logger.warning("\(context) requires \(expectedBitDepth)-bit grayscale image (bitDepth=\(bitDepth), samplesPerPixel=\(samplesPerPixel))")
            return false
        }

        let width64 = Int64(width)
        let height64 = Int64(height)
        guard width64 > 0, height64 > 0 else {
            logger.warning("\(context) requires positive dimensions (width=\(width), height=\(height))")
            return false
        }

        let (pixelCount, pixelOverflow) = width64.multipliedReportingOverflow(by: height64)
        let (expectedByteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: Int64(bytesPerPixel))
        let (endOffset, offsetOverflow) = Int64(offset).addingReportingOverflow(expectedByteCount)
        guard !pixelOverflow, !byteOverflow, !offsetOverflow else {
            logger.warning("\(context) pixel byte range overflow")
            return false
        }
        let dataCount = dicomDataCount()
        guard offset >= 0, endOffset <= Int64(dataCount) else {
            let available = max(0, dataCount - max(0, offset))
            logger.warning("\(context) requires \(expectedByteCount) bytes at offset \(offset), available \(available)")
            return false
        }

        return true
    }

    /// Creates an aspect-preserving downsampled 16-bit grayscale thumbnail from the image pixel data.
    /// The result preserves the source aspect ratio, produces row-major UInt16 pixel values, and accounts for MONOCHROME1 inversion when present.
    /// - Parameters:
    ///   - maxDimension: The maximum width or height for the thumbnail in pixels; the other dimension is scaled to preserve aspect ratio.
    /// - Returns: A tuple containing `pixels` (row-major downsampled `UInt16` values), `width`, and `height`; returns `nil` if the image is not 16-bit single-channel or pixel data is unavailable.
    public func getDownsampledPixels16(maxDimension: Int = 150) -> (pixels: [UInt16], width: Int, height: Int)? {
        synchronized {
            guard canReadRawPixelsForDownsampling(
                expectedBitDepth: 16,
                bytesPerPixel: MemoryLayout<UInt16>.size,
                maxDimension: maxDimension,
                context: "getDownsampledPixels16"
            ) else {
                return nil
            }

            let startTime = CFAbsoluteTimeGetCurrent()
            let (thumbWidth, thumbHeight, xStep, yStep) = thumbnailDimensions(
                sourceWidth: width, sourceHeight: height, maxDimension: maxDimension
            )

            logger.debug("Downsampling \(width)x\(height) -> \(thumbWidth)x\(thumbHeight) (step: \(String(format: "%.2f", xStep))x\(String(format: "%.2f", yStep)))")

            var downsampledPixels = [UInt16](repeating: 0, count: thumbWidth * thumbHeight)

            let data = dicomDataSnapshot()
            let isLittleEndian = currentLittleEndian()
            data.withUnsafeBytes { dataBytes in
                let basePtr = dataBytes.baseAddress!.advanced(by: offset)

                for thumbY in 0..<thumbHeight {
                    for thumbX in 0..<thumbWidth {
                        let sourceX = min(Int(Double(thumbX) * xStep), width - 1)
                        let sourceY = min(Int(Double(thumbY) * yStep), height - 1)
                        let sourceIndex = (sourceY * width + sourceX) * 2
                        let thumbIndex = thumbY * thumbWidth + thumbX

                        let b0 = basePtr.advanced(by: sourceIndex).assumingMemoryBound(to: UInt8.self).pointee
                        let b1 = basePtr.advanced(by: sourceIndex + 1).assumingMemoryBound(to: UInt8.self).pointee

                        var value = isLittleEndian ? UInt16(b1) << 8 | UInt16(b0)
                                                  : UInt16(b0) << 8 | UInt16(b1)
                        if pixelRepresentationTagValue == 1 {
                            let signedValue = Int16(bitPattern: value)
                            value = UInt16(Int(signedValue) - Int(Int16.min))
                        }
                        if photometricInterpretation == "MONOCHROME1" {
                            value = 65535 - value
                        }
                        downsampledPixels[thumbIndex] = value
                    }
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            debugPerfLog("[PERF] getDownsampledPixels16: \(String(format: "%.2f", elapsed))ms | thumbSize: \(thumbWidth)x\(thumbHeight)")

            return (downsampledPixels, thumbWidth, thumbHeight)
        }
    }

    /// Creates an aspect-preserving downsampled 8-bit grayscale thumbnail from the image pixel data.
    /// The result preserves the source aspect ratio, produces row-major UInt8 pixel values, and accounts for MONOCHROME1 inversion when present.
    /// - Parameters:
    ///   - maxDimension: The maximum width or height for the thumbnail in pixels; the other dimension is scaled to preserve aspect ratio.
    /// - Returns: A tuple containing `pixels` (row-major downsampled `UInt8` values), `width`, and `height`; returns `nil` if the image is not 8-bit single-channel or pixel data is unavailable.
    public func getDownsampledPixels8(maxDimension: Int = 150) -> (pixels: [UInt8], width: Int, height: Int)? {
        synchronized {
            guard canReadRawPixelsForDownsampling(
                expectedBitDepth: 8,
                bytesPerPixel: MemoryLayout<UInt8>.size,
                maxDimension: maxDimension,
                context: "getDownsampledPixels8"
            ) else {
                return nil
            }

            let startTime = CFAbsoluteTimeGetCurrent()
            let (thumbWidth, thumbHeight, xStep, yStep) = thumbnailDimensions(
                sourceWidth: width, sourceHeight: height, maxDimension: maxDimension
            )

            logger.debug("Downsampling \(width)x\(height) -> \(thumbWidth)x\(thumbHeight) (step: \(String(format: "%.2f", xStep))x\(String(format: "%.2f", yStep)))")

            var downsampledPixels = [UInt8](repeating: 0, count: thumbWidth * thumbHeight)

            let data = dicomDataSnapshot()
            data.withUnsafeBytes { dataBytes in
                let basePtr = dataBytes.baseAddress!.advanced(by: offset)

                for thumbY in 0..<thumbHeight {
                    for thumbX in 0..<thumbWidth {
                        let sourceX = min(Int(Double(thumbX) * xStep), width - 1)
                        let sourceY = min(Int(Double(thumbY) * yStep), height - 1)
                        let sourceIndex = sourceY * width + sourceX
                        let thumbIndex = thumbY * thumbWidth + thumbX

                        var value = basePtr.advanced(by: sourceIndex).assumingMemoryBound(to: UInt8.self).pointee
                        if photometricInterpretation == "MONOCHROME1" {
                            value = 255 - value
                        }
                        downsampledPixels[thumbIndex] = value
                    }
                }
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            debugPerfLog("[PERF] getDownsampledPixels8: \(String(format: "%.2f", elapsed))ms | thumbSize: \(thumbWidth)x\(thumbHeight)")

            return (downsampledPixels, thumbWidth, thumbHeight)
        }
    }

    /// Reads a contiguous range of 8-bit pixel samples from the decoded DICOM image.
    /// - Parameters:
    ///   - range: A 0-based half-open range of pixel indices within the image (upperBound is exclusive).
    /// - Returns: An array of `UInt8` pixel values for the requested range, or `nil` if the file was not read, the range is out of bounds, or reading failed.
    public func getPixels8(range: Range<Int>) -> [UInt8]? {
        synchronized {
            let startTime = CFAbsoluteTimeGetCurrent()

            guard fileReadSucceeded else {
                return nil
            }
            guard !compressedImage else {
                logger.warning("getPixels8(range:) requires uncompressed pixel data")
                return nil
            }
            guard bitDepth == 8, samplesPerPixel == 1 else {
                logger.warning("getPixels8(range:) called on non-8-bit grayscale image (bitDepth=\(bitDepth), samplesPerPixel=\(samplesPerPixel))")
                return nil
            }

            let totalPixels = width * height
            guard range.lowerBound >= 0, range.upperBound <= totalPixels else {
                logger.warning("Range out of bounds: \(range) (total pixels: \(totalPixels))")
                return nil
            }

            guard let result = DCMPixelReader.readPixels8(
                data: dicomDataSnapshot(),
                range: range,
                width: width,
                height: height,
                offset: offset,
                photometricInterpretation: photometricInterpretation,
                logger: logger
            ) else {
                return nil
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if elapsed > 1 {
                debugPerfLog("[PERF] getPixels8(range): \(String(format: "%.2f", elapsed))ms | range: \(range.lowerBound)..<\(range.upperBound)")
            }

            return result.pixels8
        }
    }

    /// Retrieve a contiguous subset of 16-bit pixel samples specified by a linear pixel index range.
    /// - Parameters:
    ///   - range: A half-open range of linear pixel indices (0..<(width * height)); upper bound is exclusive.
    /// - Returns: An array of `UInt16` pixel values covering `range`, or `nil` if the file was not read successfully, the range is out of bounds, or pixel reading failed.
    public func getPixels16(range: Range<Int>) -> [UInt16]? {
        synchronized {
            let startTime = CFAbsoluteTimeGetCurrent()

            guard fileReadSucceeded else {
                return nil
            }
            guard !compressedImage else {
                logger.warning("getPixels16(range:) requires uncompressed pixel data")
                return nil
            }
            guard bitDepth == 16, samplesPerPixel == 1 else {
                logger.warning("getPixels16(range:) called on non-16-bit grayscale image (bitDepth=\(bitDepth), samplesPerPixel=\(samplesPerPixel))")
                return nil
            }

            let totalPixels = width * height
            guard range.lowerBound >= 0, range.upperBound <= totalPixels else {
                logger.warning("Range out of bounds: \(range) (total pixels: \(totalPixels))")
                return nil
            }

            guard let result = DCMPixelReader.readPixels16(
                data: dicomDataSnapshot(),
                range: range,
                width: width,
                height: height,
                offset: offset,
                pixelRepresentation: pixelRepresentationTagValue,
                littleEndian: currentLittleEndian(),
                photometricInterpretation: photometricInterpretation,
                logger: logger
            ) else {
                return nil
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if elapsed > 1 {
                debugPerfLog("[PERF] getPixels16(range): \(String(format: "%.2f", elapsed))ms | range: \(range.lowerBound)..<\(range.upperBound)")
            }

            return result.pixels16
        }
    }

    /// Returns the 24-bit RGB pixel bytes for a contiguous range of pixel indices.
    /// - Parameters:
    ///   - range: A range of pixel indices (0-based) within the image; upper bound must be <= width * height.
    /// - Returns: An array of `UInt8` containing interleaved RGB bytes (`R,G,B` per pixel) for the requested range, or `nil` if the file was not read successfully, the range is invalid, or reading failed.
    public func getPixels24(range: Range<Int>) -> [UInt8]? {
        synchronized {
            let startTime = CFAbsoluteTimeGetCurrent()

            guard fileReadSucceeded else {
                return nil
            }
            guard !compressedImage else {
                logger.warning("getPixels24(range:) requires uncompressed pixel data")
                return nil
            }
            guard samplesPerPixel == 3 else {
                logger.warning("getPixels24(range:) requires samplesPerPixel == 3 (RGB). Found \(samplesPerPixel)")
                return nil
            }
            let bitsAllocated = Int(info(for: DicomTag.bitsAllocated.rawValue)) ?? bitDepth
            guard bitsAllocated == 8 else {
                logger.warning("getPixels24(range:) requires BitsAllocated == 8. Found \(bitsAllocated)")
                return nil
            }
            if let planarConfiguration = Int(info(for: DicomTag.planarConfiguration.rawValue)),
               planarConfiguration != 0 {
                logger.warning("getPixels24(range:) requires interleaved RGB (planarConfiguration == 0). Found \(planarConfiguration)")
                return nil
            }

            let totalPixels = width * height
            guard range.lowerBound >= 0, range.upperBound <= totalPixels else {
                logger.warning("Range out of bounds: \(range) (total pixels: \(totalPixels))")
                return nil
            }

            guard let result = DCMPixelReader.readPixels24(
                data: dicomDataSnapshot(),
                range: range,
                width: width,
                height: height,
                offset: offset,
                logger: logger
            ) else {
                return nil
            }

            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if elapsed > 1 {
                debugPerfLog("[PERF] getPixels24(range): \(String(format: "%.2f", elapsed))ms | range: \(range.lowerBound)..<\(range.upperBound)")
            }

            return result.pixels24
        }
    }
}
