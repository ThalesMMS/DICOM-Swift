import Foundation

extension DicomTranscoder {
    func resolveExecutionRoute(
        decoder: DCMDecoder,
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        environment: [String: String],
        jpeg2000Options: DicomJPEG2000EncodingOptions? = nil
    ) throws -> DicomTranscodeExecutionRoute {
        if let jpeg2000Options {
            guard decoder.dataSet.contains(.pixelData) else {
                throw DicomJPEG2000EncodingError.unsupportedConfiguration(reason: "encoding options require Pixel Data")
            }
            // Explicit packet configuration always re-encodes, including same-UID and superset routes.
            let descriptor = Self.compressedFrameDescriptor(decoder: decoder, syntax: destination)
            _ = try jpeg2000Options.resolved(descriptor: descriptor, intent: intent)
            return .jpeg2000(try prepareJ2KDescriptor(decoder: decoder, destination: destination, intent: intent, environment: environment))
        }
        // The carrying writer preserves binary value bytes; it does not convert OW words to Big Endian.
        if destination == .explicitVRBigEndian, source != destination {
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue, destinationUID: destination.rawValue,
                diagnostics: ["Explicit VR Big Endian generation is unavailable: binary value byte-order conversion is not implemented."]
            )
        }
        if intent.isLossy, destination.registryEntry.pixelEncoding == .native {
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue, destinationUID: destination.rawValue,
                diagnostics: ["Native pixel output does not accept lossy encoding intent."]
            )
        }
        let plan = Self.executionPlan(from: source, to: destination, intent: intent)
        // Deflate keeps native pixels: a rewrite from a native source, a decode from a compressed one.
        if destination.registryEntry.pixelEncoding == .native, source != destination, !intent.isLossy {
            if source.registryEntry.pixelEncoding == .native { return .carryDataset(nil) }
            if source.registryEntry.pixelEncoding == .encapsulated {
                if DicomCodecFamily.family(for: source) == .jpegXL {
                    try validateJPEGXLRollout(source: source, destination: destination, environment: environment, operation: "decoding")
                }
                try validateDecompressionDestination(source: source, destination: destination)
                return .decompress
            }
        }
        switch plan.route {
        case .passThrough, .rewriteNative:
            return .carryDataset(destination.registryEntry.isCompressed
                ? Self.compressedFrameDescriptor(decoder: decoder, syntax: destination) : nil)
        case .decompress:
            if DicomCodecFamily.family(for: source) == .jpegXL {
                try validateJPEGXLRollout(source: source, destination: destination, environment: environment,
                                         operation: "decoding")
            }
            try validateDecompressionDestination(source: source, destination: destination)
            return .decompress
        case .compress, .recompress:
            if source == .jpegXLJPEGRecompression, destination == .jpegBaseline || destination == .jpegExtended {
                try validateJPEGXLRollout(source: source, destination: destination, environment: environment,
                                         operation: "transcoding")
                return .jpegReconstruction(try prepareJPEGReconstructionDescriptor(
                    decoder: decoder, destination: destination, intent: intent
                ))
            }
            if Self.isJPEGXLFrameSyntax(destination) {
                try validateJPEGXLRollout(source: source, destination: destination, environment: environment,
                                         operation: "transcoding")
                if destination == .jpegXLJPEGRecompression {
                    return .jpegRecompression(try prepareJPEGRecompressionDescriptor(
                        decoder: decoder, source: source, intent: intent
                    ))
                }
                return .jpegXL(try prepareJPEGXLDescriptor(decoder: decoder, destination: destination, intent: intent, environment: environment))
            }
            if Self.isJPEGLSFrameSyntax(destination) {
                return .jpegLS(try prepareJPEGLSDescriptor(decoder: decoder, destination: destination, intent: intent, environment: environment))
            }
            if Self.isJ2KFrameSyntax(destination) {
                return .jpeg2000(try prepareJ2KDescriptor(decoder: decoder, destination: destination, intent: intent, environment: environment))
            }
            if DicomJ2KPart2Profile.isPart2(destination.rawValue) {
                return .jpeg2000Part2(try prepareJ2KPart2Descriptor(decoder: decoder, destination: destination, intent: intent, environment: environment))
            }
            if destination == .rleLossless {
                return .rle(try prepareRLEDescriptor(decoder: decoder, source: source, intent: intent))
            }
            if destination == .deflatedImageFrameCompression {
                return .deflatedFrames(try prepareDeflatedFramesDescriptor(decoder: decoder, source: source, intent: intent))
            }
            if DicomCodecFamily.family(for: destination) == .jpeg {
                return .jpeg(try prepareJPEGDescriptor(decoder: decoder, source: source, destination: destination, intent: intent))
            }
            let diagnostics = plan.diagnostics.map(\.message)
                + (plan.route == .compress
                    ? ["Executable encoder families are JPEG, JPEG-LS, JPEG 2000/HTJ2K, JPEG 2000 Part 2, RLE, and JPEG XL."]
                    : [])
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue, destinationUID: destination.rawValue, diagnostics: diagnostics
            )
        case .reference:
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue, destinationUID: destination.rawValue,
                diagnostics: plan.diagnostics.map(\.message)
            )
        }
    }

    /// Explicit quality requests require encoding even when the UID is unchanged.
    static func executionPlan(
        from source: DicomTransferSyntax,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent,
        jpeg2000Options: DicomJPEG2000EncodingOptions? = nil
    ) -> DicomTranscodePlan {
        let plan = DicomTransferSyntaxRegistry.standard.transcodePlan(from: source, to: destination)
        guard plan.route == .passThrough, intent.isLossy || jpeg2000Options != nil else { return plan }
        return DicomTranscodePlan(
            source: plan.source, destination: plan.destination, route: .recompress, status: .ambiguous,
            diagnostics: [.init(severity: .info,
                                message: jpeg2000Options == nil
                                    ? "Explicit quality requires recompression despite an unchanged transfer syntax UID."
                                    : "Explicit JPEG 2000 packet configuration requires re-encoding despite an unchanged transfer syntax UID.")]
        )
    }

    func validateDecompressionDestination(source: DicomTransferSyntax, destination: DicomTransferSyntax) throws {
        guard [.explicitVRLittleEndian, .implicitVRLittleEndian, .deflatedExplicitVRLittleEndian].contains(destination) else {
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue, destinationUID: destination.rawValue,
                diagnostics: ["Decompression targets the native little-endian syntaxes (Explicit, Implicit or Deflated Explicit VR)."]
            )
        }
    }

    private func validateJPEGXLRollout(
        source: DicomTransferSyntax,
        destination: DicomTransferSyntax,
        environment: [String: String],
        operation: String
    ) throws {
        guard DicomJXLSwiftRolloutMode(environment: environment) != .disabled else {
            throw TranscodeError.routeUnsupported(
                sourceUID: source.rawValue, destinationUID: destination.rawValue,
                diagnostics: ["Experimental JPEG XL \(operation) requires DICOM_JXLSWIFT_MODE=experimental."]
            )
        }
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
}
