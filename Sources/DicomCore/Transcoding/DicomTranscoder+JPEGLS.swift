import Foundation

extension DicomTranscoder {
    func prepareJPEGLSDescriptor(
        decoder: DCMDecoder,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        environment: [String: String]
    ) throws -> DicomCompressedFrameDescriptor {
        let descriptor = try jpegLSDescriptor(decoder: decoder, destination: destination)
        let decision = DicomCodecCapabilities.resolve(
            DicomCodecCapabilityRequest(operation: .encode, descriptor: descriptor, intent: intent),
            environment: environment
        )
        guard decision.canExecute else {
            if decision.reasonCode == .intentUnsupported {
                throw TranscodeError.encodeFailed(destinationUID: destination.rawValue, frameIndex: 0,
                                                  reason: decision.reason ?? "The encoding intent is unsupported.")
            }
            throw TranscodeError.unsupportedPixelShape(reason: decision.reason ?? "No qualified encoder is available.")
        }
        return descriptor
    }

    func compressToJPEGLS(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        descriptor: DicomCompressedFrameDescriptor,
        environment: [String: String]
    ) async throws -> Data {
        let backend = DicomJLSwiftBackend()

        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let frameCount = max(1, frameReader.frameCount)
        var fragments: [Data] = []
        fragments.reserveCapacity(frameCount)
        var encodedByteCount = 0
        var uncompressedByteCount = 0
        for index in 0..<frameCount {
            let storedBytes = try await storedFrameBytes(
                frameReader: frameReader,
                decoder: decoder,
                frameIndex: index,
                source: source,
                environment: environment
            )
            let byteCount = uncompressedByteCount.addingReportingOverflow(storedBytes.count)
            guard !byteCount.overflow else {
                throw TranscodeError.unsupportedPixelShape(
                    reason: "The decoded frames exceed the addressable byte range."
                )
            }
            uncompressedByteCount = byteCount.partialValue
            let frame = DicomCodecDecodedFrame(
                buffer: .owned(storedBytes),
                width: descriptor.columns,
                height: descriptor.rows,
                bitsPerSample: descriptor.bitsStored,
                componentCount: descriptor.samplesPerPixel
            )
            do {
                let codestream = try await backend.encode(DicomFrameEncodeRequest(
                    frame: frame,
                    descriptor: descriptor,
                    targetTransferSyntaxUID: destination.rawValue,
                    intent: intent
                ))
                encodedByteCount += codestream.count
                fragments.append(codestream)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscodeError.encodeFailed(
                    destinationUID: destination.rawValue,
                    frameIndex: index,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        }

        let encapsulation = try Self.encapsulate(fragments: fragments)
        var dataSet = decoder.dataSet
        dataSet.remove(.extendedOffsetTable)
        dataSet.remove(.extendedOffsetTableLengths)
        if let offsets = encapsulation.extendedOffsetTable,
           let lengths = encapsulation.extendedOffsetTableLengths {
            dataSet.set(DicomDataElement(
                tag: DicomTag.extendedOffsetTable.rawValue,
                vr: .OV,
                value: .bytes(offsets)
            ))
            dataSet.set(DicomDataElement(
                tag: DicomTag.extendedOffsetTableLengths.rawValue,
                vr: .OV,
                value: .bytes(lengths)
            ))
        }
        dataSet.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: .OB,
            value: .bytes(encapsulation.pixelData)
        ))
        if descriptor.samplesPerPixel == 3 {
            dataSet.set(DicomDataElement(
                tag: DicomTag.photometricInterpretation.rawValue,
                vr: .CS,
                value: .strings(["RGB"])
            ))
            dataSet.set(DicomDataElement(
                tag: DicomTag.planarConfiguration.rawValue,
                vr: .US,
                value: .unsignedIntegers([0])
            ))
        }

        var outputSOPInstanceUID: String?
        if destination == .jpegLSNearLossless {
            let derivedSOPInstanceUID = DicomDataSetWriter.makeUID()
            outputSOPInstanceUID = derivedSOPInstanceUID
            dataSet.set(DicomDataElement(
                tag: DicomTag.sopInstanceUID.rawValue,
                vr: .UI,
                value: .strings([derivedSOPInstanceUID])
            ))
            Self.applyLossyMetadata(
                to: &dataSet,
                destination: destination,
                uncompressedByteCount: uncompressedByteCount,
                encodedByteCount: encodedByteCount,
                sourceSOPClassUID: decoder.info(for: .sopClassUID),
                sourceSOPInstanceUID: decoder.info(for: .sopInstanceUID)
            )
        }
        return try write(
            dataSet,
            decoder: decoder,
            transferSyntax: destination,
            sopInstanceUID: outputSOPInstanceUID
        )
    }

