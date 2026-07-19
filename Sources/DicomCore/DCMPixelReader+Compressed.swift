//
//  DCMPixelReader+Compressed.swift
//
//  Compressed pixel decoding helpers for DCMPixelReader.
//

import Foundation
import CoreGraphics
import ImageIO

internal enum DicomCompressedPixelBackendResolver {
    static func resolve(
        transferSyntax: DicomTransferSyntax?,
        requestedBitDepth: Int?,
        samplesPerPixel: Int?,
        photometricInterpretation: String? = nil,
        bitsStored: Int? = nil
    ) -> DicomCompressedPixelBackendDecision {
        DicomCompressedPixelBackendRegistry.resolve(
            transferSyntax: transferSyntax,
            requestedBitDepth: requestedBitDepth,
            samplesPerPixel: samplesPerPixel,
            photometricInterpretation: photometricInterpretation,
            bitsStored: bitsStored
        )
    }
}

extension DCMPixelReader {

    internal static func makeCompressedResult(
        from frame: DicomCodecDecodedFrame,
        pixelRepresentation: Int,
        photometricInterpretation: String
    ) -> DCMPixelReadResult? {
        makeResult(
            bytes: frame.buffer.data,
            width: frame.width,
            height: frame.height,
            bitsPerSample: frame.bitsPerSample,
            componentCount: frame.componentCount,
            pixelRepresentation: pixelRepresentation,
            photometricInterpretation: photometricInterpretation
        )
    }

    /// Decode compressed image bytes starting at `offset` and produce a `DCMPixelReadResult`.
    /// 
    /// Detects JPEG Lossless streams and decodes them into 16-bit pixel data; for other formats it uses ImageIO/Core Graphics to decode into either 8-bit grayscale (`pixels8`) or packed 24-bit RGB (`pixels24`). Returns `nil` when the data cannot be parsed, decoded, or rendered into a pixel buffer (for example: invalid image source, failed decode, or inability to create/get CGContext data).
    /// - Parameters:
    ///   - data: The full data buffer containing the compressed image bytes.
    ///   - offset: The byte index within `data` where the compressed image begins.
    ///   - pixelRepresentation: DICOM Pixel Representation value (`1` for signed pixel data).
    ///   - logger: An optional logger for warning messages when decoding fails.
    /// - Returns: A `DCMPixelReadResult` populated with decoded pixels and image metadata, or `nil` if decoding failed.
    internal static func decodeCompressedPixelData(
        data: Data,
        offset: Int,
        transferSyntax: DicomTransferSyntax? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bitDepth: Int? = nil,
        samplesPerPixel: Int? = nil,
        pixelRepresentation: Int = 0,
        photometricInterpretation: String = "MONOCHROME2",
        bitsStored: Int? = nil,
        logger: LoggerProtocol? = nil
    ) -> DCMPixelReadResult? {
        guard offset > 0, offset <= data.count else {
            logger?.warning("Invalid compressed pixel data offset: \(offset) (data count: \(data.count))")
            return nil
        }

        let compressedData = data.subdata(in: offset..<data.count)
        return decodeCompressedFrameData(
            data: compressedData,
            transferSyntax: transferSyntax,
            width: width,
            height: height,
            bitDepth: bitDepth,
            samplesPerPixel: samplesPerPixel,
            pixelRepresentation: pixelRepresentation,
            photometricInterpretation: photometricInterpretation,
            bitsStored: bitsStored,
            logger: logger
        )
    }

