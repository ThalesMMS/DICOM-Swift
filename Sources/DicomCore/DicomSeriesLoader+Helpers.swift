import Foundation
import simd

// MARK: - Helpers

extension DicomSeriesLoader {
    /// Extract the preferred paired Window Center / Window Width values from DICOM metadata.
    ///
    /// WC/WW may be multi-valued DS fields (for example, `40\80` and `400\2000`).
    /// DCMDecoder preserves its legacy selected values in `windowCenter` / `windowWidth`;
    /// otherwise prefer the second paired component when present, then fall back to the
    /// first valid paired component without combining alternatives from different indexes.
    func windowCenterWidth(from decoder: any DicomDecoderProtocol) -> (center: Double, width: Double)? {
        if decoder.windowCenter.isFinite, decoder.windowWidth.isFinite, decoder.windowWidth > 0 {
            return (decoder.windowCenter, decoder.windowWidth)
        }

        let centers = decimalValues(from: decoder.info(for: .windowCenter))
        let widths = decimalValues(from: decoder.info(for: .windowWidth))
        let pairCount = min(centers.count, widths.count)

        guard pairCount > 0 else { return nil }

        let preferredIndex = pairCount > 1 ? 1 : 0
        if let center = centers[preferredIndex],
           let width = widths[preferredIndex],
           center.isFinite,
           width.isFinite,
           width > 0 {
            return (center, width)
        }

        for index in 0..<pairCount {
            if let center = centers[index],
               let width = widths[index],
               center.isFinite,
               width.isFinite,
               width > 0 {
                return (center, width)
            }
        }
        return nil
    }

