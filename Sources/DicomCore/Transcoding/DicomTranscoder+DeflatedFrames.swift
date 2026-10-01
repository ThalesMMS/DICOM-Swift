import DicomData
import Foundation

/// Deflated Image Frame Compression (`1.2.840.10008.1.2.8.1`) routes. A native little-endian source deflates its
/// own frame bytes (any Bits Allocated, Planar Configuration kept); a compressed source is decoded to stored
/// bytes first. Decoding inflates every fragment to exactly the native frame length and writes native Pixel Data.
extension DicomTranscoder {
    func prepareDeflatedFramesDescriptor(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) throws -> DicomCompressedFrameDescriptor {
        guard !intent.isLossy else {
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue, destinationUID: DicomTransferSyntax.deflatedImageFrameCompression.rawValue,
                diagnostics: ["Deflated Image Frame Compression is reversible; a lossy or NEAR intent has no meaning for it."]
            )
        }
        let descriptor = Self.compressedFrameDescriptor(decoder: decoder, syntax: .deflatedImageFrameCompression)
        guard DicomDeflatedFrameCodec.frameByteCount(
            rows: descriptor.rows, columns: descriptor.columns,
            samplesPerPixel: descriptor.samplesPerPixel, bitsAllocated: descriptor.bitsAllocated,
            photometricInterpretation: descriptor.photometricInterpretation
        ) != nil else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "Deflated Image Frame Compression needs a valid native frame shape; the source has \(descriptor.rows)×\(descriptor.columns) "
                    + "pixels, \(descriptor.samplesPerPixel) sample(s) per pixel and \(descriptor.bitsAllocated) bits allocated."
            )
        }
        if !Self.deflatesNativeFrames(decoder: decoder) {
            // Decoded (typed) frames feed the codec: the shared pipeline materialises 8/16-bit grey and 8-bit RGB.
            guard [8, 16].contains(descriptor.bitsAllocated), [1, 3].contains(descriptor.samplesPerPixel),
                  descriptor.samplesPerPixel == 1 || descriptor.bitsAllocated == 8 else {
                throw TranscodeError.unsupportedPixelShape(
                    reason: "Deflated Image Frame Compression from a decoded source covers 8/16-bit single-sample and 8-bit three-sample frames; "
                        + "the source has \(descriptor.bitsAllocated) bits allocated and \(descriptor.samplesPerPixel) samples per pixel."
                )
            }
        }
        return descriptor
    }

    /// Native little-endian frames are deflated directly; single-bit frames are packed independently.
    static func deflatesNativeFrames(decoder: DCMDecoder) -> Bool {
        guard !decoder.compressedImage, decoder.currentLittleEndian(), let descriptor = decoder.pixelDataDescriptor else { return false }
        return descriptor.bitsAllocated == 1 || descriptor.bitsPerFrame.isMultiple(of: 8) && (0..<descriptor.numberOfFrames).allSatisfy {
            (descriptor.bitRange(forFrame: $0)?.lowerBound ?? 1).isMultiple(of: 8)
        }
    }

    /// Native frame bytes, with packed one-bit frames aligned at bit zero.
    static func nativeFrameBytes(decoder: DCMDecoder, frameIndex: Int) throws -> Data {
        guard let descriptor = decoder.pixelDataDescriptor, let byteRange = descriptor.byteRange(forFrame: frameIndex),
              let bitRange = descriptor.bitRange(forFrame: frameIndex),
              descriptor.bitsAllocated == 1 || bitRange.lowerBound.isMultiple(of: 8) && bitRange.count.isMultiple(of: 8) else {
            throw TranscodeError.unsupportedPixelShape(reason: "frame \(frameIndex) has no supported native layout")
        }
        let source = decoder.dicomDataSnapshot()
        guard byteRange.lowerBound >= source.startIndex, byteRange.upperBound <= source.endIndex else {
            throw TranscodeError.decodeFailed(sourceUID: decoder.info(for: .transferSyntaxUID),
                                              reason: "native frame \(frameIndex) lies outside the Pixel Data value")
        }
        if bitRange.lowerBound.isMultiple(of: 8), bitRange.count.isMultiple(of: 8) {
            return source.subdata(in: byteRange)
        }
        // Native one-bit frames share byte boundaries. Each deflated frame
        // starts at bit zero and has zero padding in its final partial byte.
        let shift = bitRange.lowerBound % 8
        let count = bitRange.count / 8 + (bitRange.count.isMultiple(of: 8) ? 0 : 1)
        var frame = Data(count: count)
        for index in 0..<count {
            let start = byteRange.lowerBound + index
            var value = source[start] >> shift
            if shift > 0, start + 1 < byteRange.upperBound { value |= source[start + 1] << (8 - shift) }
            frame[index] = value
        }
        if !bitRange.count.isMultiple(of: 8) { frame[count - 1] &= UInt8((1 << (bitRange.count % 8)) - 1) }
        return frame
    }

    static func deflatedFrameByteCount(decoder: DCMDecoder) throws -> Int {
        guard let count = DicomDeflatedFrameCodec.frameByteCount(
            rows: decoder.height, columns: decoder.width, samplesPerPixel: decoder.samplesPerPixel, bitsAllocated: decoder.bitDepth,
            photometricInterpretation: decoder.photometricInterpretation
        ) else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "Rows, Columns, Samples per Pixel and Bits Allocated do not describe a valid native frame")
        }
        return count
    }

    static func deflatedFrameReader(decoder: DCMDecoder) throws -> DicomEncapsulatedPixelFrameReader {
        do {
            return try decoder.makeEncapsulatedPixelFrameReader()
        } catch {
            throw TranscodeError.decodeFailed(sourceUID: DicomTransferSyntax.deflatedImageFrameCompression.rawValue,
                                              reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    static func inflateNativeFrame(_ reader: DicomEncapsulatedPixelFrameReader, frameIndex: Int, expectedByteCount: Int) throws -> Data {
        do {
            guard reader.descriptor.frameFragmentIndexes.indices.contains(frameIndex),
                  reader.descriptor.frameFragmentIndexes[frameIndex].count == 1 else {
                throw TranscodeError.unsupportedPixelShape(reason: "each deflated frame requires exactly one fragment")
            }
            return try DicomDeflatedFrameCodec.decodeFrame(try reader.frameData(at: frameIndex), expectedByteCount: expectedByteCount)
        } catch {
            throw TranscodeError.decodeFailed(
                sourceUID: DicomTransferSyntax.deflatedImageFrameCompression.rawValue,
                reason: "frame \(frameIndex): " + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
            )
        }
    }

    static func deflatedFragment(_ nativeBytes: Data, frameIndex: Int) throws -> Data {
        do {
            return try DicomDeflatedFrameCodec.encodeFrame(nativeBytes)
        } catch {
            throw TranscodeError.encodeFailed(
                destinationUID: DicomTransferSyntax.deflatedImageFrameCompression.rawValue, frameIndex: frameIndex,
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
    }

    func compressToDeflatedFrames(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        descriptor: DicomCompressedFrameDescriptor,
        environment: [String: String]
    ) async throws -> Data {
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let frameCount = max(1, frameReader.frameCount)
        let raw = Self.deflatesNativeFrames(decoder: decoder)
        var fragments: [Data] = []
        fragments.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            try Task.checkCancellation()
            let bytes = raw
                ? try Self.nativeFrameBytes(decoder: decoder, frameIndex: index)
                : try await storedFrameBytes(frameReader: frameReader, decoder: decoder, frameIndex: index, source: source, environment: environment)
            fragments.append(try Self.deflatedFragment(bytes, frameIndex: index))
        }
        return try writeDeflatedFrames(decoder: decoder, descriptor: descriptor, fragments: fragments, rawNativeFrames: raw)
    }

    func compressToDeflatedFramesSynchronously(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        descriptor: DicomCompressedFrameDescriptor
    ) throws -> Data {
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let frameCount = max(1, frameReader.frameCount)
        let raw = Self.deflatesNativeFrames(decoder: decoder)
        var fragments: [Data] = []
        for index in 0..<frameCount {
            let bytes: Data
            if raw {
                bytes = try Self.nativeFrameBytes(decoder: decoder, frameIndex: index)
            } else if !decoder.compressedImage, decoder.samplesPerPixel == 3 {
                bytes = try decoder.displayRGBPixelBuffer(frame: index).rgbData
            } else {
                bytes = try storedFrameBytes(frameReader: frameReader, decoder: decoder, frameIndex: index)
            }
            fragments.append(try Self.deflatedFragment(bytes, frameIndex: index))
        }
        return try writeDeflatedFrames(decoder: decoder, descriptor: descriptor, fragments: fragments, rawNativeFrames: raw)
    }

    private func writeDeflatedFrames(decoder: DCMDecoder, descriptor: DicomCompressedFrameDescriptor, fragments: [Data],
                                     rawNativeFrames: Bool) throws -> Data {
        let encapsulation = try Self.encapsulate(fragments: fragments)
        var dataSet = decoder.dataSet
        Self.replaceEncapsulatedPixelData(in: &dataSet, with: encapsulation)
        if !rawNativeFrames, descriptor.samplesPerPixel == 3 {
            // Decoded colour frames are interleaved RGB; verbatim native frames keep their own attributes.
            dataSet.set(DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["RGB"])))
            dataSet.set(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0])))
        }
        return try write(dataSet, decoder: decoder, transferSyntax: .deflatedImageFrameCompression)
    }

    /// `.8.1` → native: every fragment inflates to the exact native frame length and the frames are concatenated
    /// as Pixel Data; the Image Pixel attributes are carried unchanged (the frames are their own native bytes).
    func inflateDeflatedFramesToNative(decoder: DCMDecoder, destination: DicomTransferSyntax) throws -> Data {
        let frameBytes = try Self.deflatedFrameByteCount(decoder: decoder)
        let reader = try Self.deflatedFrameReader(decoder: decoder)
        let frameCount = max(1, decoder.nImages)
        guard reader.frameCount == frameCount else {
            throw TranscodeError.decodeFailed(
                sourceUID: DicomTransferSyntax.deflatedImageFrameCompression.rawValue,
                reason: "NumberOfFrames declares \(frameCount) frame(s) but \(reader.frameCount) fragment(s) were mapped"
            )
        }
        var pixelBytes = Data()
        let bitPacked = decoder.bitDepth == 1
        let bitsPerFrame = bitPacked ? decoder.height * decoder.width * decoder.samplesPerPixel : 0
        if bitPacked {
            let total = bitsPerFrame.multipliedReportingOverflow(by: frameCount)
            guard !total.overflow else { throw TranscodeError.unsupportedPixelShape(reason: "native Pixel Data length overflows") }
            pixelBytes = Data(count: total.partialValue / 8 + (total.partialValue.isMultiple(of: 8) ? 0 : 1))
        }
        for index in 0..<frameCount {
            let frame = try Self.inflateNativeFrame(reader, frameIndex: index, expectedByteCount: frameBytes)
            if bitPacked {
                for byte in frame.indices {
                    let bit = index * bitsPerFrame + byte * 8
                    let shift = bit % 8
                    var value = frame[byte]
                    if byte == frame.count - 1, !bitsPerFrame.isMultiple(of: 8) {
                        value &= UInt8((1 << (bitsPerFrame % 8)) - 1)
                    }
                    pixelBytes[bit / 8] |= value << shift
                    if shift > 0, bit / 8 + 1 < pixelBytes.count { pixelBytes[bit / 8 + 1] |= value >> (8 - shift) }
                }
            } else {
                pixelBytes.append(frame)
            }
        }
        if !pixelBytes.count.isMultiple(of: 2) { pixelBytes.append(0) }
        var dataSet = decoder.dataSet
        dataSet.remove(.extendedOffsetTable)
        dataSet.remove(.extendedOffsetTableLengths)
        dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: decoder.bitDepth > 8 ? .OW : .OB, value: .bytes(pixelBytes)))
        return try write(dataSet, decoder: decoder, transferSyntax: destination)
    }
}