    internal static func decodeCompressedFrameData(
        data compressedData: Data,
        transferSyntax: DicomTransferSyntax? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bitDepth: Int? = nil,
        samplesPerPixel: Int? = nil,
        pixelRepresentation: Int = 0,
        photometricInterpretation: String = "MONOCHROME2",
        bitsStored: Int? = nil,
        logger: LoggerProtocol? = nil
    ) -> DCMPixelReadResult? {
        let backendDecision = DicomCompressedPixelBackendResolver.resolve(
            transferSyntax: transferSyntax,
            requestedBitDepth: bitDepth,
            samplesPerPixel: samplesPerPixel,
            photometricInterpretation: photometricInterpretation,
            bitsStored: bitsStored
        )

        switch backendDecision.backend {
        case .nativeRLELossless:
            guard let width, let height, let bitDepth, let samplesPerPixel else {
                logger?.warning("RLE Lossless decode requires image dimensions, bit depth, and samples per pixel")
                return nil
            }
            do {
                return try DicomRLELosslessDecoder.decode(
                    frame: compressedData,
                    width: width,
                    height: height,
                    bitsAllocated: bitDepth,
                    samplesPerPixel: samplesPerPixel,
                    pixelRepresentation: pixelRepresentation,
                    photometricInterpretation: photometricInterpretation
                )
            } catch {
                logger?.warning("RLE Lossless decoding failed: \(error)")
                return nil
            }

        case .nativeJPEGLS:
            do {
                let decoded = try DicomJPEGLSCodec.decode(compressedData)
                return makeResult(
                    from: decoded,
                    pixelRepresentation: pixelRepresentation,
                    photometricInterpretation: photometricInterpretation
                )
            } catch {
                logger?.warning("JPEG-LS decoding failed: \(error)")
                return nil
            }

        case .nativeJPEGLossless:
            return decodeJPEGLosslessFrame(
                compressedData,
                pixelRepresentation: pixelRepresentation,
                photometricInterpretation: photometricInterpretation,
                logger: logger
            )

        case .nativeJPEGExtended:
            do {
                let frame = try JPEGExtendedDecoder.decode(compressedData)
                return makeGrayscaleResult(
                    pixels: frame.pixels,
                    width: frame.width,
                    height: frame.height,
                    bitDepth: frame.precision,
                    pixelRepresentation: pixelRepresentation,
                    photometricInterpretation: photometricInterpretation
                )
            } catch {
                logger?.warning("JPEG Extended native decoding failed: \(error)")
                return nil
            }

        case .imageIOJPEGBaseline, .imageIOJPEGExtended, .imageIOJPEG2000:
            return decodeImageIOFrame(
                compressedData,
                backend: backendDecision.backend,
                requestedBitDepth: bitDepth,
                pixelRepresentation: pixelRepresentation,
                photometricInterpretation: photometricInterpretation,
                logger: logger
            )

        case .openJPEG2000:
            do {
                let decoded = try DicomJPEG2000Codec.decode(compressedData)
                return makeResult(
                    bytes: decoded.bytes,
                    width: decoded.width,
                    height: decoded.height,
                    bitsPerSample: decoded.bitsPerSample,
                    componentCount: decoded.componentCount,
                    pixelRepresentation: pixelRepresentation,
                    photometricInterpretation: photometricInterpretation
                )
            } catch {
                logger?.warning("JPEG 2000 decoding failed: \(error)")
                return nil
            }

        case .openJPEGHTJ2K:
            do {
                let decoded = try DicomJPEG2000Codec.decode(compressedData)
                return makeResult(
                    bytes: decoded.bytes,
                    width: decoded.width,
                    height: decoded.height,
                    bitsPerSample: decoded.bitsPerSample,
                    componentCount: decoded.componentCount,
                    pixelRepresentation: pixelRepresentation,
                    photometricInterpretation: photometricInterpretation
                )
            } catch {
                logger?.warning("HTJ2K decoding failed: \(error)")
                return nil
            }

        case .legacyImageIO:
            if isJPEGLosslessFrame(compressedData) {
                return decodeJPEGLosslessFrame(
                    compressedData,
                    pixelRepresentation: pixelRepresentation,
                    photometricInterpretation: photometricInterpretation,
                    logger: logger
                )
            }
            return decodeImageIOFrame(
                compressedData,
                backend: .legacyImageIO,
                requestedBitDepth: bitDepth,
                pixelRepresentation: pixelRepresentation,
                photometricInterpretation: photometricInterpretation,
                logger: logger
            )

        case .unsupported:
            backendDecision.diagnostics.forEach { logger?.warning($0) }
            return nil
        }
    }

