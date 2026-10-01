import Foundation

extension DicomTranscoder {
    /// RLE Lossless (PS3.5 Annex G) accepts 8/16-bit grayscale and 8-bit RGB stored samples; nothing else is
    /// representable without changing the pixel structure.
    func prepareRLEDescriptor(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) throws -> DicomCompressedFrameDescriptor {
        guard !intent.isLossy else {
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue, destinationUID: DicomTransferSyntax.rleLossless.rawValue,
                diagnostics: ["RLE Lossless is reversible; a lossy or NEAR intent has no meaning for it."]
            )
        }
        let descriptor = Self.compressedFrameDescriptor(decoder: decoder, syntax: .rleLossless)
        guard [8, 16].contains(descriptor.bitsAllocated), [1, 3].contains(descriptor.samplesPerPixel),
              descriptor.samplesPerPixel == 1 || descriptor.bitsAllocated == 8 else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "RLE Lossless encoding covers 8/16-bit single-sample and 8-bit three-sample frames; "
                    + "the source has \(descriptor.bitsAllocated) bits allocated and \(descriptor.samplesPerPixel) samples per pixel."
            )
        }
        return descriptor
    }

    /// Encodes one frame of stored bytes as an RLE frame (segments, PackBits, header).
    static func encodeRLEFrame(_ stored: Data, descriptor: DicomCompressedFrameDescriptor) throws -> Data {
        try DicomRLECodec.encodeFrame(
            stored, width: descriptor.columns, height: descriptor.rows,
            samplesPerPixel: descriptor.samplesPerPixel, bytesPerSample: descriptor.bitsAllocated / 8
        )
    }

    func compressToRLE(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        descriptor: DicomCompressedFrameDescriptor,
        environment: [String: String]
    ) async throws -> Data {
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let frameCount = max(1, frameReader.frameCount)
        var fragments: [Data] = []
        fragments.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            let storedBytes = try await storedFrameBytes(
                frameReader: frameReader, decoder: decoder, frameIndex: index, source: source, environment: environment
            )
            fragments.append(try Self.rleFragment(storedBytes, descriptor: descriptor, frameIndex: index))
        }
        return try writeRLE(decoder: decoder, descriptor: descriptor, fragments: fragments)
    }

    func compressToRLESynchronously(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        descriptor: DicomCompressedFrameDescriptor
    ) throws -> Data {
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let frameCount = max(1, frameReader.frameCount)
        var fragments: [Data] = []
        for index in 0..<frameCount {
            let storedBytes: Data
            if !decoder.compressedImage, decoder.samplesPerPixel == 3 {
                storedBytes = try decoder.displayRGBPixelBuffer(frame: index).rgbData
            } else {
                storedBytes = try storedFrameBytes(frameReader: frameReader, decoder: decoder, frameIndex: index)
            }
            fragments.append(try Self.rleFragment(storedBytes, descriptor: descriptor, frameIndex: index))
        }
        return try writeRLE(decoder: decoder, descriptor: descriptor, fragments: fragments)
    }

    static func rleFragment(_ storedBytes: Data, descriptor: DicomCompressedFrameDescriptor, frameIndex: Int) throws -> Data {
        do {
            return try encodeRLEFrame(storedBytes, descriptor: descriptor)
        } catch {
            throw TranscodeError.encodeFailed(
                destinationUID: DicomTransferSyntax.rleLossless.rawValue, frameIndex: frameIndex,
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
    }

    private func writeRLE(decoder: DCMDecoder, descriptor: DicomCompressedFrameDescriptor, fragments: [Data]) throws -> Data {
        let encapsulation = try Self.encapsulate(fragments: fragments)
        var dataSet = decoder.dataSet
        Self.replaceEncapsulatedPixelData(in: &dataSet, with: encapsulation)
        if descriptor.samplesPerPixel == 3 {
            // Segments are one byte plane per sample; the decoded interleave is what Planar Configuration 0 declares.
            dataSet.set(DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["RGB"])))
            dataSet.set(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0])))
        }
        return try write(dataSet, decoder: decoder, transferSyntax: .rleLossless)
    }
}
