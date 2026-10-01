import Foundation

extension DCMDecoder {
    /// Retrieve the decoded 8-bit pixel buffer for the DICOM image.
    /// Thread-safe; triggers lazy pixel decoding on first call.
    /// - Returns: The decoded 8-bit pixel buffer, or `nil` if pixel data could not be loaded.
    public func getPixels8() -> [UInt8]? {
        return synchronized {
            let startTime = CFAbsoluteTimeGetCurrent()
            guard ensurePixelsLoadedUnsafe() else {
                return nil
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if elapsed > 1 { debugPerfLog("[PERF] getPixels8: \(String(format: "%.2f", elapsed))ms") }
            return pixels8
        }
    }

    /// Returns the decoder's 16-bit pixel buffer, loading and decoding pixel data on first access if necessary.
    /// Thread-safe; triggers lazy pixel decoding on first call.
    /// - Returns: The 16-bit pixel samples as `[UInt16]` if available, `nil` if pixels could not be loaded.
    public func getPixels16() -> [UInt16]? {
        return synchronized {
            let startTime = CFAbsoluteTimeGetCurrent()
            guard ensurePixelsLoadedUnsafe() else {
                return nil
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if elapsed > 1 { debugPerfLog("[PERF] getPixels16: \(String(format: "%.2f", elapsed))ms") }
            return pixels16
        }
    }

    /// Returns the decoded 24-bit interleaved RGB pixel buffer, loading pixels on first access if needed.
    /// Thread-safe; triggers lazy pixel decoding on first call.
    /// - Returns: The 24-bit interleaved pixel buffer (RGB) as `[UInt8]` if available, or `nil` if pixel data could not be loaded.
    public func getPixels24() -> [UInt8]? {
        return synchronized {
            let startTime = CFAbsoluteTimeGetCurrent()
            guard ensurePixelsLoadedUnsafe() else {
                return nil
            }
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if elapsed > 1 { debugPerfLog("[PERF] getPixels24: \(String(format: "%.2f", elapsed))ms") }
            return pixels24
        }
    }

    /// Copies native uncompressed signed 16-bit samples directly into an Int16 destination.
    ///
    /// This is intentionally internal to preserve the public `getPixels16()` contract, which returns
    /// normalized UInt16 samples. Volume assembly needs stored Int16 voxels, so it can avoid the
    /// normalize-then-denormalize roundtrip for native signed CT/MR slices.
    func copyNativeSigned16Pixels(into buffer: inout [Int16], expectedPixelCount: Int) -> Bool {
        synchronized {
            guard fileReadSucceeded,
                  !compressedImage,
                  bitDepth == 16,
                  samplesPerPixel == 1,
                  pixelRepresentation == 1,
                  expectedPixelCount >= 0,
                  buffer.count >= expectedPixelCount else {
                return false
            }

            let (byteCount, byteCountOverflow) = expectedPixelCount.multipliedReportingOverflow(
                by: MemoryLayout<Int16>.size
            )
            guard !byteCountOverflow else {
                return false
            }
            guard offset >= 0, byteCount <= dicomData.count - offset else {
                return false
            }

            dicomData.withUnsafeBytes { dataBytes in
                let basePtr = dataBytes.baseAddress!.advanced(by: offset)
                buffer.withUnsafeMutableBufferPointer { destination in
                    guard let destinationBase = destination.baseAddress else { return }
                    if littleEndian {
                        _ = memcpy(destinationBase, basePtr, byteCount)
                    } else {
                        let source = basePtr.assumingMemoryBound(to: UInt8.self)
                        for index in 0..<expectedPixelCount {
                            let byteOffset = index * 2
                            let value = UInt16(source[byteOffset]) << 8 | UInt16(source[byteOffset + 1])
                            destinationBase[index] = Int16(bitPattern: value)
                        }
                    }
                }
            }

            if photometricInterpretation == "MONOCHROME1" {
                for index in 0..<expectedPixelCount {
                    buffer[index] = ~buffer[index]
                }
            }

            return true
        }
    }

    /// Reads uncompressed pixel data from the current DICOM byte buffer and updates the decoder's pixel caches.
    ///
    /// Clears existing pixel buffers and replaces them with results from `DCMPixelReader.readPixels(...)`, and updates `signedImage`.
    /// - Important: Must be called from within a synchronized block.
    private func readPixelsUnsafe() {
        // Clear any previously stored buffers
        pixels8 = nil
        pixels16 = nil
        pixels24 = nil

        // Use DCMPixelReader to read pixel data. Word-swapped 8-bit samples (OW under Explicit VR Big
        // Endian) are restored to raster order first; the reader then addresses the restored copy.
        var source = dicomData
        var pixelOffset = offset
        if !compressedImage, bigEndianTransferSyntax, !littleEndian, bitDepth == 8, pixelDataVR == .OW,
           let descriptor = makePixelDataDescriptorUnsafe(),
           let restored = descriptor.nativeFrameData(in: dicomData, frame: 0) {
            source = Data(count: descriptor.pixelDataOffset) + restored
            pixelOffset = descriptor.pixelDataOffset
        }
        let result = DCMPixelReader.readPixels(
            data: source,
            width: width,
            height: height,
            bitDepth: bitDepth,
            samplesPerPixel: samplesPerPixel,
            offset: pixelOffset,
            pixelRepresentation: pixelRepresentation,
            littleEndian: littleEndian,
            photometricInterpretation: photometricInterpretation,
            logger: logger
        )

        // Store the results
        pixels8 = result.pixels8
        pixels16 = result.pixels16
        pixels24 = result.pixels24
        signedImage = result.signedImage
    }

    /// Ensures the decoder's pixel buffers are loaded, performing decoding if necessary.
    ///
    /// Must be called from within a synchronized block. Triggers the appropriate decode path
    /// for compressed or uncompressed images and marks pixels as loaded.
    /// - Returns: `true` if the DICOM file was read successfully and pixel buffers are available (or already loaded), `false` otherwise.
    @inline(__always)
    private func ensurePixelsLoadedUnsafe() -> Bool {
        guard fileReadSucceeded else {
            return false
        }

        if !pixelsNotLoaded {
            return true
        }

        if compressedImage {
            decodeCompressedPixelDataUnsafe()
        } else {
            readPixelsUnsafe()
        }

        pixelsNotLoaded = false
        return fileReadSucceeded
    }

    /// Decodes compressed pixel data and updates the decoder's image state and cached pixel buffers.
    ///
    /// On success, updates `width`, `height`, `bitDepth`, `samplesPerPixel`, `signedImage` and stores pixel buffers.
    /// On failure, sets `fileReadSucceeded = false`.
    /// - Note: Must be called from within a synchronized block.
    private func decodeCompressedPixelDataUnsafe() {
        let bitsStored = intValue(for: DicomTag.bitsStored.rawValue)
        let planarConfiguration = intValue(for: DicomTag.planarConfiguration.rawValue) ?? 0
        if let frame = getEncapsulatedFrame(0),
           let result = DCMPixelReader.decodeCompressedFrameData(
               data: frame.data,
               transferSyntax: DicomTransferSyntax(uid: transferSyntaxUID),
               width: width,
               height: height,
               bitDepth: bitDepth,
               samplesPerPixel: samplesPerPixel,
               pixelRepresentation: pixelRepresentationTagValue,
               photometricInterpretation: photometricInterpretation,
               bitsStored: bitsStored,
               planarConfiguration: planarConfiguration,
               logger: logger
           ) {
            applyCompressedPixelReadResult(result)
            return
        }

        // Use DCMPixelReader to decode compressed pixel data
        guard let result = DCMPixelReader.decodeCompressedPixelData(
            data: dicomData,
            offset: offset,
            transferSyntax: DicomTransferSyntax(uid: transferSyntaxUID),
            width: width,
            height: height,
            bitDepth: bitDepth,
            samplesPerPixel: samplesPerPixel,
            pixelRepresentation: pixelRepresentationTagValue,
            photometricInterpretation: photometricInterpretation,
            bitsStored: bitsStored,
            planarConfiguration: planarConfiguration,
            logger: logger
        ) else {
            fileReadSucceeded = false
            return
        }

        applyCompressedPixelReadResult(result)
    }

    private func applyCompressedPixelReadResult(_ result: DCMPixelReadResult) {
        // Update decoder state with decoded image properties
        width = result.width
        height = result.height
        bitDepth = result.bitDepth
        samplesPerPixel = result.samplesPerPixel
        signedImage = result.signedImage

        // Store pixel buffers
        pixels8 = result.pixels8
        pixels16 = result.pixels16
        pixels24 = result.pixels24
    }
}