    private static func decodeJPEGLosslessFrame(
        _ compressedData: Data,
        pixelRepresentation: Int,
        photometricInterpretation: String,
        logger: LoggerProtocol?
    ) -> DCMPixelReadResult? {
        guard isJPEGLosslessFrame(compressedData) else {
            logger?.warning("JPEG Lossless transfer syntax requires a JPEG Lossless SOF3 frame")
            return nil
        }

        let decoder = JPEGLosslessDecoder()
        do {
            let losslessResult = try decoder.decode(data: compressedData)
            if losslessResult.componentCount == 3 {
                guard losslessResult.bitDepth <= 8 else {
                    logger?.warning(
                        "JPEG Lossless interleaved color decode supports 8 bits per component; "
                            + "the stream declares \(losslessResult.bitDepth) (Photometric Interpretation=\(photometricInterpretation))"
                    )
                    return nil
                }
                guard photometricInterpretation == "RGB" else {
                    logger?.warning(
                        "JPEG Lossless 3-component output is only unambiguous for Photometric Interpretation=RGB; "
                            + "got \(photometricInterpretation)"
                    )
                    return nil
                }
                return DCMPixelReadResult(
                    pixels8: nil,
                    pixels16: nil,
                    pixels24: losslessResult.pixels.map { UInt8(truncatingIfNeeded: $0) },
                    signedImage: false,
                    width: losslessResult.width,
                    height: losslessResult.height,
                    bitDepth: losslessResult.bitDepth,
                    samplesPerPixel: 3
                )
            }
            return makeGrayscaleResult(
                pixels: losslessResult.pixels,
                width: losslessResult.width,
                height: losslessResult.height,
                bitDepth: losslessResult.bitDepth,
                pixelRepresentation: pixelRepresentation,
                photometricInterpretation: photometricInterpretation
            )
        } catch {
            logger?.warning("JPEG Lossless decoding failed: \(error)")
            return nil
        }
    }

