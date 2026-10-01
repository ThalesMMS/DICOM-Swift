import Foundation

extension DicomTranscoder {
    func prepareJ2KDescriptor(
        decoder: DCMDecoder,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        environment: [String: String]
    ) throws -> DicomCompressedFrameDescriptor {
        let descriptor = try j2kDescriptor(decoder: decoder, destination: destination)
        if case .jpegLSNearLossless = intent {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG-LS NEAR intent cannot be used for JPEG 2000 or HTJ2K."
            )
        }
        if case .jpegLossless = intent {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG lossless predictor options cannot be used for JPEG 2000 or HTJ2K."
            )
        }
        if case .jpegLS = intent {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG-LS options cannot be used for JPEG 2000 or HTJ2K."
            )
        }
        if case .irreversible = intent,
           destination == .jpeg2000Lossless
            || destination == .htj2kLossless
            || destination == .htj2kLosslessRPCL {
            throw TranscodeError.unsupportedPixelShape(
                reason: "Irreversible encoding cannot target a lossless-only transfer syntax."
            )
        }
        if case .irreversible(let quality) = intent,
           !(quality > 0 && quality < 1 && quality.isFinite) {
            throw TranscodeError.unsupportedPixelShape(
                reason: "Irreversible quality must be finite and strictly between zero and one."
            )
        }
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

    func compressToJ2K(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        descriptor: DicomCompressedFrameDescriptor,
        environment: [String: String],
        jpeg2000Options: DicomJPEG2000EncodingOptions? = nil
    ) async throws -> Data {
        let backend = DicomJ2KSwiftBackend()

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
            let request = DicomFrameEncodeRequest(
                frame: frame,
                descriptor: descriptor,
                targetTransferSyntaxUID: destination.rawValue,
                intent: intent, jpeg2000Options: jpeg2000Options
            )
            do {
                var codestream = try await backend.encode(request)
                encodedByteCount += codestream.count
                if codestream.count % 2 != 0 {
                    codestream.append(0x00)
                }
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
            let photometric = intent.isLossy ? "YBR_ICT" : "YBR_RCT"
            dataSet.set(DicomDataElement(
                tag: DicomTag.photometricInterpretation.rawValue,
                vr: .CS,
                value: .strings([photometric])
            ))
            dataSet.set(DicomDataElement(
                tag: DicomTag.planarConfiguration.rawValue,
                vr: .US,
                value: .unsignedIntegers([0])
            ))
        }
        var outputSOPInstanceUID: String?
        if intent.isLossy {
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

    private func j2kDescriptor(
        decoder: DCMDecoder,
        destination: DicomTransferSyntax
    ) throws -> DicomCompressedFrameDescriptor {
        let bitsStored = decoder.intValue(for: .bitsStored) ?? decoder.bitDepth
        let highBit = decoder.intValue(for: .highBit) ?? max(0, bitsStored - 1)
        guard decoder.width > 0, decoder.height > 0 else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "J2KSwift encoding requires positive Rows and Columns."
            )
        }
        guard decoder.bitDepth == 8 || decoder.bitDepth == 16,
              bitsStored > 0,
              bitsStored <= decoder.bitDepth,
              highBit == bitsStored - 1 else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "J2KSwift encoding requires an aligned 8- or 16-bit integer pixel layout."
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
                reason: "J2KSwift encoding supports MONOCHROME1/2 and unsigned 8-bit RGB; received "
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

// MARK: - JPEG 2000 Part 2 component collections (#2331)

extension DicomTranscoder {
    /// Descriptor of a `.92/.93` destination: single-sample frames only (every frame becomes a component), the
    /// lossless-only syntax refuses irreversible intent, and the encoder is resolved as experimental.
    func prepareJ2KPart2Descriptor(
        decoder: DCMDecoder,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        environment: [String: String]
    ) throws -> DicomCompressedFrameDescriptor {
        let descriptor = try j2kDescriptor(decoder: decoder, destination: destination)
        guard descriptor.samplesPerPixel == 1 else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG 2000 Part 2 Multi-component codes the frames as components; only single-sample (grayscale) frames are supported."
            )
        }
        switch intent {
        case .jpegLSNearLossless, .jpegLossless, .jpegLS, .jpegXL:
            throw TranscodeError.unsupportedPixelShape(reason: "JPEG-LS, JPEG lossless and JPEG XL options cannot be used for JPEG 2000 Part 2.")
        case .irreversible(let quality):
            guard destination != .jpeg2000Part2MulticomponentLossless else {
                throw TranscodeError.unsupportedPixelShape(reason: "Irreversible encoding cannot target a lossless-only transfer syntax.")
            }
            guard quality > 0, quality < 1, quality.isFinite else {
                throw TranscodeError.unsupportedPixelShape(reason: "Irreversible quality must be finite and strictly between zero and one.")
            }
        case .reversible:
            break
        }
        let decision = DicomCodecCapabilities.resolve(
            DicomCodecCapabilityRequest(operation: .encode, descriptor: descriptor, intent: intent), environment: environment
        )
        guard decision.canExecute else {
            throw TranscodeError.unsupportedPixelShape(reason: decision.reason ?? "No JPEG 2000 Part 2 encoder is available.")
        }
        return descriptor
    }

    /// Encodes every frame of the object into component collections of at most
    /// `DicomJ2KPart2Profile.framesPerCollection` frames (one fragment each, empty Basic Offset Table as the
    /// fragments are not frames) and writes the `.92/.93` object.
    func compressToJ2KPart2(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        descriptor: DicomCompressedFrameDescriptor,
        environment: [String: String]
    ) async throws -> Data {
        let backend = DicomJ2KSwiftBackend()
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let frameCount = max(1, frameReader.frameCount)
        var fragments: [Data] = []
        var encodedByteCount = 0
        var uncompressedByteCount = 0
        var start = 0
        while start < frameCount {
            let end = min(frameCount, start + DicomJ2KPart2Profile.framesPerCollection)
            var frames: [Data] = []
            for index in start..<end {
                try Task.checkCancellation()
                let storedBytes = try await storedFrameBytes(frameReader: frameReader, decoder: decoder, frameIndex: index,
                                                             source: source, environment: environment)
                let byteCount = uncompressedByteCount.addingReportingOverflow(storedBytes.count)
                guard !byteCount.overflow else {
                    throw TranscodeError.unsupportedPixelShape(reason: "The decoded frames exceed the addressable byte range.")
                }
                uncompressedByteCount = byteCount.partialValue
                frames.append(storedBytes)
            }
            do {
                var codestream = try await backend.encodeCollection(
                    frames: frames, descriptor: descriptor, targetTransferSyntaxUID: destination.rawValue, intent: intent)
                encodedByteCount += codestream.count
                if codestream.count % 2 != 0 { codestream.append(0x00) }
                fragments.append(codestream)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscodeError.encodeFailed(
                    destinationUID: destination.rawValue, frameIndex: start,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
            start = end
        }
        let encapsulation = try Self.encapsulate(fragments: fragments, emptyBasicOffsetTable: true)
        var dataSet = decoder.dataSet
        dataSet.remove(.extendedOffsetTable)
        dataSet.remove(.extendedOffsetTableLengths)
        dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(encapsulation.pixelData)))
        var outputSOPInstanceUID: String?
        if intent.isLossy {
            let derivedSOPInstanceUID = DicomDataSetWriter.makeUID()
            outputSOPInstanceUID = derivedSOPInstanceUID
            dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([derivedSOPInstanceUID])))
            Self.applyLossyMetadata(
                to: &dataSet, destination: destination, uncompressedByteCount: uncompressedByteCount, encodedByteCount: encodedByteCount,
                sourceSOPClassUID: decoder.info(for: .sopClassUID), sourceSOPInstanceUID: decoder.info(for: .sopInstanceUID)
            )
        }
        return try write(dataSet, decoder: decoder, transferSyntax: destination, sopInstanceUID: outputSOPInstanceUID)
    }
}
