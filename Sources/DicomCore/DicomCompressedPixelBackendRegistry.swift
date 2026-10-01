//
//  DicomCompressedPixelBackendRegistry.swift
//  DicomCore
//
//  Compatibility policy for the compressed-frame implementations that ship
//  today. The legacy pixel reader asks this registry for a decision; future
//  package adapters use DicomFrameCodecRegistry directly.
//

import Foundation

internal enum DicomCompressedPixelBackend: Equatable {
    case nativeJPEGLossless
    case nativeRLELossless
    case nativeDeflatedFrames
    case nativeJPEGLS
    case nativeJPEGExtended
    case nativeJPEG
    case imageIOJPEGBaseline
    case imageIOJPEGExtended
    case imageIOJPEG2000
    case openJPEG2000
    case openJPEGHTJ2K
    case legacyImageIO
    case unsupported
}

internal struct DicomCompressedPixelBackendDecision: Equatable {
    let backend: DicomCompressedPixelBackend
    let diagnostics: [String]
}

internal enum DicomCompressedPixelBackendRegistry {
    static func resolve(
        transferSyntax: DicomTransferSyntax?,
        requestedBitDepth: Int?,
        samplesPerPixel: Int?,
        photometricInterpretation: String? = nil,
        bitsStored: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DicomCompressedPixelBackendDecision {
        guard let transferSyntax else {
            return selected(.legacyImageIO)
        }

        let componentContext = multiComponentContext(
            photometricInterpretation: photometricInterpretation,
            samplesPerPixel: samplesPerPixel
        )

        switch transferSyntax {
        case .rleLossless:
            return selected(.nativeRLELossless)
        case .deflatedImageFrameCompression:
            return selected(.nativeDeflatedFrames)
        case .jpegLSLossless, .jpegLSNearLossless:
            if let samplesPerPixel, samplesPerPixel > 1, let requestedBitDepth, requestedBitDepth > 8 {
                return unsupported(
                    "JPEG-LS multi-component output above 8 bits per component is unsupported (\(componentContext))."
                )
            }
            return selected(.nativeJPEGLS)
        case .jpegLossless, .jpegLosslessFirstOrder:
            if let samplesPerPixel, samplesPerPixel > 1 {
                let storedBits = bitsStored ?? requestedBitDepth
                let photometric = photometricInterpretation?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Lossless JPEG keeps the components as coded: YBR_FULL(_422) samples come out as stored and the
                // caller converts them (issue #2821).
                if samplesPerPixel == 3, ["RGB", "YBR_FULL", "YBR_FULL_422"].contains(photometric ?? ""),
                   let storedBits, storedBits <= 8 {
                    return selected(.nativeJPEGLossless)
                }
                return unsupported(
                    "\(transferSyntax.registryEntry.name) (transfer syntax \(transferSyntax.rawValue)) multi-component"
                        + " decode supports 8-bit RGB, YBR_FULL and YBR_FULL_422 only; "
                        + "\(storedBits.map { "\($0)-bit" } ?? "unknown-depth")"
                        + " output for \(componentContext) has no unambiguous mapping."
                )
            }
            return selected(.nativeJPEGLossless)
        case .jpegBaseline, .jpegExtended:
            if DicomJPEGSwiftRolloutMode(environment: environment) != .disabled,
               Self.ownJPEGHandles(bitsStored: bitsStored ?? requestedBitDepth, requestedBitDepth: requestedBitDepth,
                                   samplesPerPixel: samplesPerPixel, photometricInterpretation: photometricInterpretation,
                                   syntax: transferSyntax) {
                return selected(.nativeJPEG)
            }
            return legacyJPEGDecision(transferSyntax, requestedBitDepth: requestedBitDepth, samplesPerPixel: samplesPerPixel,
                                      bitsStored: bitsStored, componentContext: componentContext)
        case .jpeg2000Lossless, .jpeg2000:
            if let requestedBitDepth, requestedBitDepth > 16 {
                return unsupported(
                    "JPEG 2000 \(requestedBitDepth)-bit output exceeds the supported 16-bit grayscale backend path."
                )
            }
            if let samplesPerPixel, samplesPerPixel > 1, let requestedBitDepth, requestedBitDepth > 8 {
                return unsupported(
                    "JPEG 2000 color output above 8 bits per component has no precision-preserving backend path "
                        + "(\(componentContext))."
                )
            }
            if DicomCodecCapabilities.capability(for: .openJPEG, environment: environment).isAvailable {
                return selected(.openJPEG2000)
            }
            if let requestedBitDepth, requestedBitDepth > 8 {
                return unsupported(
                    "JPEG 2000 >8-bit output requires the OpenJPEG runtime library; refusing ImageIO fallback."
                )
            }
            return selected(.imageIOJPEG2000)
        case .jpeg2000Part2MulticomponentLossless, .jpeg2000Part2Multicomponent:
            return unsupported(
                "\(transferSyntax.registryEntry.name) codes frames as the components of Annex J collections "
                    + "(\(componentContext)); the synchronous frame path has no collection decoder — use DicomDecodedFrameReader "
                    + "(experimental own DicomJPEG2000 collection codec)."
            )
        case .jpipReferenced, .jpipReferencedDeflate,
             .jpipHTJ2KReferenced, .jpipHTJ2KReferencedDeflate:
            return unsupported(
                "\(transferSyntax.registryEntry.name) references remote pixel data; "
                    + "use DicomJPIPClient to stream progressive updates."
            )
        case .mpeg2MainProfileMainLevel,
             .mpeg2MainProfileMainLevelFragmentable,
             .mpeg2MainProfileHighLevel,
             .mpeg2MainProfileHighLevelFragmentable,
             .mpeg4AVCH264HighProfileLevel41,
             .mpeg4AVCH264HighProfileLevel41Fragmentable,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable,
             .mpeg4AVCH264HighProfileLevel42For2DVideo,
             .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
             .mpeg4AVCH264HighProfileLevel42For3DVideo,
             .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable,
             .mpeg4AVCH264StereoHighProfileLevel42,
             .mpeg4AVCH264StereoHighProfileLevel42Fragmentable,
             .hevcH265MainProfileLevel51,
             .hevcH265Main10ProfileLevel51:
            return unsupported(
                "\(transferSyntax.registryEntry.name) stores an encoded video stream; "
                    + "use DicomVideo to forward it to a video player."
            )
        case .htj2kLossless, .htj2kLosslessRPCL, .htj2k:
            let runtime = DicomCodecCapabilities.capability(for: .openJPEG, environment: environment)
            if let reason = DicomJPEG2000Codec.htj2kUnsupportedReason(
                runtimeAvailable: runtime.isAvailable,
                runtimeMessage: runtime.unsupportedReason ?? "OpenJPEG is available.", version: runtime.version
            ) {
                return unsupported(
                    "\(transferSyntax.registryEntry.name) (transfer syntax \(transferSyntax.rawValue)) \(reason)"
                        + " ImageIO JPEG 2000 fallback is not used for HTJ2K."
                )
            }
            if let requestedBitDepth, requestedBitDepth > 16 {
                return unsupported(
                    "HTJ2K \(requestedBitDepth)-bit output exceeds the supported 16-bit grayscale backend path."
                )
            }
            if let samplesPerPixel, samplesPerPixel > 1, let requestedBitDepth, requestedBitDepth > 8 {
                return unsupported(
                    "HTJ2K color output above 8 bits per component has no precision-preserving backend path "
                        + "(\(componentContext))."
                )
            }
            return selected(.openJPEGHTJ2K)
        case .jpegXLLossless, .jpegXLJPEGRecompression, .jpegXL:
            return unsupported(
                "\(transferSyntax.registryEntry.name) is available only through the feature-gated "
                    + "async JXLSwift frame reader (DICOM_JXLSWIFT_MODE=experimental)."
            )
        case .implicitVRLittleEndian, .explicitVRLittleEndian, .deflatedExplicitVRLittleEndian,
             .explicitVRBigEndian:
            return unsupported("Transfer syntax \(transferSyntax.rawValue) is not compressed.")
        }
    }

    static func capabilities(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [DicomFrameCodecCapabilities] {
        let runtimeCapabilities = Dictionary(
            uniqueKeysWithValues: DicomCodecCapabilities.all(environment: environment).map { ($0.runtime, $0) }
        )
        let openJPEG = runtimeCapabilities[.openJPEG]
        return [
            DicomJ2KSwiftBackend().capabilities,
            DicomJLSwiftBackend().capabilities,
            DicomJXLSwiftBackend().capabilities,
            DicomJPEGSwiftBackend().capabilities,
            capability(
                id: "native-rle-lossless",
                families: [.rle],
                syntaxes: [.rleLossless],
                encodeSyntaxes: [.rleLossless],
                grayscale: 1...16,
                color: 1...16,
                source: .packageLinked
            ),
            capability(
                id: "native-deflated-frames",
                families: [.deflatedFrames],
                syntaxes: [.deflatedImageFrameCompression],
                encodeSyntaxes: [.deflatedImageFrameCompression],
                grayscale: 1...32,
                color: 1...32,
                source: .packageLinked
            ),
            capability(
                id: "native-jpeg-lossless",
                families: [.jpeg],
                syntaxes: [.jpegLossless, .jpegLosslessFirstOrder],
                grayscale: 1...16,
                source: .packageLinked
            ),
            capability(
                id: "native-jpeg-extended",
                families: [.jpeg],
                syntaxes: [.jpegExtended],
                grayscale: 9...12,
                maximumComponents: 1,
                source: .packageLinked
            ),
            DicomCharLSFrameBackend(environment: environment).capabilities,
            capability(
                id: "imageio-jpeg-baseline",
                families: [.jpeg],
                syntaxes: [.jpegBaseline],
                grayscale: 1...8,
                source: .systemFramework
            ),
            capability(
                id: "imageio-jpeg-extended",
                families: [.jpeg],
                syntaxes: [.jpegExtended],
                grayscale: 1...8,
                source: .systemFramework
            ),
            capability(
                id: "imageio-jpeg-2000",
                families: [.jpeg2000],
                syntaxes: [.jpeg2000Lossless, .jpeg2000],
                grayscale: 1...8,
                source: .systemFramework
            ),
            runtimeCapability(
                id: "openjpeg-jpeg-2000",
                family: .jpeg2000,
                runtime: openJPEG,
                syntaxes: [.jpeg2000Lossless, .jpeg2000]
            ),
            runtimeCapability(
                id: "openjpeg-htj2k",
                family: .htj2k,
                runtime: openJPEG,
                syntaxes: [.htj2kLossless, .htj2kLosslessRPCL, .htj2k]
            )
        ]
    }

    private static func selected(_ backend: DicomCompressedPixelBackend) -> DicomCompressedPixelBackendDecision {
        DicomCompressedPixelBackendDecision(backend: backend, diagnostics: [])
    }

    private static func unsupported(_ diagnostic: String) -> DicomCompressedPixelBackendDecision {
        DicomCompressedPixelBackendDecision(backend: .unsupported, diagnostics: [diagnostic])
    }

    private static func multiComponentContext(
        photometricInterpretation: String?,
        samplesPerPixel: Int?
    ) -> String {
        let photometric = photometricInterpretation?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let photometricValue: String
        if let photometric, !photometric.isEmpty {
            photometricValue = photometric
        } else {
            photometricValue = "unknown"
        }
        let samplesValue = samplesPerPixel.map(String.init) ?? "unknown"
        return "Photometric Interpretation=\(photometricValue), Samples Per Pixel=\(samplesValue)"
    }

    private static func runtimeCapability(
        id: DicomCodecBackendIdentifier,
        family: DicomCodecFamily,
        runtime: DicomCodecCapability?,
        syntaxes: [DicomTransferSyntax]? = nil
    ) -> DicomFrameCodecCapabilities {
        let htj2kReason = family == .htj2k ? DicomJPEG2000Codec.htj2kUnsupportedReason(
            runtimeAvailable: runtime?.isAvailable ?? false,
            runtimeMessage: runtime?.unsupportedReason ?? "OpenJPEG is unavailable.", version: runtime?.version
        ) : nil
        return DicomFrameCodecCapabilities(
            identifier: id,
            families: [family],
            transferSyntaxUIDs: Set(syntaxes?.map(\.rawValue) ?? runtime?.transferSyntaxUIDs ?? []),
            supportedGrayscaleBitDepths: runtime?.supportedGrayscaleBitDepths ?? 1...16,
            supportedColorBitDepths: runtime?.supportedColorBitDepths ?? 1...8,
            executionClass: .cpu,
            source: runtime?.source ?? .unavailable,
            version: runtime?.version,
            isAvailable: (runtime?.isAvailable ?? false) && htj2kReason == nil,
            unsupportedReason: htj2kReason ?? runtime?.unsupportedReason
        )
    }

    /// Shapes the own JPEG backend decodes for the legacy pixel reader: 8-bit grayscale and YBR colour for
    /// Baseline, 8/12-bit grayscale and 8-bit YBR colour for Extended.
    static func ownJPEGHandles(bitsStored: Int?, requestedBitDepth: Int?, samplesPerPixel: Int?,
                               photometricInterpretation: String?, syntax: DicomTransferSyntax) -> Bool {
        let stored = bitsStored ?? 8
        let samples = samplesPerPixel ?? 1
        let photometric = photometricInterpretation?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? "MONOCHROME2"
        if samples == 3 {
            return stored == 8 && (requestedBitDepth ?? 8) == 8 && ["YBR_FULL", "YBR_FULL_422"].contains(photometric)
        }
        guard samples == 1, ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR"].contains(photometric) else { return false }
        if syntax == .jpegBaseline { return stored == 8 && (requestedBitDepth ?? 8) == 8 }
        return stored == 8 ? (requestedBitDepth ?? 8) == 8 : stored == 12 && (requestedBitDepth ?? 16) == 16
    }

    /// The pre-#2326 Baseline/Extended decision (native 12-bit decoder, ImageIO otherwise).
    private static func legacyJPEGDecision(_ transferSyntax: DicomTransferSyntax, requestedBitDepth: Int?, samplesPerPixel: Int?,
                                           bitsStored: Int?, componentContext: String) -> DicomCompressedPixelBackendDecision {
        switch transferSyntax {
        case .jpegBaseline:
            if let requestedBitDepth, requestedBitDepth > 8 {
                return unsupported(
                    "JPEG Baseline (Process 1) is limited to 8-bit output; refusing "
                        + "\(requestedBitDepth)-bit decode to avoid precision loss."
                )
            }
            return selected(.imageIOJPEGBaseline)
        case .jpegExtended:
            guard let storedBits = bitsStored ?? requestedBitDepth else {
                return unsupported(
                    "JPEG Extended (Process 2 and 4) decode requires DICOM bit-depth metadata "
                        + "before selecting a backend."
                )
            }
            if storedBits > 12 {
                return unsupported(
                    "JPEG Extended (Process 2 and 4, transfer syntax \(transferSyntax.rawValue)) caps sample"
                        + " precision at 12 bits; \(storedBits)-bit output is not representable"
                        + " (\(componentContext))."
                )
            }
            if storedBits > 8 {
                if let samplesPerPixel, samplesPerPixel > 1 {
                    return unsupported(
                        "JPEG Extended (Process 2 and 4, transfer syntax \(transferSyntax.rawValue))"
                            + " \(storedBits)-bit decode supports single-component grayscale only;"
                            + " no precision-preserving backend exists for \(componentContext)."
                    )
                }
                return selected(.nativeJPEGExtended)
            }
            return selected(.imageIOJPEGExtended)
        default:
            return selected(.legacyImageIO)
        }
    }

    private static func capability(
        id: DicomCodecBackendIdentifier,
        families: Set<DicomCodecFamily>,
        syntaxes: [DicomTransferSyntax],
        encodeSyntaxes: [DicomTransferSyntax] = [],
        grayscale: ClosedRange<Int>,
        color: ClosedRange<Int> = 1...8,
        maximumComponents: Int = 3,
        source: DicomCodecBackendSource
    ) -> DicomFrameCodecCapabilities {
        DicomFrameCodecCapabilities(
            identifier: id,
            families: families,
            transferSyntaxUIDs: Set(syntaxes.map(\.rawValue)),
            encodeTransferSyntaxUIDs: Set(encodeSyntaxes.map(\.rawValue)),
            operations: encodeSyntaxes.isEmpty ? [.decode] : [.decode, .encode],
            supportedGrayscaleBitDepths: grayscale,
            supportedColorBitDepths: color,
            maximumComponents: maximumComponents,
            executionClass: .cpu,
            source: source
        )
    }
}
