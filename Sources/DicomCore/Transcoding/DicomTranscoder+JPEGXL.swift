import Foundation

extension DicomTranscoder {
    func prepareJPEGXLDescriptor(
        decoder: DCMDecoder,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        environment: [String: String]
    ) throws -> DicomCompressedFrameDescriptor {
        if intent.isLossy, Self.iccProfileBytes(in: decoder.dataSet) != nil {
            throw TranscodeError.unsupportedPixelShape(
                reason: "Irreversible JPEG XL transcoding does not carry a DICOM ICC Profile; the reversible routes embed it."
            )
        }
        let descriptor = try jpegXLDescriptor(decoder: decoder, destination: destination)
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

    func compressToJPEGXL(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        descriptor: DicomCompressedFrameDescriptor,
        environment: [String: String]
    ) async throws -> Data {
        let backend = DicomJXLSwiftBackend()

        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let frameCount = max(1, frameReader.frameCount)
        // ICC Profile (0028,2000) travels inside every codestream (C.3.4) and
        // stays in the data set: a passthrough, not a colorimetric conversion.
        let iccProfile = Self.iccProfileBytes(in: decoder.dataSet)
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
                    intent: intent,
                    iccProfile: iccProfile
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
        Self.replaceEncapsulatedPixelData(in: &dataSet, with: encapsulation)
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

    func prepareJPEGRecompressionDescriptor(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) throws -> DicomCompressedFrameDescriptor {
        guard source == .jpegBaseline || source == .jpegExtended else {
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue,
                destinationUID: DicomTransferSyntax.jpegXLJPEGRecompression.rawValue,
                diagnostics: ["JPEG XL JPEG Recompression accepts 8-bit JPEG Baseline (.50) or JPEG Extended (.51) input only."]
            )
        }
        guard intent == .reversible else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG XL JPEG Recompression requires reversible intent."
            )
        }
        return try jpegXLDescriptor(decoder: decoder, destination: .jpegXLJPEGRecompression)
    }

    func recompressJPEGToJPEGXL(
        decoder: DCMDecoder,
        source: DicomTransferSyntax
    ) async throws -> Data {
        let frameReader: DicomEncapsulatedPixelFrameReader
        do {
            frameReader = try decoder.makeEncapsulatedPixelFrameReader()
        } catch {
            throw TranscodeError.decodeFailed(
                sourceUID: source.rawValue,
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
        let backend = DicomJXLSwiftBackend()
        var fragments: [Data] = []
        fragments.reserveCapacity(frameReader.frameCount)
        for index in 0..<frameReader.frameCount {
            let jpeg: Data
            do {
                jpeg = try Self.jpegStreamWithoutDICOMPadding(frameReader.frameData(at: index))
                let expectedProcess: UInt8 = source == .jpegExtended ? 0xC1 : 0xC0
                guard DicomJXLSwiftBackend.jpegProcess(of: jpeg) == expectedProcess else {
                    throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                        reason: "frame \(index) JPEG process does not match source transfer syntax \(source.rawValue)")
                }
                let encoded = try await backend.recompressJPEG(jpeg)
                let reconstructed = try await backend.reconstructJPEG(encoded)
                guard reconstructed == jpeg else {
                    throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                        reason: "frame \(index) did not reconstruct byte-for-byte"
                    )
                }
                fragments.append(encoded)
                decoder.logger.info(
                    "JXLSwift JPEG bridge frame=\(index) source=\(jpeg.count) encoded=\(encoded.count) success=true"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw TranscodeError.encodeFailed(
                    destinationUID: DicomTransferSyntax.jpegXLJPEGRecompression.rawValue,
                    frameIndex: index,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        }

        let encapsulation = try Self.encapsulate(fragments: fragments)
        var dataSet = decoder.dataSet
        Self.replaceEncapsulatedPixelData(in: &dataSet, with: encapsulation)
        return try write(
            dataSet,
            decoder: decoder,
            transferSyntax: .jpegXLJPEGRecompression
        )
    }

    /// `.111` → `.50`/`.51`: every fragment is reconstructed to its JPEG
    /// bytes (never decoded and re-encoded); the process must be the one
    /// the destination syntax names, the data set and SOP identity are kept.
    func prepareJPEGReconstructionDescriptor(
        decoder: DCMDecoder,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) throws -> DicomCompressedFrameDescriptor {
        guard intent == .reversible else {
            throw TranscodeError.unsupportedPixelShape(reason: "JPEG reconstruction from JPEG XL requires reversible intent.")
        }
        let base = try jpegXLDescriptor(decoder: decoder, destination: .jpegXLJPEGRecompression)
        return DicomCompressedFrameDescriptor(
            transferSyntaxUID: destination.rawValue, rows: base.rows, columns: base.columns,
            bitsAllocated: base.bitsAllocated, bitsStored: base.bitsStored, highBit: base.highBit,
            pixelRepresentation: base.pixelRepresentation, samplesPerPixel: base.samplesPerPixel,
            photometricInterpretation: base.photometricInterpretation, planarConfiguration: base.planarConfiguration)
    }

    func reconstructJPEGFromJPEGXL(
        decoder: DCMDecoder,
        destination: DicomTransferSyntax
    ) async throws -> Data {
        let frameReader: DicomEncapsulatedPixelFrameReader
        do {
            frameReader = try decoder.makeEncapsulatedPixelFrameReader()
        } catch {
            throw TranscodeError.decodeFailed(
                sourceUID: DicomTransferSyntax.jpegXLJPEGRecompression.rawValue,
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
        let backend = DicomJXLSwiftBackend()
        // PS3.5 A.4.1: .50 carries SOF0 and .51 carries SOF1, never progressive SOF2.
        let expectedProcesses: [UInt8] = destination == .jpegExtended ? [0xC1] : [0xC0]
        var fragments: [Data] = []
        fragments.reserveCapacity(frameReader.frameCount)
        for index in 0..<frameReader.frameCount {
            do {
                let jpeg = try await backend.reconstructJPEG(frameReader.frameData(at: index))
                let process = DicomJXLSwiftBackend.jpegProcess(of: jpeg)
                guard expectedProcesses.contains(process) else {
                    throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                        reason: "frame \(index) reconstructs to JPEG process 0x\(String(process, radix: 16)), "
                            + "which \(destination.rawValue) does not carry")
                }
                fragments.append(jpeg)
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
        Self.replaceEncapsulatedPixelData(in: &dataSet, with: encapsulation)
        return try write(dataSet, decoder: decoder, transferSyntax: destination)
    }

    /// The bytes of ICC Profile (0028,2000), if present and non-empty.
    static func iccProfileBytes(in dataSet: DicomDataSet) -> Data? {
        guard let element = dataSet.element(for: .iccProfile) else { return nil }
        if case .bytes(let data) = element.value, !data.isEmpty { return data }
        return nil
    }

    private static func jpegStreamWithoutDICOMPadding(_ data: Data) throws -> Data {
        guard data.count >= 4, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else {
            throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                reason: "the source frame is not a JPEG interchange stream"
            )
        }
        var endOfImage: Int?
        for index in stride(from: data.count - 2, through: 0, by: -1) where
            data[index] == 0xFF && data[index + 1] == 0xD9 {
            endOfImage = index + 2
            break
        }
        guard let endOfImage else {
            throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                reason: "the source JPEG frame has no EOI marker"
            )
        }
        guard data[endOfImage...].allSatisfy({ $0 == 0 }) else {
            throw DicomJXLSwiftBackendError.jpegRecompressionFailed(
                reason: "the source JPEG frame has non-padding bytes after EOI"
            )
        }
        return data.prefix(endOfImage)
    }

    private func jpegXLDescriptor(
        decoder: DCMDecoder,
        destination: DicomTransferSyntax
    ) throws -> DicomCompressedFrameDescriptor {
        let bitsStored = decoder.intValue(for: .bitsStored) ?? decoder.bitDepth
        let highBit = decoder.intValue(for: .highBit) ?? max(0, bitsStored - 1)
        guard decoder.width > 0, decoder.height > 0 else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JXLSwift encoding requires positive Rows and Columns."
            )
        }
        let recompression = destination == .jpegXLJPEGRecompression
        guard decoder.bitDepth == 8 || decoder.bitDepth == 16,
              bitsStored >= 1, bitsStored <= decoder.bitDepth,
              highBit == bitsStored - 1,
              !recompression || bitsStored == 8 else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG XL encoding requires Bits Allocated 8 or 16 with Bits Stored 1...Bits Allocated "
                    + "and High Bit = Bits Stored - 1 (JPEG recompression: 8-bit only)."
            )
        }
        let photometric = decoder.photometricInterpretation.uppercased()
        let supportedPhotometric: Bool
        if destination == .jpegXLJPEGRecompression {
            let monochrome = decoder.samplesPerPixel == 1 && photometric == "MONOCHROME2"
            let color = decoder.samplesPerPixel == 3
                && ["RGB", "YBR_FULL_422"].contains(photometric)
                && decoder.intValue(for: .planarConfiguration) == 0
            supportedPhotometric = decoder.bitDepth == 8
                && decoder.pixelRepresentationTagValue == 0
                && (monochrome || color)
        } else if decoder.samplesPerPixel == 1 {
            supportedPhotometric = photometric.isEmpty
                || photometric == "MONOCHROME1"
                || photometric == "MONOCHROME2"
        } else {
            let decodedColorPhotometrics = ["RGB", "YBR_RCT", "YBR_ICT", "YBR_FULL_422"]
            supportedPhotometric = decoder.samplesPerPixel == 3
                && bitsStored == 8 && decoder.bitDepth == 8
                && decoder.pixelRepresentationTagValue == 0
                && decodedColorPhotometrics.contains(photometric)
        }
        guard supportedPhotometric else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG XL supports MONOCHROME1/2 (1...16 bits, signed or unsigned) and unsigned RGB8; "
                    + "JPEG recompression is limited to JPEG Baseline or JPEG Extended 8-bit MONOCHROME2 or RGB/YBR_FULL_422."
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
            photometricInterpretation: destination == .jpegXLJPEGRecompression
                ? photometric
                : (decoder.samplesPerPixel == 3 ? "RGB" : photometric),
            planarConfiguration: decoder.samplesPerPixel == 3 ? 0 : nil
        )
    }
}
