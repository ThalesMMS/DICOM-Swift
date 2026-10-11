import Foundation

internal enum DicomRLELosslessDecoder {
    static func decode(
        frame data: Data,
        width: Int,
        height: Int,
        bitsAllocated: Int,
        samplesPerPixel: Int,
        pixelRepresentation: Int,
        photometricInterpretation: String
    ) throws -> DCMPixelReadResult {
        guard bitsAllocated == 8 || bitsAllocated == 16 else {
            throw DICOMError.invalidPixelData(reason: "RLE supports only 8-bit and 16-bit samples in this decoder")
        }
        guard (samplesPerPixel == 1 && (pixelRepresentation == 0 || pixelRepresentation == 1))
                || (samplesPerPixel == 3 && pixelRepresentation == 0) else {
            throw DICOMError.invalidPixelData(reason: "RLE supports grayscale samples or unsigned 8/16-bit three-sample colour")
        }
        guard let metrics = DCMPixelReader.computePixelMetrics(
            width: width,
            height: height,
            bytesPerPixel: Int64(samplesPerPixel * (bitsAllocated / 8)),
            context: "RLE Lossless",
            logger: nil
        ) else {
            throw DICOMError.invalidPixelData(reason: "Invalid RLE image dimensions")
        }

        let bytesPerSample = bitsAllocated / 8
        let pixelCount = metrics.numPixels
        let expectedSegments = samplesPerPixel * bytesPerSample
        let decodedSegments: [[UInt8]]
        do {
            decodedSegments = try DicomRLECodec.decodeSegments(data, width: width, height: height,
                limits: .init(maximumDecodedBytes: metrics.numPixels * expectedSegments),
                // Readers accept a stray pad byte and a segment cut short within the last row (issue #2855).
                allowNonzeroPadding: true, allowShortSegments: true)
        } catch {
            throw DICOMError.invalidPixelData(reason: "RLE header or segment is malformed or exceeds the pixel budget")
        }
        guard decodedSegments.count == expectedSegments else {
            throw DICOMError.invalidPixelData(reason: "RLE segment count does not match sample allocation")
        }

        if samplesPerPixel == 1 && bytesPerSample == 1 {
            var pixels = decodedSegments[0]
            if pixelRepresentation == 1 {
                pixels = pixels.map { sample in
                    UInt8(Int(Int8(bitPattern: sample)) - Int(Int8.min))
                }
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
                bitDepth: bitsAllocated,
                samplesPerPixel: samplesPerPixel
            )
        }

        if samplesPerPixel == 1 && bytesPerSample == 2 {
            var pixels = [UInt16](repeating: 0, count: pixelCount)
            for index in 0..<pixelCount {
                let high = UInt16(decodedSegments[0][index])
                let low = UInt16(decodedSegments[1][index])
                let sample = (high << 8) | low
                if pixelRepresentation == 1 {
                    pixels[index] = UInt16(Int(Int16(bitPattern: sample)) - Int(Int16.min))
                } else {
                    pixels[index] = sample
                }
            }
            if photometricInterpretation == "MONOCHROME1" {
                if pixelRepresentation == 1 {
                    DCMPixelReader.invertMonochrome1SignedVectorized(buffer: &pixels, count: pixelCount)
                } else {
                    DCMPixelReader.invertMonochrome1Vectorized(buffer: &pixels, count: pixelCount)
                }
            }
            return DCMPixelReadResult(
                pixels8: nil,
                pixels16: pixels,
                pixels24: nil,
                signedImage: pixelRepresentation == 1,
                width: width,
                height: height,
                bitDepth: bitsAllocated,
                samplesPerPixel: samplesPerPixel
            )
        }

        if bytesPerSample == 2 {
            // PS3.5 G.2: one segment per byte of each sample, most significant byte first, samples in order
            // (R high, R low, G high, G low, B high, B low); the words come out interleaved (issue #3034).
            var rgb = [UInt16](repeating: 0, count: pixelCount * 3)
            for index in 0..<pixelCount {
                for sample in 0..<3 {
                    rgb[index * 3 + sample] = (UInt16(decodedSegments[sample * 2][index]) << 8)
                        | UInt16(decodedSegments[sample * 2 + 1][index])
                }
            }
            return DCMPixelReadResult(
                pixels8: nil,
                pixels16: nil,
                pixels24: nil,
                signedImage: false,
                width: width,
                height: height,
                bitDepth: bitsAllocated,
                samplesPerPixel: samplesPerPixel,
                pixels48: rgb
            )
        }

        var rgb = [UInt8](repeating: 0, count: pixelCount * 3)
        for index in 0..<pixelCount {
            rgb[index * 3] = decodedSegments[0][index]
            rgb[index * 3 + 1] = decodedSegments[1][index]
            rgb[index * 3 + 2] = decodedSegments[2][index]
        }
        return DCMPixelReadResult(
            pixels8: nil,
            pixels16: nil,
            pixels24: rgb,
            signedImage: false,
            width: width,
            height: height,
            bitDepth: bitsAllocated,
            samplesPerPixel: samplesPerPixel
        )
    }

}