    private func decimalValues(from value: String) -> [Double?] {
        value.split(separator: "\\", omittingEmptySubsequences: false).map { component in
            Double(component.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Validate and normalize `ImageOrientationPatient` (IOP).
    ///
    /// DICOM supplies two direction cosines: the row and column directions in patient space.
    /// For robust geometry, we require:
    /// - each vector has non-zero length and is approximately unit length
    /// - the two vectors are approximately orthogonal
    ///
    /// We normalize the vectors to unit length to reduce downstream drift.
    ///
    /// - Throws: `DicomSeriesLoaderError.invalidImageOrientation` when the vectors are degenerate or not sufficiently orthogonal.
    func validatedOrientation(
        from orientation: (row: SIMD3<Double>, column: SIMD3<Double>),
        lengthTolerance: Double = 1e-2,
        orthogonalityTolerance: Double = 1e-3
    ) throws -> (row: SIMD3<Double>, column: SIMD3<Double>) {
        let rowLen = simd_length(orientation.row)
        let colLen = simd_length(orientation.column)
        guard rowLen.isFinite, colLen.isFinite, rowLen > 0, colLen > 0 else {
            throw DicomSeriesLoaderError.invalidImageOrientation
        }

        // Require near-unit direction cosines; allow small drift.
        guard abs(rowLen - 1.0) <= lengthTolerance, abs(colLen - 1.0) <= lengthTolerance else {
            throw DicomSeriesLoaderError.invalidImageOrientation
        }

        let row = orientation.row / rowLen
        let col = orientation.column / colLen

        let dot = simd_dot(row, col)
        guard dot.isFinite, abs(dot) <= orthogonalityTolerance else {
            throw DicomSeriesLoaderError.invalidImageOrientation
        }

        return (row: row, column: col)
    }

    /// Finds DICOM candidate files by recursively enumerating a directory and returning regular files with a `.dcm` extension or no extension.
    /// - Parameters:
    ///   - directory: The directory URL to search.
    /// - Returns: An array of file URLs for regular files within `directory` whose path extension is `"dcm"` (case-insensitive) or is empty. Returns an empty array if the directory cannot be enumerated.
    /// - Throws: An error from `URL.resourceValues(forKeys:)` if reading resource values for an entry fails.
    func listDicomFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .nameKey]
        guard let enumerator = fm.enumerator(at: directory,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
            if resourceValues.isDirectory == true { continue }
            if resourceValues.isRegularFile == true {
                if fileURL.pathExtension.lowercased() == "dcm" || fileURL.pathExtension.isEmpty {
                    urls.append(fileURL)
                }
            }
        }
        return urls
    }

    /// Decode a DICOM image slice at the given URL and return its pixel values as an array of Int16 integers.
    /// - Parameters:
    ///   - url: File URL of the DICOM slice to decode.
    ///   - expectedWidth: Expected image width in pixels; decoder must match this value.
    ///   - expectedHeight: Expected image height in pixels; decoder must match this value.
    ///   - pixelFormat: Validated DICOM pixel format context for this slice.
    /// - Returns: An array of `Int16` pixel values for the decoded slice, normalized according to the pixel format.
    /// - Throws: `DicomSeriesLoaderError.failedToDecode(url)` if the decoder's format does not match the expected dimensions/format or pixel data cannot be obtained; also rethrows errors from the `decoderFactory` when creating a decoder.
    func decodeSlice(at url: URL,
                     expectedWidth: Int,
                     expectedHeight: Int,
                     pixelFormat: DicomSeriesLoaderPixelFormat,
                     cachedDecoder: (URL) -> DicomDecoderProtocol? = { _ in nil },
                     cacheDecoder: (DicomDecoderProtocol, URL) -> Void = { _, _ in }) throws -> [Int16] {
        // Try to use cached decoder first, fallback to creating new one
        let decoder: DicomDecoderProtocol
        let createdNewDecoder: Bool
        if let cached = cachedDecoder(url) {
            decoder = cached
            createdNewDecoder = false
        } else {
            // Load DICOM file using factory
            decoder = try decoderFactory(url.path)
            createdNewDecoder = true
        }

        guard decoder.width == expectedWidth,
              decoder.height == expectedHeight,
              decoder.bitDepth == pixelFormat.bitsAllocated,
              decoder.samplesPerPixel == pixelFormat.samplesPerPixel else {
            throw DicomSeriesLoaderError.failedToDecode(url)
        }

        if createdNewDecoder {
            cacheDecoder(decoder, url)
        }

        var buffer = [Int16](repeating: 0, count: expectedWidth * expectedHeight)
        var didReport32BitClamp = false
        let count = try decodePixels(
            from: decoder,
            into: &buffer,
            pixelFormat: pixelFormat,
            url: url,
            report32BitClamp: {
                self.report32BitClampIfNeeded(
                    reported: &didReport32BitClamp,
                    pixelFormat: pixelFormat,
                    url: url
                )
            }
        )
        return Array(buffer.prefix(count))
    }

    /// Decode a DICOM slice from `url` into the provided `buffer`, converting pixel samples to `Int16` and validating expected image dimensions and format.
    /// - Parameters:
    ///   - url: File URL of the DICOM slice to decode.
    ///   - buffer: Destination buffer to receive decoded pixels. Must have a count greater than or equal to the number of pixels in the slice.
    ///   - expectedWidth: Expected image width; decoding fails if the decoder reports a different width.
    ///   - expectedHeight: Expected image height; decoding fails if the decoder reports a different height.
    ///   - pixelFormat: Validated DICOM pixel format context for this slice.
    /// - Returns: The number of pixels written into `buffer`.
    /// - Throws: `DicomSeriesLoaderError.failedToDecode(url)` if the decoder or pixel data cannot be obtained, the decoder's format does not match the expectations, or `buffer` is too small.
    func decodeSliceIntoBuffer(
        at url: URL,
        buffer: inout [Int16],
        expectedWidth: Int,
        expectedHeight: Int,
        pixelFormat: DicomSeriesLoaderPixelFormat,
        cachedDecoder: (URL) -> DicomDecoderProtocol? = { _ in nil },
        cacheDecoder: (DicomDecoderProtocol, URL) -> Void = { _, _ in },
        report32BitClamp: () -> Void = {}
    ) throws -> Int {
        // Try to use cached decoder first, fallback to creating new one
        let decoder: DicomDecoderProtocol
        let createdNewDecoder: Bool
        if let cached = cachedDecoder(url) {
            decoder = cached
            createdNewDecoder = false
        } else {
            // Load DICOM file using factory
            decoder = try decoderFactory(url.path)
            createdNewDecoder = true
        }

        guard decoder.width == expectedWidth,
              decoder.height == expectedHeight,
              decoder.bitDepth == pixelFormat.bitsAllocated,
              decoder.samplesPerPixel == pixelFormat.samplesPerPixel else {
            throw DicomSeriesLoaderError.failedToDecode(url)
        }

        if createdNewDecoder {
            cacheDecoder(decoder, url)
        }

        return try decodePixels(
            from: decoder,
            into: &buffer,
            pixelFormat: pixelFormat,
            url: url,
            report32BitClamp: report32BitClamp
        )
    }

    private func decodePixels(
        from decoder: any DicomDecoderProtocol,
        into buffer: inout [Int16],
        pixelFormat: DicomSeriesLoaderPixelFormat,
        url: URL,
        report32BitClamp: () -> Void
    ) throws -> Int {
        let expectedPixelCount = decoder.width * decoder.height
        guard buffer.count >= expectedPixelCount else {
            throw DicomSeriesLoaderError.failedToDecode(url)
        }

        // Compressed slices decode through the production frame reader
        // (#1233): one decode per slice straight into the volume buffer,
        // without populating the decoder's whole-image pixel cache, so
        // memory stays bounded to the compressed bytes plus one frame.
        if pixelFormat.isCompressed {
            guard let concreteDecoder = decoder as? DCMDecoder else {
                throw DicomSeriesLoaderError.unsupportedTransferSyntaxForVolume(pixelFormat)
            }
            return try decodeCompressedSlice(
                from: concreteDecoder,
                into: &buffer,
                pixelFormat: pixelFormat,
                url: url,
                expectedPixelCount: expectedPixelCount
            )
        }

        switch pixelFormat.bitsAllocated {
        case 8:
            guard let pixels = decoder.getPixels8(), pixels.count == expectedPixelCount else {
                throw DicomSeriesLoaderError.failedToDecode(url)
            }
            for index in 0..<expectedPixelCount {
                buffer[index] = Int16(clamping: normalizedStoredValue(
                    Int(pixels[index]),
                    pixelFormat: pixelFormat
                ))
            }
        case 16:
            if pixelFormat.pixelRepresentation == 1,
               let concreteDecoder = decoder as? DCMDecoder,
               concreteDecoder.copyNativeSigned16Pixels(into: &buffer, expectedPixelCount: expectedPixelCount) {
                maskNarrow16BitSamples(in: &buffer, count: expectedPixelCount, pixelFormat: pixelFormat)
                return expectedPixelCount
            }

            guard let pixels = decoder.getPixels16(), pixels.count == expectedPixelCount else {
                throw DicomSeriesLoaderError.failedToDecode(url)
            }
            if pixelFormat.pixelRepresentation == 1 {
                for index in 0..<expectedPixelCount {
                    let signed = Int32(pixels[index]) + Int32(Int16.min)
                    buffer[index] = Int16(truncatingIfNeeded: signed)
                }
            } else {
                for index in 0..<expectedPixelCount {
                    buffer[index] = Int16(bitPattern: pixels[index])
                }
            }
            maskNarrow16BitSamples(in: &buffer, count: expectedPixelCount, pixelFormat: pixelFormat)
        case 32:
            for index in 0..<expectedPixelCount {
                guard let stored = decoder.storedPixelValue(at: index, frame: 0, sample: 0) else {
                    throw DicomSeriesLoaderError.failedToDecode(url)
                }
                if stored < Int(Int16.min) || stored > Int(Int16.max) {
                    report32BitClamp()
                }
                buffer[index] = Int16(clamping: stored)
            }
        default:
            throw DicomSeriesLoaderError.unsupportedPixelFormat(pixelFormat)
        }

        return expectedPixelCount
    }

    /// Decodes one compressed slice via `DicomDecodedFrameReader` and
    /// writes stored-value Int16 voxels using the same normalization-undo
    /// as the uncompressed paths (the decoded buffers are byte-identical
    /// to `getPixels8/16` by the #1227 parity contract).
    private func decodeCompressedSlice(
        from decoder: DCMDecoder,
        into buffer: inout [Int16],
        pixelFormat: DicomSeriesLoaderPixelFormat,
        url: URL,
        expectedPixelCount: Int
    ) throws -> Int {
        let frame: DicomDecodedFrame
        do {
            frame = try DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
        } catch let error as DicomDecodedFrameReader.ReadError {
            switch error {
            case .unsupportedTransferSyntax, .unusableEncapsulation:
                throw DicomSeriesLoaderError.unsupportedTransferSyntaxForVolume(pixelFormat)
            default:
                throw DicomSeriesLoaderError.failedToDecode(url)
            }
        } catch {
            throw DicomSeriesLoaderError.failedToDecode(url)
        }

        switch frame.pixels {
        case .gray8(let pixels):
            guard pixels.count == expectedPixelCount else {
                throw DicomSeriesLoaderError.failedToDecode(url)
            }
            for index in 0..<expectedPixelCount {
                buffer[index] = Int16(clamping: normalizedStoredValue(
                    Int(pixels[index]),
                    pixelFormat: pixelFormat
                ))
            }
        case .gray16(let pixels):
            guard pixels.count == expectedPixelCount else {
                throw DicomSeriesLoaderError.failedToDecode(url)
            }
            if pixelFormat.pixelRepresentation == 1 {
                for index in 0..<expectedPixelCount {
                    let signed = Int32(pixels[index]) + Int32(Int16.min)
                    buffer[index] = Int16(truncatingIfNeeded: signed)
                }
            } else {
                for index in 0..<expectedPixelCount {
                    buffer[index] = Int16(bitPattern: pixels[index])
                }
            }
            maskNarrow16BitSamples(in: &buffer, count: expectedPixelCount, pixelFormat: pixelFormat)
        case .rgb8:
            throw DicomSeriesLoaderError.unsupportedPixelFormat(pixelFormat)
        }

        return expectedPixelCount
    }

    func report32BitClampIfNeeded(
        reported: inout Bool,
        pixelFormat: DicomSeriesLoaderPixelFormat,
        url: URL
    ) {
        guard !reported else { return }
        reported = true

        let representation = pixelFormat.pixelRepresentation == 1 ? "signed" : "unsigned"
        logger.warning(
            "32-bit \(representation) DICOM pixel values outside Int16 range were quantized while loading "
            + "\(url.lastPathComponent). DicomSeriesLoader outputs Int16 voxels, so saturated values are lossy."
        )
    }

    /// The 16-bit paths hold each sample's whole word; with fewer bits stored (issue #2781) the bits above
    /// them may carry anything, and a signed sample's sign is its top stored bit.
    private func maskNarrow16BitSamples(
        in buffer: inout [Int16],
        count: Int,
        pixelFormat: DicomSeriesLoaderPixelFormat
    ) {
        guard pixelFormat.bitsStored < 16 else { return }
        for index in 0..<count {
            buffer[index] = Int16(truncatingIfNeeded: normalizedStoredValue(
                Int(UInt16(bitPattern: buffer[index])),
                pixelFormat: pixelFormat
            ))
        }
    }

    private func normalizedStoredValue(
        _ rawValue: Int,
        pixelFormat: DicomSeriesLoaderPixelFormat
    ) -> Int {
        guard pixelFormat.bitsStored > 0,
              pixelFormat.bitsStored < Int.bitWidth else {
            return rawValue
        }
        let shift = max(0, pixelFormat.highBit - pixelFormat.bitsStored + 1)
        let mask = (1 << pixelFormat.bitsStored) - 1
        let storedBits = (rawValue >> shift) & mask
        guard pixelFormat.pixelRepresentation == 1 else {
            return storedBits
        }
        let signBit = 1 << (pixelFormat.bitsStored - 1)
        return (storedBits & signBit) != 0
            ? storedBits - (1 << pixelFormat.bitsStored)
            : storedBits
    }

    /// Computes slice spacing along the series normal using IPP projection deltas.
    ///
    /// The function projects slice positions onto `normal`, measures absolute distances between consecutive projections,
    /// and returns the **median** delta. The median is more robust than the mean in the presence of outliers.
    ///
    /// If the deltas vary beyond supported tolerance, this throws ``DicomSeriesLoaderError/variableSliceSpacing(median:maxDeviation:)``
    /// rather than silently returning a misleading single Z spacing.
    ///
    /// - Parameters:
    ///   - slices: An ordered array of `SliceMeta` representing the series (order defines adjacency).
    ///   - normal: The unit or non-unit vector to project positions onto; spacing is measured along this direction.
    /// - Returns: The median spacing along `normal` as a `Double`, or `nil` if fewer than two valid distances are available.
    func computeZSpacing(from slices: [SliceMeta],
                         normal: SIMD3<Double>) throws -> Double? {
        guard slices.count > 1 else { return nil }
        var deltas: [Double] = []
        deltas.reserveCapacity(slices.count - 1)

        for idx in 1..<slices.count {
            if let p0 = slices[idx - 1].position, let p1 = slices[idx].position {
                let d0 = simd_dot(p0, normal)
                let d1 = simd_dot(p1, normal)
                let delta = abs(d1 - d0)
                if delta > 0 {
                    deltas.append(delta)
                }
            }
        }

        guard !deltas.isEmpty else { return nil }
        deltas.sort()

        let median: Double
        if deltas.count % 2 == 1 {
            median = deltas[deltas.count / 2]
        } else {
            let upper = deltas.count / 2
            median = 0.5 * (deltas[upper - 1] + deltas[upper])
        }

        // Consider spacing "variable" if any delta deviates from the median beyond clinical acquisition noise.
        // This primarily catches missing-slice discontinuities or mixed spacing series.
        let maxDeviation = deltas.map { abs($0 - median) }.max() ?? 0
        let allowedDeviation = max(0.05, 0.02 * median) // 0.05mm absolute or 2% relative
        if maxDeviation > allowedDeviation {
            throw DicomSeriesLoaderError.variableSliceSpacing(median: median, maxDeviation: maxDeviation)
        }

        return median
    }

    /// Checks whether two 3D vectors are equal within a per-component tolerance.
    /// - Parameters:
    ///   - lhs: The left-hand side vector.
    ///   - rhs: The right-hand side vector.
    ///   - tolerance: Maximum allowed absolute difference for each component.
    /// - Returns: `true` if the absolute difference of `x`, `y`, and `z` components are each less than `tolerance`, `false` otherwise.
    func isApproximatelyEqual(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>, tolerance: Double = 1e-4) -> Bool {
        abs(lhs.x - rhs.x) < tolerance &&
        abs(lhs.y - rhs.y) < tolerance &&
        abs(lhs.z - rhs.z) < tolerance
    }
}
