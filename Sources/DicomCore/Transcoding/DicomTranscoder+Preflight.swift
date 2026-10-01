import Foundation

extension DicomTranscoder {
    func preflightDecodedSource(
        decoder: DCMDecoder,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        environment: [String: String],
        verifyDecodedPixels: Bool
    ) throws -> DicomTranscodePreflightResult {
        guard decoder.fileReadSucceeded else {
            return .unavailable("The Part 10 file or dataset could not be parsed")
        }
        let source = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID))
            ?? .explicitVRLittleEndian
        let route: DicomTranscodeExecutionRoute
        do {
            route = try resolveExecutionRoute(
                decoder: decoder, source: source, destination: destination, intent: intent, environment: environment
            )
        } catch {
            return .unavailable((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        if !verifyDecodedPixels, route.requiresDecodedSource, source.registryEntry.isCompressed {
            let descriptor = Self.compressedFrameDescriptor(decoder: decoder, syntax: source)
            if decoderUnavailableReason(for: descriptor, environment: environment) != nil {
                return .unavailable("No codec in this build can decode the source pixels")
            }
        }
        guard verifyDecodedPixels, decoder.dataSet.contains(.pixelData) else {
            return .executable
        }
        if source.registryEntry.isCompressed {
            let sourceDescriptor = Self.compressedFrameDescriptor(decoder: decoder, syntax: source)
            if decoderUnavailableReason(for: sourceDescriptor, environment: environment) != nil {
                return .unavailable(DicomTranscodePreflightResult.verificationUnavailableReason)
            }
        }
        if let outputDescriptor = route.outputDescriptor,
           decoderUnavailableReason(for: outputDescriptor, environment: environment) != nil {
            return .unavailable(DicomTranscodePreflightResult.verificationUnavailableReason)
        }
        return .executable
    }

    private func decoderUnavailableReason(
        for descriptor: DicomCompressedFrameDescriptor,
        environment: [String: String]
    ) -> String? {
        DicomCodecCapabilities.resolve(
            DicomCodecCapabilityRequest(operation: .decode, descriptor: descriptor), environment: environment
        ).reason
    }

    static func compressedFrameDescriptor(
        decoder: DCMDecoder,
        syntax: DicomTransferSyntax
    ) -> DicomCompressedFrameDescriptor {
        let bitsStored = decoder.intValue(for: .bitsStored) ?? decoder.bitDepth
        // JPEG 2000 colour transforms (YBR_RCT/YBR_ICT) live in the codestream; decoded samples are RGB, which is
        // what every other family encodes and declares.
        var photometric = decoder.photometricInterpretation
        let j2kFamily = DicomCodecFamily.family(for: syntax) == .jpeg2000 || DicomCodecFamily.family(for: syntax) == .htj2k
        if !j2kFamily, ["YBR_RCT", "YBR_ICT"].contains(photometric.uppercased()) {
            photometric = "RGB"
        }
        return DicomCompressedFrameDescriptor(
            transferSyntaxUID: syntax.rawValue,
            rows: decoder.height,
            columns: decoder.width,
            bitsAllocated: decoder.bitDepth,
            bitsStored: bitsStored,
            highBit: decoder.intValue(for: .highBit) ?? max(0, bitsStored - 1),
            pixelRepresentation: decoder.pixelRepresentationTagValue,
            samplesPerPixel: decoder.samplesPerPixel,
            photometricInterpretation: photometric,
            planarConfiguration: decoder.intValue(for: .planarConfiguration)
        )
    }
}