    func compressToJPEGLSLossless(decoder: DCMDecoder, source: DicomTransferSyntax) throws -> Data {
        guard DicomJPEGLSCodec.isAvailable else {
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue,
                destinationUID: DicomTransferSyntax.jpegLSLossless.rawValue,
                diagnostics: ["The CharLS runtime is unavailable; JPEG-LS encoding requires it."]
            )
        }
        guard decoder.samplesPerPixel == 1,
              decoder.photometricInterpretation == "MONOCHROME2" || decoder.photometricInterpretation.isEmpty else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG-LS lossless encoding covers single-sample MONOCHROME2 frames "
                    + "(Photometric Interpretation=\(decoder.photometricInterpretation), "
                    + "Samples per Pixel=\(decoder.samplesPerPixel))."
            )
        }

        let bitsStored = decoder.intValue(for: .bitsStored) ?? decoder.bitDepth
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        var fragments = [Data]()
        for index in 0..<max(1, frameReader.frameCount) {
            let storedBytes = try storedFrameBytes(frameReader: frameReader, decoder: decoder, frameIndex: index)
            var encoded = try DicomJPEGLSCodec.encode(
                bytes: storedBytes,
                width: decoder.width,
                height: decoder.height,
                bitsPerSample: bitsStored
            )
            if encoded.count % 2 != 0 {
                encoded.append(0x00)
            }
            fragments.append(encoded)
        }

        let encapsulation = try Self.encapsulate(fragments: fragments)
        var dataSet = decoder.dataSet
        dataSet.remove(.extendedOffsetTable)
        dataSet.remove(.extendedOffsetTableLengths)
        if let offsets = encapsulation.extendedOffsetTable,
           let lengths = encapsulation.extendedOffsetTableLengths {
            dataSet.set(DicomDataElement(
                tag: DicomTag.extendedOffsetTable.rawValue,
                vr: .OV,
                value: .bytes(offsets)
            ))
            dataSet.set(DicomDataElement(
                tag: DicomTag.extendedOffsetTableLengths.rawValue,
                vr: .OV,
                value: .bytes(lengths)
            ))
        }
        dataSet.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: .OB,
            value: .bytes(encapsulation.pixelData)
        ))
        return try write(dataSet, decoder: decoder, transferSyntax: .jpegLSLossless)
    }

    private func jpegLSDescriptor(
        decoder: DCMDecoder,
        destination: DicomTransferSyntax
    ) throws -> DicomCompressedFrameDescriptor {
        let bitsStored = decoder.intValue(for: .bitsStored) ?? decoder.bitDepth
        let highBit = decoder.intValue(for: .highBit) ?? max(0, bitsStored - 1)
        guard decoder.width > 0, decoder.height > 0 else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JLSwift encoding requires positive Rows and Columns."
            )
        }
        guard decoder.bitDepth == 8 || decoder.bitDepth == 16,
              bitsStored >= 8,
              bitsStored <= decoder.bitDepth,
              highBit == bitsStored - 1 else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JLSwift encoding is qualified for aligned 8- to 16-bit grayscale layouts."
            )
        }
        let photometric = decoder.photometricInterpretation.uppercased()
        let supportedPhotometric: Bool
        if decoder.samplesPerPixel == 1 {
            supportedPhotometric = photometric.isEmpty
                || photometric == "MONOCHROME1"
                || photometric == "MONOCHROME2"
        } else {
            let compressedRGBPhotometrics = ["YBR_RCT", "YBR_ICT"]
            supportedPhotometric = decoder.samplesPerPixel == 3
                && decoder.bitDepth == 8
                && bitsStored == 8
                && decoder.pixelRepresentationTagValue == 0
                && (photometric == "RGB"
                    || decoder.compressedImage && compressedRGBPhotometrics.contains(photometric))
        }
        guard supportedPhotometric else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JLSwift encoding supports MONOCHROME1/2 and unsigned 8-bit RGB; received "
                    + "\(decoder.photometricInterpretation) with \(decoder.samplesPerPixel) sample(s)."
            )
        }
        return DicomCompressedFrameDescriptor(
            transferSyntaxUID: destination.rawValue,
            rows: decoder.height,
            columns: decoder.width,
            bitsAllocated: decoder.bitDepth,
            bitsStored: bitsStored,
            highBit: highBit,
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: decoder.samplesPerPixel == 3 ? "RGB" : photometric,
            planarConfiguration: decoder.samplesPerPixel == 3 ? 0 : nil
        )
    }
}