    private static func decodeImageIOFrame(
        _ compressedData: Data,
        backend: DicomCompressedPixelBackend,
        requestedBitDepth: Int?,
        pixelRepresentation: Int,
        photometricInterpretation: String,
        logger: LoggerProtocol?
    ) -> DCMPixelReadResult? {
        guard let source = CGImageSourceCreateWithData(compressedData as CFData, nil) else {
            logger?.warning("Failed to create image source from compressed data")
            return nil
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            logger?.warning("Failed to decode image from source")
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bitDepth = cgImage.bitsPerComponent
        let samples = max(1, cgImage.bitsPerPixel / cgImage.bitsPerComponent)
        let samplesPerPixel = samples >= 3 ? 3 : 1
        if let requestedBitDepth, requestedBitDepth > 8, bitDepth <= 8 {
            logger?.warning("ImageIO decoded \(bitDepth)-bit output for \(requestedBitDepth)-bit DICOM pixels; refusing precision-losing fallback")
            return nil
        }
        if bitDepth > 16 {
            logger?.warning("ImageIO decoded \(bitDepth)-bit output, but only 8-bit and 16-bit buffers are supported")
            return nil
        }
        if bitDepth > 8 && samplesPerPixel != 1 {
            logger?.warning("ImageIO \(backend) does not support >8-bit color output without precision loss")
            return nil
        }

        var result = DCMPixelReadResult(
            pixels8: nil,
            pixels16: nil,
            pixels24: nil,
            signedImage: pixelRepresentation == 1,
            width: width,
            height: height,
            bitDepth: bitDepth,
            samplesPerPixel: samplesPerPixel
        )

        if samplesPerPixel == 1 {
            if bitDepth > 8 {
                return decodeImageIOGrayscale16(
                    cgImage,
                    requestedBitDepth: requestedBitDepth,
                    pixelRepresentation: pixelRepresentation,
                    photometricInterpretation: photometricInterpretation,
                    logger: logger
                )
            }

            let colorSpace = CGColorSpaceCreateDeviceGray()
            let bytesPerRow = width
            guard let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                logger?.warning("Failed to create grayscale context")
                return nil
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let dataPtr = ctx.data else {
                logger?.warning("Failed to get context data pointer")
                return nil
            }
            let buffer = dataPtr.assumingMemoryBound(to: UInt8.self)
            result.pixels8 = [UInt8](UnsafeBufferPointer(start: buffer, count: width * height))
        } else {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bytesPerPixel = 4
            let bytesPerRow = width * bytesPerPixel
            let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            guard let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                logger?.warning("Failed to create RGB context")
                return nil
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let dataPtr = ctx.data else {
                logger?.warning("Failed to get context data pointer")
                return nil
            }
            let rawBuffer = dataPtr.assumingMemoryBound(to: UInt8.self)
            let count = width * height
            var output = [UInt8](repeating: 0, count: count * 3)
            for i in 0..<count {
                let srcIndex = i * 4
                let dstIndex = i * 3
                output[dstIndex] = rawBuffer[srcIndex]
                output[dstIndex + 1] = rawBuffer[srcIndex + 1]
                output[dstIndex + 2] = rawBuffer[srcIndex + 2]
            }
            result.pixels24 = output
        }

        return result
    }

    private static func decodeImageIOGrayscale16(
        _ cgImage: CGImage,
        requestedBitDepth: Int?,
        pixelRepresentation: Int,
        photometricInterpretation: String,
        logger: LoggerProtocol?
    ) -> DCMPixelReadResult? {
        let width = cgImage.width
        let height = cgImage.height
        let sampleCount = width * height
        let bytesPerRow = width * MemoryLayout<UInt16>.size
        var rawData = Data(count: sampleCount * MemoryLayout<UInt16>.size)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue

        let contextCreated = rawData.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let baseAddress = rawBytes.baseAddress,
                  let ctx = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 16,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard contextCreated else {
            logger?.warning("Failed to create 16-bit grayscale context")
            return nil
        }

        var pixels = rawData.withUnsafeBytes { rawBytes -> [UInt16] in
            let buffer = rawBytes.bindMemory(to: UInt16.self)
            return buffer.prefix(sampleCount).map { UInt16(littleEndian: $0) }
        }

        if pixelRepresentation == 1 {
            pixels = pixels.map { UInt16(Int(Int16(bitPattern: $0)) - Int(Int16.min)) }
        }
        if photometricInterpretation == "MONOCHROME1" {
            if pixelRepresentation == 1 {
                invertMonochrome1SignedVectorized(buffer: &pixels, count: sampleCount)
            } else {
                invertMonochrome1Vectorized(buffer: &pixels, count: sampleCount)
            }
        }

        return DCMPixelReadResult(
            pixels8: nil,
            pixels16: pixels,
            pixels24: nil,
            signedImage: pixelRepresentation == 1,
            width: width,
            height: height,
            bitDepth: requestedBitDepth ?? cgImage.bitsPerComponent,
            samplesPerPixel: 1
        )
    }

    private static func makeResult(
        from frame: DicomJPEGLSCodec.DecodedFrame,
        pixelRepresentation: Int,
        photometricInterpretation: String
    ) -> DCMPixelReadResult? {
        makeResult(
            bytes: frame.bytes,
            width: frame.width,
            height: frame.height,
            bitsPerSample: frame.bitsPerSample,
            componentCount: frame.componentCount,
            pixelRepresentation: pixelRepresentation,
            photometricInterpretation: photometricInterpretation
        )
    }

    private static func makeResult(
        bytes: Data,
        width: Int,
        height: Int,
        bitsPerSample: Int,
        componentCount: Int,
        pixelRepresentation: Int,
        photometricInterpretation: String
    ) -> DCMPixelReadResult? {
        let sampleCount = width * height
        if componentCount == 1 {
            if bitsPerSample <= 8 {
                guard bytes.count >= sampleCount else { return nil }
                var pixels = [UInt8](bytes.prefix(sampleCount))
                if pixelRepresentation == 1 {
                    pixels = pixels.map { UInt8(Int(Int8(bitPattern: $0)) - Int(Int8.min)) }
                }
                if photometricInterpretation == "MONOCHROME1" {
                    pixels = pixels.map { 255 - $0 }
                }
                return DCMPixelReadResult(
                    pixels8: pixels,
                    pixels16: nil,
                    pixels24: nil,
                    signedImage: pixelRepresentation == 1,
                    width: width,
                    height: height,
                    bitDepth: bitsPerSample,
                    samplesPerPixel: 1
                )
            }

            guard bitsPerSample <= 16, bytes.count >= sampleCount * 2 else {
                return nil
            }
            var pixels = [UInt16](repeating: 0, count: sampleCount)
            for index in 0..<sampleCount {
                let byteIndex = index * 2
                let sample = UInt16(bytes[byteIndex]) | (UInt16(bytes[byteIndex + 1]) << 8)
                if pixelRepresentation == 1 {
                    pixels[index] = UInt16(Int(Int16(bitPattern: sample)) - Int(Int16.min))
                } else {
                    pixels[index] = sample
                }
            }
            if photometricInterpretation == "MONOCHROME1" {
                if pixelRepresentation == 1 {
                    invertMonochrome1SignedVectorized(buffer: &pixels, count: sampleCount)
                } else {
                    invertMonochrome1Vectorized(buffer: &pixels, count: sampleCount)
                }
            }
            return DCMPixelReadResult(
                pixels8: nil,
                pixels16: pixels,
                pixels24: nil,
                signedImage: pixelRepresentation == 1,
                width: width,
                height: height,
                bitDepth: bitsPerSample,
                samplesPerPixel: 1
            )
        }

        if componentCount == 3 && bitsPerSample <= 8 {
            guard bytes.count >= sampleCount * 3 else { return nil }
            return DCMPixelReadResult(
                pixels8: nil,
                pixels16: nil,
                pixels24: [UInt8](bytes.prefix(sampleCount * 3)),
                signedImage: false,
                width: width,
                height: height,
                bitDepth: bitsPerSample,
                samplesPerPixel: 3
            )
        }

        return nil
    }

    private static func makeGrayscaleResult(
        pixels sourcePixels: [UInt16],
        width: Int,
        height: Int,
        bitDepth: Int,
        pixelRepresentation: Int,
        photometricInterpretation: String
    ) -> DCMPixelReadResult {
        let signedImage = pixelRepresentation == 1
        if bitDepth <= 8 {
            var pixels = sourcePixels.map { UInt8(truncatingIfNeeded: $0) }
            if signedImage {
                pixels = pixels.map { UInt8(Int(Int8(bitPattern: $0)) - Int(Int8.min)) }
            }
            if photometricInterpretation == "MONOCHROME1" {
                pixels = pixels.map { 255 - $0 }
            }
            return DCMPixelReadResult(
                pixels8: pixels,
                pixels16: nil,
                pixels24: nil,
                signedImage: signedImage,
                width: width,
                height: height,
                bitDepth: bitDepth,
                samplesPerPixel: 1
            )
        }

        var pixels = sourcePixels
        if signedImage {
            pixels = pixels.map { UInt16(Int(Int16(bitPattern: $0)) - Int(Int16.min)) }
        }
        if photometricInterpretation == "MONOCHROME1" {
            if signedImage {
                invertMonochrome1SignedVectorized(buffer: &pixels, count: pixels.count)
            } else {
                invertMonochrome1Vectorized(buffer: &pixels, count: pixels.count)
            }
        }
        return DCMPixelReadResult(
            pixels8: nil,
            pixels16: pixels,
            pixels24: nil,
            signedImage: signedImage,
            width: width,
            height: height,
            bitDepth: bitDepth,
            samplesPerPixel: 1
        )
    }

    /// Detects whether JPEG data uses the Lossless (SOF3) encoding.
    /// 
    /// Scans JPEG markers starting at byte index 2 and returns `true` if a Start Of Frame 3 (marker `0xC3`) is encountered before the Start Of Scan marker (`0xDA`); returns `false` if the scan ends or `0xDA` is reached first.
    /// - Returns: `true` if the JPEG stream contains a lossless SOF3 (`0xC3`) marker before SOS (`0xDA`), `false` otherwise.
    private static func isJPEGLossless(data: Data) -> Bool {
        var index = 2

        while index + 1 < data.count {
            if data[index] != 0xFF {
                index += 1
                continue
            }

            let markerCode = data[index + 1]
            if markerCode == 0xC3 {
                return true
            }
            if markerCode == 0xDA {
                return false
            }

            if markerCode == 0xD8 || markerCode == 0xD9 {
                index += 2
            } else if index + 3 < data.count {
                let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
                index += 2 + length
            } else {
                break
            }
        }

        return false
    }

    private static func isJPEGLosslessFrame(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8 && isJPEGLossless(data: data)
    }
}
