import Foundation

extension DicomTranscoder {
    /// JPEG (ITU-T T.81) destinations: Baseline 8-bit, Extended 8/12-bit (lossy, explicit quality) and the
    /// lossless predictive syntaxes (reversible); the own DicomJPEG backend validates the shape.
    func prepareJPEGDescriptor(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) throws -> DicomCompressedFrameDescriptor {
        let descriptor = Self.compressedFrameDescriptor(decoder: decoder, syntax: destination)
        do {
            _ = try DicomJPEGSwiftBackend.validateEncoding(descriptor: descriptor, targetTransferSyntaxUID: destination.rawValue, intent: intent)
        } catch {
            throw TranscodeError.routeUnsupported(sourceUID: source.rawValue, destinationUID: destination.rawValue,
                                                  diagnostics: [(error as? LocalizedError)?.errorDescription ?? "\(error)"])
        }
        return descriptor
    }

    func compressToJPEG(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        descriptor: DicomCompressedFrameDescriptor,
        environment: [String: String]
    ) async throws -> Data {
        let backend = DicomJPEGSwiftBackend()
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let frameCount = max(1, frameReader.frameCount)
        var fragments: [Data] = []
        var encodedByteCount = 0
        var uncompressedByteCount = 0
        for index in 0..<frameCount {
            let storedBytes = try await storedFrameBytes(frameReader: frameReader, decoder: decoder, frameIndex: index, source: source, environment: environment)
            uncompressedByteCount += storedBytes.count
            let frame = DicomCodecDecodedFrame(buffer: .owned(storedBytes), width: descriptor.columns, height: descriptor.rows,
                                               bitsPerSample: descriptor.bitsStored, componentCount: descriptor.samplesPerPixel)
            do {
                let codestream = try await backend.encode(DicomFrameEncodeRequest(
                    frame: frame, descriptor: descriptor, targetTransferSyntaxUID: destination.rawValue, intent: intent))
                encodedByteCount += codestream.count
                fragments.append(codestream)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscodeError.encodeFailed(destinationUID: destination.rawValue, frameIndex: index,
                                                  reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        var dataSet = decoder.dataSet
        Self.replaceEncapsulatedPixelData(in: &dataSet, with: try Self.encapsulate(fragments: fragments))
        Self.applyDestinationPixelMetadata(to: &dataSet, destination: destination, descriptor: descriptor, intent: intent)
        var outputSOPInstanceUID: String?
        if intent.isLossy {
            let derived = DicomDataSetWriter.makeUID()
            outputSOPInstanceUID = derived
            dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([derived])))
            Self.applyLossyMetadata(to: &dataSet, destination: destination, uncompressedByteCount: uncompressedByteCount,
                                    encodedByteCount: encodedByteCount, sourceSOPClassUID: decoder.info(for: .sopClassUID),
                                    sourceSOPInstanceUID: decoder.info(for: .sopInstanceUID))
        }
        return try write(dataSet, decoder: decoder, transferSyntax: destination, sopInstanceUID: outputSOPInstanceUID)
    }
}
