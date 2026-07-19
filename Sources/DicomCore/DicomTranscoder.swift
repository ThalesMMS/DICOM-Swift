//
//  DicomTranscoder.swift
//  DicomCore
//
//  Executable transfer syntax transcoding routes (issue #1237). The
//  registry's transcode planner stays the decision authority; this
//  executor runs the supported routes as file-level operations:
//
//  - passThrough / rewriteNative: a safe Part 10 rewrite carrying every
//    element and the Pixel Data bytes unchanged (encapsulated payloads
//    byte-for-byte) into the destination syntax's writer path.
//  - decompress: compressed sources whose decode backend is active are
//    decoded frame-by-frame through DicomDecodedFrameReader and written
//    as Explicit VR Little Endian with stored-value pixel fidelity.
//  - compress / recompress: JPEG-LS Lossless remains available through
//    CharLS; the async overloads add explicit-intent J2KSwift CPU routes
//    for JPEG 2000 and HTJ2K.
//

import Foundation

public struct DicomTranscoder {
    public enum TranscodeError: Error, Equatable, LocalizedError, Sendable {
        /// The planner rejected the route; diagnostics carry the reasons.
        case routeUnsupported(sourceUID: String, destinationUID: String, diagnostics: [String])
        /// The source's frames could not be decoded.
        case decodeFailed(sourceUID: String, reason: String)
        /// The source's pixel shape cannot be converted with fidelity.
        case unsupportedPixelShape(reason: String)
        /// A frame failed during destination encoding.
        case encodeFailed(destinationUID: String, frameIndex: Int, reason: String)

        public var errorDescription: String? {
            switch self {
            case .routeUnsupported(let source, let destination, let diagnostics):
                return "Transcoding \(source) to \(destination) is unsupported: \(diagnostics.joined(separator: " "))"
            case .decodeFailed(let source, let reason):
                return "Decoding \(source) frames failed: \(reason)"
            case .unsupportedPixelShape(let reason):
                return "The pixel shape cannot be transcoded with fidelity: \(reason)"
            case .encodeFailed(let destination, let frameIndex, let reason):
                return "Encoding frame \(frameIndex) for \(destination) failed: \(reason)"
            }
        }
    }

    public init() {}

    /// Transcodes a Part 10 file on disk into the destination syntax.
    public func transcode(contentsOf url: URL, to destination: DicomTransferSyntax) throws -> Data {
        try transcode(decoder: DCMDecoder(contentsOf: url), to: destination)
    }

    /// Transcodes in-memory Part 10 bytes into the destination syntax.
    public func transcode(_ data: Data, to destination: DicomTransferSyntax) throws -> Data {
        try transcode(decoder: DCMDecoder(data: data), to: destination)
    }

    /// Transcodes a Part 10 file using an explicit JPEG 2000/HTJ2K encoding intent.
    public func transcode(
        contentsOf url: URL,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) async throws -> Data {
        try await transcode(decoder: DCMDecoder(contentsOf: url), to: destination, intent: intent)
    }

    /// Transcodes in-memory Part 10 bytes using an explicit JPEG 2000/HTJ2K encoding intent.
    public func transcode(
        _ data: Data,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) async throws -> Data {
        try await transcode(decoder: DCMDecoder(data: data), to: destination, intent: intent)
    }

