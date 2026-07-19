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
    case nativeJPEGLS
    case nativeJPEGExtended
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
        bitsStored: Int? = nil
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
                if samplesPerPixel == 3, photometric == "RGB", let storedBits, storedBits <= 8 {
                    return selected(.nativeJPEGLossless)
                }
                return unsupported(
                    "\(transferSyntax.registryEntry.name) (transfer syntax \(transferSyntax.rawValue)) multi-component"
                        + " decode supports 8-bit interleaved RGB only; "
                        + "\(storedBits.map { "\($0)-bit" } ?? "unknown-depth")"
                        + " output for \(componentContext) has no unambiguous mapping."
                )
            }
            return selected(.nativeJPEGLossless)
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
            if DicomJPEG2000Codec.isAvailable {
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
                "\(transferSyntax.registryEntry.name) stores frames as a multi-component volume "
                    + "(\(componentContext)); use DicomJP3DVolumeDocument to decode the volume buffer."
            )
        case .jpipReferenced, .jpipReferencedDeflate:
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
            if let reason = DicomJPEG2000Codec.htj2kUnsupportedReason() {
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
            capability(
                id: "native-rle-lossless",
                families: [.rle],
                syntaxes: [.rleLossless],
                grayscale: 1...16,
                color: 1...16,
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
        DicomFrameCodecCapabilities(
            identifier: id,
            families: [family],
            transferSyntaxUIDs: Set(syntaxes?.map(\.rawValue) ?? runtime?.transferSyntaxUIDs ?? []),
            supportedGrayscaleBitDepths: runtime?.supportedGrayscaleBitDepths ?? 1...16,
            supportedColorBitDepths: runtime?.supportedColorBitDepths ?? 1...8,
            executionClass: .cpu,
            source: runtime?.source ?? .unavailable,
            version: runtime?.version,
            isAvailable: runtime?.isAvailable ?? false,
            unsupportedReason: runtime?.unsupportedReason ?? "Codec runtime capability is unavailable."
        )
    }

    private static func capability(
        id: DicomCodecBackendIdentifier,
        families: Set<DicomCodecFamily>,
        syntaxes: [DicomTransferSyntax],
        grayscale: ClosedRange<Int>,
        color: ClosedRange<Int> = 1...8,
        maximumComponents: Int = 3,
        source: DicomCodecBackendSource
    ) -> DicomFrameCodecCapabilities {
        DicomFrameCodecCapabilities(
            identifier: id,
            families: families,
            transferSyntaxUIDs: Set(syntaxes.map(\.rawValue)),
            supportedGrayscaleBitDepths: grayscale,
            supportedColorBitDepths: color,
            maximumComponents: maximumComponents,
            executionClass: .cpu,
            source: source
        )
    }
}