    func transcode(decoder: DCMDecoder, to destination: DicomTransferSyntax) throws -> Data {
        let source = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID)) ?? .explicitVRLittleEndian
        let plan = DicomTransferSyntaxRegistry.standard.transcodePlan(from: source, to: destination)

        switch plan.route {
        case .passThrough, .rewriteNative:
            return try writeCarryingDataset(decoder: decoder, destination: destination)

        case .decompress:
            guard destination == .explicitVRLittleEndian else {
                throw TranscodeError.routeUnsupported(
                    sourceUID: source.rawValue,
                    destinationUID: destination.rawValue,
                    diagnostics: ["Decompression targets Explicit VR Little Endian only."]
                )
            }
            return try decompressToNative(decoder: decoder, source: source)

        case .compress:
            guard destination == .jpegLSLossless else {
                throw TranscodeError.routeUnsupported(
                    sourceUID: source.rawValue,
                    destinationUID: destination.rawValue,
                    diagnostics: plan.diagnostics.map(\.message)
                        + ["JPEG-LS Lossless is the only executable lossless encoder route."]
                )
            }
            return try compressToJPEGLSLossless(decoder: decoder, source: source)

        case .reference, .recompress:
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue,
                destinationUID: destination.rawValue,
                diagnostics: plan.diagnostics.map(\.message)
            )
        }
    }

    func transcode(
        decoder: DCMDecoder,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) async throws -> Data {
        let source = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID))
            ?? .explicitVRLittleEndian
        let plan = DicomTransferSyntaxRegistry.standard.transcodePlan(from: source, to: destination)

        switch plan.route {
        case .passThrough, .rewriteNative:
            return try transcode(decoder: decoder, to: destination)
        case .decompress:
            if DicomCodecFamily.family(for: source) == .jpegXL {
                guard DicomJXLSwiftRolloutMode() != .disabled else {
                    throw TranscodeError.routeUnsupported(
                        sourceUID: source.rawValue,
                        destinationUID: destination.rawValue,
                        diagnostics: [
                            "Experimental JPEG XL decoding requires DICOM_JXLSWIFT_MODE=experimental."
                        ]
                    )
                }
                guard destination == .explicitVRLittleEndian else {
                    throw TranscodeError.routeUnsupported(
                        sourceUID: source.rawValue,
                        destinationUID: destination.rawValue,
                        diagnostics: ["Decompression targets Explicit VR Little Endian only."]
                    )
                }
                return try await decompressJPEGXLToNative(decoder: decoder, source: source)
            }
            return try transcode(decoder: decoder, to: destination)
        case .compress, .recompress:
            if Self.isJPEGXLFrameSyntax(destination) {
                guard DicomJXLSwiftRolloutMode() != .disabled else {
                    throw TranscodeError.routeUnsupported(
                        sourceUID: source.rawValue,
                        destinationUID: destination.rawValue,
                        diagnostics: [
                            "Experimental JPEG XL transcoding requires DICOM_JXLSWIFT_MODE=experimental."
                        ]
                    )
                }
                if destination == .jpegXLJPEGRecompression {
                    return try await recompressJPEGToJPEGXL(
                        decoder: decoder,
                        source: source,
                        intent: intent
                    )
                }
                return try await compressToJPEGXL(
                    decoder: decoder,
                    source: source,
                    destination: destination,
                    intent: intent
                )
            }
            if Self.isJPEGLSFrameSyntax(destination) {
                return try await compressToJPEGLS(
                    decoder: decoder,
                    source: source,
                    destination: destination,
                    intent: intent
                )
            }
            guard Self.isJ2KFrameSyntax(destination) else {
                return try transcode(decoder: decoder, to: destination)
            }
            return try await compressToJ2K(
                decoder: decoder,
                source: source,
                destination: destination,
                intent: intent
            )
        case .reference:
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue,
                destinationUID: destination.rawValue,
                diagnostics: plan.diagnostics.map(\.message)
            )
        }
    }

    // MARK: - Routes

    private func writeCarryingDataset(decoder: DCMDecoder, destination: DicomTransferSyntax) throws -> Data {
        let dataSet = DicomAnonymizer.datasetCarryingPixelBytes(from: decoder)
        return try write(dataSet, decoder: decoder, transferSyntax: destination)
    }

    private func decompressToNative(decoder: DCMDecoder, source: DicomTransferSyntax) throws -> Data {
        let (pixelBytes, samplesPerPixel) = try nativePixelBytes(decoder: decoder, source: source)

        var dataSet = decoder.dataSet
        dataSet.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: decoder.bitDepth > 8 ? .OW : .OB,
            value: .bytes(pixelBytes)
        ))
        if samplesPerPixel == 3 {
            // Decoded color output is interleaved.
            dataSet.set(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US,
                                         value: .unsignedIntegers([0])))
        }
        return try write(dataSet, decoder: decoder, transferSyntax: .explicitVRLittleEndian)
    }

    private func decompressJPEGXLToNative(
        decoder: DCMDecoder,
        source: DicomTransferSyntax
    ) async throws -> Data {
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        var pixelBytes = Data()
        var samplesPerPixel = 1
        for index in 0..<max(1, frameReader.frameCount) {
            let frame: DicomDecodedFrame
            do {
                frame = try await frameReader.frame(at: index)
            } catch {
                throw TranscodeError.decodeFailed(
                    sourceUID: source.rawValue,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
            if case .rgb8 = frame.pixels { samplesPerPixel = 3 }
            pixelBytes.append(try storedBytes(from: frame, decoder: decoder))
        }
        if !pixelBytes.count.isMultiple(of: 2) {
            pixelBytes.append(0x00)
        }

        var dataSet = decoder.dataSet
        dataSet.remove(.extendedOffsetTable)
        dataSet.remove(.extendedOffsetTableLengths)
        dataSet.set(DicomDataElement(
            tag: DicomTag.pixelData.rawValue,
            vr: decoder.bitDepth > 8 ? .OW : .OB,
            value: .bytes(pixelBytes)
        ))
        if samplesPerPixel == 3 {
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
        return try write(dataSet, decoder: decoder, transferSyntax: .explicitVRLittleEndian)
    }

    private func compressToJPEGLSLossless(decoder: DCMDecoder, source: DicomTransferSyntax) throws -> Data {
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

    private func compressToJ2K(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) async throws -> Data {
        let descriptor = try j2kDescriptor(decoder: decoder, destination: destination)
        if case .jpegLSNearLossless = intent {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG-LS NEAR intent cannot be used for JPEG 2000 or HTJ2K."
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
        let backend = DicomJ2KSwiftBackend()
        if let reason = backend.capabilities.unsupportedReason(for: descriptor, operation: .encode) {
            throw TranscodeError.unsupportedPixelShape(reason: reason)
        }

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
                source: source
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
                intent: intent
            )
            do {
                var codestream = try await backend.encode(request)
                encodedByteCount += codestream.count
                if codestream.count % 2 != 0 {
                    codestream.append(0x00)
                }
                fragments.append(codestream)
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
                encodedByteCount: encodedByteCount
            )
        }
        return try write(
            dataSet,
            decoder: decoder,
            transferSyntax: destination,
            sopInstanceUID: outputSOPInstanceUID
        )
    }

    private func compressToJPEGLS(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) async throws -> Data {
        let descriptor = try jpegLSDescriptor(decoder: decoder, destination: destination)
        let backend = DicomJLSwiftBackend()
        if let reason = backend.capabilities.unsupportedReason(for: descriptor, operation: .encode) {
            throw TranscodeError.unsupportedPixelShape(reason: reason)
        }

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
                source: source
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
                encodedByteCount: encodedByteCount
            )
        }
        return try write(
            dataSet,
            decoder: decoder,
            transferSyntax: destination,
            sopInstanceUID: outputSOPInstanceUID
        )
    }

    private func compressToJPEGXL(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) async throws -> Data {
        guard decoder.dataSet.element(for: .iccProfile) == nil else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG XL transcoding with a DICOM ICC Profile remains outside the qualified route."
            )
        }
        let descriptor = try jpegXLDescriptor(decoder: decoder, destination: destination)
        let backend = DicomJXLSwiftBackend()
        if let reason = backend.capabilities.unsupportedReason(for: descriptor, operation: .encode) {
            throw TranscodeError.unsupportedPixelShape(reason: reason)
        }

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
                source: source
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
                encodedByteCount: encodedByteCount
            )
        }
        return try write(
            dataSet,
            decoder: decoder,
            transferSyntax: destination,
            sopInstanceUID: outputSOPInstanceUID
        )
    }

    private func recompressJPEGToJPEGXL(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        intent: DicomEncodingIntent
    ) async throws -> Data {
        guard source == .jpegBaseline else {
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue,
                destinationUID: DicomTransferSyntax.jpegXLJPEGRecompression.rawValue,
                diagnostics: ["JPEG XL JPEG Recompression accepts JPEG Baseline (Process 1) input only."]
            )
        }
        guard intent == .reversible else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JPEG XL JPEG Recompression requires reversible intent."
            )
        }
        _ = try jpegXLDescriptor(decoder: decoder, destination: .jpegXLJPEGRecompression)
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

    // MARK: - Stored-value pixel reconstruction

    private func nativePixelBytes(decoder: DCMDecoder, source: DicomTransferSyntax) throws -> (Data, Int) {
        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        var pixelBytes = Data()
        var samplesPerPixel = 1
        for index in 0..<max(1, frameReader.frameCount) {
            let frame: DicomDecodedFrame
            do {
                frame = try frameReader.frame(at: index)
            } catch {
                throw TranscodeError.decodeFailed(
                    sourceUID: source.rawValue,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
            if case .rgb8 = frame.pixels { samplesPerPixel = 3 }
            pixelBytes.append(try storedBytes(from: frame, decoder: decoder))
        }
        if pixelBytes.count % 2 != 0 {
            pixelBytes.append(0x00)
        }
        return (pixelBytes, samplesPerPixel)
    }

    private func storedFrameBytes(
        frameReader: DicomDecodedFrameReader,
        decoder: DCMDecoder,
        frameIndex: Int
    ) throws -> Data {
        let frame: DicomDecodedFrame
        do {
            frame = try frameReader.frame(at: frameIndex)
        } catch {
            throw TranscodeError.decodeFailed(
                sourceUID: decoder.info(for: .transferSyntaxUID),
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
        return try storedBytes(from: frame, decoder: decoder)
    }

    private func storedFrameBytes(
        frameReader: DicomDecodedFrameReader,
        decoder: DCMDecoder,
        frameIndex: Int,
        source: DicomTransferSyntax
    ) async throws -> Data {
        if !decoder.compressedImage, decoder.samplesPerPixel == 3 {
            do {
                return try decoder.displayRGBPixelBuffer(frame: frameIndex).rgbData
            } catch {
                throw TranscodeError.decodeFailed(
                    sourceUID: source.rawValue,
                    reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
                )
            }
        }
        let frame: DicomDecodedFrame
        do {
            frame = try await frameReader.frame(at: frameIndex)
        } catch {
            throw TranscodeError.decodeFailed(
                sourceUID: source.rawValue,
                reason: (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
        return try storedBytes(from: frame, decoder: decoder)
    }

    /// Rebuilds little-endian stored-value bytes from a decoded frame by
    /// undoing the display normalization in reverse order: decoding
    /// applies the signed offset first and then the MONOCHROME1
    /// full-range inversion (255/65535 − value, regardless of Bits
    /// Stored), so this path un-inverts first and then removes the
    /// signed offset. The output dataset keeps Photometric
    /// Interpretation=MONOCHROME1, so stored values and the tag stay
    /// consistent.
    private func storedBytes(from frame: DicomDecodedFrame, decoder: DCMDecoder) throws -> Data {
        let inverted = decoder.photometricInterpretation == "MONOCHROME1"
        let signed = decoder.pixelRepresentationTagValue == 1

        switch frame.pixels {
        case .gray16(let pixels):
            var bytes = Data(capacity: pixels.count * 2)
            for value in pixels {
                let unInverted = inverted ? UInt16.max - value : value
                let pattern: UInt16
                if signed {
                    pattern = UInt16(bitPattern: Int16(truncatingIfNeeded: Int32(unInverted) + Int32(Int16.min)))
                } else {
                    pattern = unInverted
                }
                bytes.append(UInt8(pattern & 0xFF))
                bytes.append(UInt8(pattern >> 8))
            }
            return bytes
        case .gray8(let pixels):
            return Data(pixels.map { value -> UInt8 in
                let unInverted = inverted ? UInt8.max - value : value
                if signed {
                    return UInt8(bitPattern: Int8(truncatingIfNeeded: Int(unInverted) - 128))
                }
                return unInverted
            })
        case .rgb8(let interleaved):
            return Data(interleaved)
        }
    }

    // MARK: - Helpers

    private func write(
        _ dataSet: DicomDataSet,
        decoder: DCMDecoder,
        transferSyntax: DicomTransferSyntax,
        sopInstanceUID outputSOPInstanceUID: String? = nil
    ) throws -> Data {
        let sopClassUID = decoder.info(for: .sopClassUID)
        let sourceSOPInstanceUID = decoder.info(for: .sopInstanceUID)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: sopClassUID.isEmpty ? nil : sopClassUID,
                mediaStorageSOPInstanceUID: outputSOPInstanceUID
                    ?? (sourceSOPInstanceUID.isEmpty ? nil : sourceSOPInstanceUID)
            )
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
        guard decoder.bitDepth == 8 || decoder.bitDepth == 16,
              bitsStored == decoder.bitDepth,
              highBit == bitsStored - 1 else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JXLSwift is qualified only for aligned 8- or 16-bit layouts; 10/12-bit routes remain disabled."
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
                && decoder.bitDepth == 8
                && decoder.pixelRepresentationTagValue == 0
                && decodedColorPhotometrics.contains(photometric)
        }
        guard supportedPhotometric else {
            throw TranscodeError.unsupportedPixelShape(
                reason: "JXLSwift supports MONOCHROME1/2 and unsigned RGB8; JPEG recompression is limited "
                    + "to JPEG Baseline 8-bit MONOCHROME2 or RGB/YBR_FULL_422."
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

    private static func isJ2KFrameSyntax(_ syntax: DicomTransferSyntax) -> Bool {
        switch syntax {
        case .jpeg2000Lossless, .jpeg2000, .htj2kLossless, .htj2kLosslessRPCL, .htj2k:
            return true
        default:
            return false
        }
    }

    private static func isJPEGLSFrameSyntax(_ syntax: DicomTransferSyntax) -> Bool {
        syntax == .jpegLSLossless || syntax == .jpegLSNearLossless
    }

    private static func isJPEGXLFrameSyntax(_ syntax: DicomTransferSyntax) -> Bool {
        syntax == .jpegXLLossless || syntax == .jpegXLJPEGRecompression || syntax == .jpegXL
    }

    private static func applyLossyMetadata(
        to dataSet: inout DicomDataSet,
        destination: DicomTransferSyntax,
        uncompressedByteCount: Int,
        encodedByteCount: Int
    ) {
        dataSet.set(DicomDataElement(
            tag: DicomTag.lossyImageCompression.rawValue,
            vr: .CS,
            value: .strings(["01"])
        ))
        var methods = dataSet.strings(for: .lossyImageCompressionMethod)
        switch destination {
        case .jpegLSNearLossless:
            methods.append("ISO_14495_1")
        case .jpegXL:
            methods.append("ISO_18181_1")
        case .htj2k:
            methods.append("ISO_15444_15")
        default:
            methods.append("ISO_15444_1")
        }
        dataSet.set(DicomDataElement(
            tag: DicomTag.lossyImageCompressionMethod.rawValue,
            vr: .CS,
            value: .strings(methods)
        ))
        let ratio = encodedByteCount > 0
            ? Double(uncompressedByteCount) / Double(encodedByteCount)
            : 0
        var ratios = dataSet.strings(for: .lossyImageCompressionRatio)
        ratios.append(String(format: "%.6g", ratio))
        dataSet.set(DicomDataElement(
            tag: DicomTag.lossyImageCompressionRatio.rawValue,
            vr: .DS,
            value: .strings(ratios)
        ))

        var imageType = dataSet.strings(for: .imageType)
        if imageType.isEmpty {
            imageType = ["DERIVED", "PRIMARY"]
        } else {
            imageType[0] = "DERIVED"
        }
        dataSet.set(DicomDataElement(
            tag: DicomTag.imageType.rawValue,
            vr: .CS,
            value: .strings(imageType)
        ))
        let codecName: String
        switch destination {
        case .jpegLSNearLossless:
            codecName = "JPEG-LS"
        case .jpegXL:
            codecName = "JPEG XL"
        case .htj2k:
            codecName = "HTJ2K"
        default:
            codecName = "JPEG 2000"
        }
        let operationDescription = "Irreversible \(codecName) transcoding"
        let existingDescription = dataSet.string(for: .derivationDescription)
        let description = existingDescription.map { "\($0); \(operationDescription)" }
            ?? operationDescription
        dataSet.set(DicomDataElement(
            tag: DicomTag.derivationDescription.rawValue,
            vr: .ST,
            value: .strings([description])
        ))
    }

    static func encapsulate(
        fragments: [Data],
        forceExtendedOffsets: Bool = false
    ) throws -> (
        pixelData: Data,
        extendedOffsetTable: Data?,
        extendedOffsetTableLengths: Data?
    ) {
        let paddedFragments = fragments.map { fragment -> Data in
            guard !fragment.count.isMultiple(of: 2) else { return fragment }
            var padded = fragment
            padded.append(0x00)
            return padded
        }
        var offsets: [UInt64] = []
        var running: UInt64 = 0
        for fragment in paddedFragments {
            offsets.append(running)
            let itemLength = UInt64(fragment.count) + 8
            let next = running.addingReportingOverflow(itemLength)
            guard !next.overflow else {
                throw TranscodeError.unsupportedPixelShape(
                    reason: "Encapsulated frame offsets exceed the DICOM 64-bit table range."
                )
            }
            running = next.partialValue
        }
        let useExtendedOffsets = forceExtendedOffsets
            || offsets.contains { $0 > UInt64(UInt32.max) }
        var basicOffsetTable = Data()
        if !useExtendedOffsets {
            for offset in offsets {
                let value = UInt32(offset)
                withUnsafeBytes(of: value.littleEndian) {
                    basicOffsetTable.append(contentsOf: $0)
                }
            }
        }

        var data = Data()
        appendItem(basicOffsetTable, to: &data)
        for fragment in paddedFragments {
            appendItem(fragment, to: &data)
        }
        // Sequence delimiter.
        data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0x00, 0x00, 0x00, 0x00])
        guard useExtendedOffsets else { return (data, nil, nil) }
        var extendedOffsets = Data()
        var extendedLengths = Data()
        for (offset, fragment) in zip(offsets, paddedFragments) {
            withUnsafeBytes(of: offset.littleEndian) { extendedOffsets.append(contentsOf: $0) }
            let length = UInt64(fragment.count)
            withUnsafeBytes(of: length.littleEndian) { extendedLengths.append(contentsOf: $0) }
        }
        return (data, extendedOffsets, extendedLengths)
    }

    private static func replaceEncapsulatedPixelData(
        in dataSet: inout DicomDataSet,
        with encapsulation: (
            pixelData: Data,
            extendedOffsetTable: Data?,
            extendedOffsetTableLengths: Data?
        )
    ) {
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

    private static func appendItem(_ payload: Data, to data: inout Data) {
        data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
    }
}
