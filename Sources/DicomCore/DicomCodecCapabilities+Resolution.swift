import Foundation

extension DicomCodecCapabilities {
    /// Storage needs a recognized syntax, not image metadata; zero fields explicitly mean no pixel profile was queried.
    public static func preservationDecision(for transferSyntaxUID: String) -> DicomCodecDecision {
        resolve(.init(operation: .preserve, descriptor: DicomCompressedFrameDescriptor(
            transferSyntaxUID: transferSyntaxUID, rows: 0, columns: 0, bitsAllocated: 0, bitsStored: 0,
            highBit: 0, pixelRepresentation: 0, samplesPerPixel: 0,
            photometricInterpretation: "", planarConfiguration: nil
        )), environment: [:])
    }

    /// Resolves an operation in the same environment used by the async frame reader and transcoder.
    /// Metadata qualification does not certify arbitrary compressed bytes as valid pixels.
    public static func resolve(
        _ request: DicomCodecCapabilityRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DicomCodecDecision {
        guard let syntax = DicomTransferSyntax(uid: request.descriptor.transferSyntaxUID) else {
            return rejected(request, .unknownSyntax, "No transfer syntax is registered for this UID.")
        }
        if request.operation == .preserve {
            return selected(request, backend: nativeCapability("dataset-passthrough", syntax: syntax))
        }
        if let reason = request.descriptor.validationReason() {
            return rejected(request, .invalidMetadata, reason)
        }
        guard let family = DicomCodecFamily.family(for: syntax) else {
            if syntax.registryEntry.pixelEncoding == .native, request.partialDecode == nil {
                if request.operation == .encode, request.intent.isLossy {
                    return rejected(request, .intentUnsupported, "Native pixel encoding does not accept lossy intent.")
                }
                return selected(request, backend: nativeCapability("native-uncompressed", syntax: syntax))
            }
            return rejected(request, .operationUnsupported, "This format has no local frame codec for this operation.")
        }
        if request.operation == .encode {
            return resolveEncoding(request, family: family, environment: environment)
        }
        if family == .jpegXL {
            let mode = DicomJXLSwiftRolloutMode(environment: environment)
            guard mode != .disabled else {
                return rejected(request, .profileForbidden, "The experimental JXLSwift rollout is disabled.")
            }
            return qualify(request, backend: DicomJXLSwiftBackend().capabilities,
                           qualification: mode == .forcedForTests ? .testOnly : .experimental)
        }
        if DicomJ2KPart2Profile.isPart2(request.descriptor.transferSyntaxUID) {
            return resolvePart2Decode(request, environment: environment)
        }
        if family == .jpeg2000 || family == .htj2k || family == .jpegLS {
            return resolveRolloutDecode(request, family: family, environment: environment)
        }
        if family == .jpeg {
            return resolveJPEGDecode(request, syntax: syntax, environment: environment)
        }
        return resolveLegacyDecode(request, syntax: syntax, environment: environment)
    }

    private static func resolveEncoding(
        _ request: DicomCodecCapabilityRequest,
        family: DicomCodecFamily,
        environment: [String: String]
    ) -> DicomCodecDecision {
        let backend: DicomFrameCodecCapabilities
        var qualification: DicomCodecDecision.Qualification = .qualified
        let isPart2 = DicomJ2KPart2Profile.isPart2(request.descriptor.transferSyntaxUID)
        switch family {
        case .jpeg2000, .htj2k:
            backend = DicomJ2KSwiftBackend().capabilities
            if isPart2 {
                // No independent Part 2 Annex J decoder is available locally, so the own encoder stays experimental.
                let mode = DicomJ2KSwiftRolloutMode(environment: environment)
                guard mode != .disabled else {
                    return rejected(request, .profileForbidden, "The own JPEG 2000 Part 2 codec is disabled (DICOM_J2KSWIFT_MODE=disabled).")
                }
                qualification = mode == .forcedForTests ? .testOnly : .experimental
            }
        case .jpegLS:
            backend = DicomJLSwiftBackend().capabilities
        case .jpegXL:
            let mode = DicomJXLSwiftRolloutMode(environment: environment)
            guard mode != .disabled else {
                return rejected(request, .profileForbidden, "The experimental JXLSwift rollout is disabled.")
            }
            backend = DicomJXLSwiftBackend().capabilities
            qualification = mode == .forcedForTests ? .testOnly : .experimental
        case .jpeg:
            backend = DicomJPEGSwiftBackend().capabilities
        case .rle:
            guard let rle = frameBackends(environment: environment).first(where: { $0.identifier.rawValue == "native-rle-lossless" }) else {
                return rejected(request, .operationUnsupported, "No pixel encoder is executable for this transfer syntax.")
            }
            backend = rle
        case .deflatedFrames:
            guard let deflated = frameBackends(environment: environment).first(where: { $0.identifier.rawValue == "native-deflated-frames" }) else {
                return rejected(request, .operationUnsupported, "No pixel encoder is executable for this transfer syntax.")
            }
            backend = deflated
        }
        let decision = qualify(request, backend: backend, qualification: qualification)
        guard decision.canExecute else { return decision }
        do {
            switch family {
            case .jpeg2000, .htj2k:
                if isPart2 {
                    guard request.descriptor.samplesPerPixel == 1 else {
                        return rejected(request, .unqualifiedProfile, "JPEG 2000 Part 2 codes the frames as components; only single-sample frames are supported.")
                    }
                    if request.intent.isLossy, request.descriptor.transferSyntaxUID == DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.rawValue {
                        return rejected(request, .intentUnsupported, "an irreversible request cannot use a lossless-only transfer syntax")
                    }
                } else {
                    try DicomJ2KSwiftBackend.validateEncoding(descriptor: request.descriptor,
                                                             targetTransferSyntaxUID: request.descriptor.transferSyntaxUID,
                                                             intent: request.intent)
                }
            case .jpegLS:
                _ = try DicomJLSwiftBackend.validateEncoding(descriptor: request.descriptor,
                                                           targetTransferSyntaxUID: request.descriptor.transferSyntaxUID,
                                                           intent: request.intent)
            case .jpegXL:
                _ = try DicomJXLSwiftBackend.validateEncoding(descriptor: request.descriptor,
                                                            targetTransferSyntaxUID: request.descriptor.transferSyntaxUID,
                                                            intent: request.intent)
            case .jpeg:
                _ = try DicomJPEGSwiftBackend.validateEncoding(descriptor: request.descriptor,
                                                              targetTransferSyntaxUID: request.descriptor.transferSyntaxUID,
                                                              intent: request.intent)
            case .rle:
                guard case .reversible = request.intent else {
                    throw DicomTranscoder.TranscodeError.routeUnsupported(sourceUID: "", destinationUID: request.descriptor.transferSyntaxUID,
                                                                          diagnostics: ["RLE Lossless is reversible; a lossy or NEAR intent has no meaning for it."])
                }
                let descriptor = request.descriptor
                guard [8, 16].contains(descriptor.bitsAllocated), [1, 3].contains(descriptor.samplesPerPixel),
                      descriptor.samplesPerPixel == 1 || descriptor.bitsAllocated == 8 else {
                    throw DicomTranscoder.TranscodeError.unsupportedPixelShape(
                        reason: "RLE Lossless encoding covers 8/16-bit single-sample and 8-bit three-sample frames")
                }
            case .deflatedFrames:
                guard case .reversible = request.intent else {
                    throw DicomTranscoder.TranscodeError.routeUnsupported(sourceUID: "", destinationUID: request.descriptor.transferSyntaxUID,
                                                                          diagnostics: ["Deflated Image Frame Compression is reversible; a lossy or NEAR intent has no meaning for it."])
                }
                let descriptor = request.descriptor
                guard DicomDeflatedFrameCodec.frameByteCount(rows: descriptor.rows, columns: descriptor.columns,
                                                             samplesPerPixel: descriptor.samplesPerPixel,
                                                             bitsAllocated: descriptor.bitsAllocated,
                                                             photometricInterpretation: descriptor.photometricInterpretation) != nil else {
                    throw DicomTranscoder.TranscodeError.unsupportedPixelShape(
                        reason: "Deflated Image Frame Compression needs byte-aligned frames (Rows × Columns × Samples per Pixel × Bits Allocated a multiple of 8)")
                }
            }
        } catch {
            return rejected(request, .intentUnsupported, error.localizedDescription)
        }
        return decision
    }

    /// Own JPEG backend first (preferred), the established native/ImageIO paths when it declines or when the
    /// rollout is disabled; partial (reduced) decode is served by the own backend only.
    private static func resolveJPEGDecode(
        _ request: DicomCodecCapabilityRequest,
        syntax: DicomTransferSyntax,
        environment: [String: String]
    ) -> DicomCodecDecision {
        let mode = DicomJPEGSwiftRolloutMode(environment: environment)
        let candidate = DicomJPEGSwiftBackend().capabilities
        if request.partialDecode != nil {
            guard mode != .disabled else { return rejected(request, .profileForbidden, "The own JPEG backend is disabled.") }
            return qualify(request, backend: candidate, qualification: mode == .forcedForTests ? .testOnly : .qualified)
        }
        switch mode {
        case .disabled:
            return resolveLegacyDecode(request, syntax: syntax, environment: environment)
        case .forcedForTests:
            return qualify(request, backend: candidate, qualification: .testOnly)
        case .preferred:
            if !request.allowsFallback, let requested = request.preferredBackend,
               requested != candidate.identifier.rawValue {
                return resolveLegacyDecode(request, syntax: syntax, environment: environment)
            }
            let preferred = qualify(request, backend: candidate)
            if preferred.canExecute, (try? DicomJPEGSwiftBackend.validateDescriptor(request.descriptor, operation: .decode)) != nil { return preferred }
            guard request.allowsFallback else { return preferred }
            let legacy = resolveLegacyDecode(request, syntax: syntax, environment: environment)
            return legacy.canExecute ? legacy : preferred
        case .shadow:
            let legacy = resolveLegacyDecode(request, syntax: syntax, environment: environment)
            return legacy.canExecute ? legacy : qualify(request, backend: candidate)
        }
    }

    /// JPEG 2000 Part 2 Multi-component (#2331): the own DicomJPEG2000 codec is the only local Annex J decoder
    /// (OpenJPEG rejects the T.801 SGcod value), so it is offered as experimental whenever the rollout is enabled;
    /// a collection whose transformation the codec cannot undo (wavelet-based/dependency) is refused typed.
    private static func resolvePart2Decode(
        _ request: DicomCodecCapabilityRequest,
        environment: [String: String]
    ) -> DicomCodecDecision {
        let mode = DicomJ2KSwiftRolloutMode(environment: environment)
        guard mode != .disabled else {
            return rejected(request, .profileForbidden, "The own JPEG 2000 Part 2 codec is disabled (DICOM_J2KSWIFT_MODE=disabled); no other Annex J decoder is available.")
        }
        guard request.partialDecode == nil else {
            return rejected(request, .partialUnsupported, "Annex J transformations reconstruct every component of a collection; partial decode is not offered.")
        }
        if let frameData = request.frameData, let inspection = try? DicomJ2KCodestreamInspector.inspect(frameData) {
            if let violation = DicomJ2KPart2Profile.violation(of: request.descriptor.transferSyntaxUID, in: inspection) {
                return rejected(request, .unqualifiedProfile, violation)
            }
            if let reason = DicomJ2KPart2Profile.unsupportedReason(inspection) {
                return rejected(request, .unqualifiedProfile, reason)
            }
        }
        return qualify(request, backend: DicomJ2KSwiftBackend().capabilities,
                       qualification: mode == .forcedForTests ? .testOnly : .experimental)
    }

    private static func resolveRolloutDecode(
        _ request: DicomCodecCapabilityRequest,
        family: DicomCodecFamily,
        environment: [String: String]
    ) -> DicomCodecDecision {
        let isJLS = family == .jpegLS
        let mode = isJLS ? DicomJLSwiftRolloutMode(environment: environment).rawValue
            : DicomJ2KSwiftRolloutMode(environment: environment).rawValue
        let candidate = isJLS ? DicomJLSwiftBackend().capabilities : DicomJ2KSwiftBackend().capabilities
        let established = isJLS ? DicomCharLSFrameBackend(environment: environment).capabilities
            : DicomOpenJPEGFrameBackend(environment: environment).capabilities
        if request.partialDecode != nil {
            guard mode != "disabled" else {
                return rejected(request, .profileForbidden, "The partial decoder rollout is disabled.")
            }
            return qualify(request, backend: candidate,
                           qualification: mode == "forced-for-tests" ? .testOnly : .qualified)
        }
        if mode == "forced-for-tests" {
            return qualify(request, backend: candidate, qualification: .testOnly)
        }
        if mode == "preferred" {
            if request.preferredBackend == established.identifier.rawValue {
                let preferred = qualify(request, backend: established)
                if preferred.canExecute || !request.allowsFallback { return preferred }
                return qualify(request, backend: candidate, fallbackReason: preferred.reason)
            }
            let preferred = qualify(request, backend: candidate)
            if preferred.canExecute { return preferred }
            guard request.allowsFallback else { return preferred }
            return qualify(request, backend: established, fallbackReason: preferred.reason)
        }
        let production = qualify(request, backend: established,
                                 shadow: mode == "shadow" && candidate.isAvailable
                                     ? candidate.identifier.rawValue : nil)
        if mode == "disabled", let syntax = DicomTransferSyntax(uid: request.descriptor.transferSyntaxUID) {
            let legacy = resolveLegacyDecode(request, syntax: syntax, environment: environment)
            return legacy.canExecute ? legacy : production
        }
        if production.canExecute { return production }
        guard !isJLS, family != .htj2k, let syntax = DicomTransferSyntax(uid: request.descriptor.transferSyntaxUID) else {
            return production
        }
        return resolveLegacyDecode(request, syntax: syntax, environment: environment)
    }

    private static func resolveLegacyDecode(
        _ request: DicomCodecCapabilityRequest,
        syntax: DicomTransferSyntax,
        environment: [String: String]
    ) -> DicomCodecDecision {
        let descriptor = request.descriptor
        let backends = frameBackends(environment: environment)
        if let identifier = request.preferredBackend,
           let backend = backends.first(where: { $0.identifier.rawValue == identifier }),
           ![DicomCodecBackendIdentifier.j2kSwiftCPU, .jlSwift, .jxlSwift, .jpegSwift].contains(backend.identifier) {
            let preferred = qualify(request, backend: backend)
            if preferred.canExecute || !request.allowsFallback { return preferred }
        }
        let resolved = DicomCompressedPixelBackendRegistry.resolve(
            transferSyntax: syntax, requestedBitDepth: descriptor.bitsAllocated,
            samplesPerPixel: descriptor.samplesPerPixel,
            photometricInterpretation: descriptor.photometricInterpretation,
            bitsStored: descriptor.bitsStored, environment: environment
        )
        let identifier: String
        switch resolved.backend {
        case .nativeJPEGLossless: identifier = "native-jpeg-lossless"
        case .nativeRLELossless: identifier = "native-rle-lossless"
        case .nativeDeflatedFrames: identifier = "native-deflated-frames"
        case .nativeJPEGExtended: identifier = "native-jpeg-extended"
        case .nativeJPEG: identifier = DicomCodecBackendIdentifier.jpegSwift.rawValue
        case .nativeJPEGLS: identifier = "charls-jpeg-ls"
        case .imageIOJPEGBaseline: identifier = "imageio-jpeg-baseline"
        case .imageIOJPEGExtended: identifier = "imageio-jpeg-extended"
        case .imageIOJPEG2000: identifier = "imageio-jpeg-2000"
        case .openJPEG2000: identifier = "openjpeg-jpeg-2000"
        case .openJPEGHTJ2K: identifier = "openjpeg-htj2k"
        case .unsupported, .legacyImageIO:
            return rejected(request, .unqualifiedProfile, resolved.diagnostics.joined(separator: " "))
        }
        guard let backend = backends.first(where: { $0.identifier.rawValue == identifier }) else {
            return rejected(request, .operationUnsupported, "The selected implementation has no registered capability.")
        }
        return qualify(request, backend: backend)
    }

    private static func qualify(
        _ request: DicomCodecCapabilityRequest,
        backend: DicomFrameCodecCapabilities,
        qualification: DicomCodecDecision.Qualification = .qualified,
        shadow: String? = nil,
        fallbackReason: String? = nil
    ) -> DicomCodecDecision {
        guard backend.isAvailable else {
            let incompatible = backend.version.flatMap(majorVersion).map { $0 != supportedMajorVersion } == true
                && backend.source != .packageLinked
            return rejected(request, incompatible ? .runtimeIncompatible : .runtimeUnavailable,
                            "Backend \(backend.identifier.rawValue) is unavailable or incompatible in this environment.")
        }
        if backend.identifier == .openJPEGCPU,
           let syntax = DicomTransferSyntax(uid: request.descriptor.transferSyntaxUID),
           DicomCodecFamily.family(for: syntax) == .htj2k,
           let reason = DicomJPEG2000Codec.htj2kUnsupportedReason(
               runtimeAvailable: true, runtimeMessage: "OpenJPEG is available.", version: backend.version
           ) {
            return rejected(request, .runtimeIncompatible, reason)
        }
        let reason = request.operation == .decode
            ? backend.unsupportedReason(for: request.decodeRequest)
            : backend.unsupportedReason(for: request.descriptor, operation: request.operation)
        if let reason {
            return rejected(request, request.partialDecode == nil ? .unqualifiedProfile : .partialUnsupported, reason)
        }
        do {
            switch backend.identifier {
            case .j2kSwiftCPU:
                try DicomJ2KSwiftBackend.validateFullFrameDecoding(request.descriptor)
            case .jlSwift:
                try DicomJLSwiftBackend.validateDescriptor(request.descriptor)
            case .jxlSwift:
                try DicomJXLSwiftBackend.validateDescriptor(request.descriptor)
            default:
                break
            }
        } catch {
            return rejected(request, .unqualifiedProfile, error.localizedDescription)
        }
        if let partial = request.partialDecode {
            guard let data = request.frameData else {
                return rejected(request, .codestreamRequired, "Partial decode requires the codestream's resolution and layer limits.")
            }
            do {
                let info = try DicomJ2KCodestreamInfo.parse(data)
                if (partial.resolutionLevel ?? 0) > info.decompositionLevels
                    || (partial.maximumQualityLayer ?? 0) >= info.qualityLayerCount {
                    return rejected(request, .partialUnsupported, "The requested resolution or layer exceeds the codestream limits.")
                }
            } catch {
                return rejected(request, .codestreamInvalid, error.localizedDescription)
            }
        }
        return selected(request, backend: backend, shadow: shadow, qualification: qualification,
                        fallbackReason: fallbackReason)
    }

    private static func nativeCapability(_ identifier: String, syntax: DicomTransferSyntax) -> DicomFrameCodecCapabilities {
        DicomFrameCodecCapabilities(identifier: .init(rawValue: identifier), families: [],
                                    transferSyntaxUIDs: [syntax.rawValue], supportedGrayscaleBitDepths: 1...16,
                                    executionClass: .cpu, source: .packageLinked)
    }

    private static func selected(
        _ request: DicomCodecCapabilityRequest,
        backend: DicomFrameCodecCapabilities,
        shadow: String? = nil,
        qualification: DicomCodecDecision.Qualification = .qualified,
        fallbackReason: String? = nil
    ) -> DicomCodecDecision {
        if let required = request.requiredExecutionClass, required != backend.executionClass {
            return rejected(request, .ownershipUnsupported, "The backend cannot execute on the requested processor.")
        }
        if let required = request.requiredOutputOwnership, required != backend.outputOwnership {
            return rejected(request, .ownershipUnsupported, "The backend cannot return the requested buffer ownership.")
        }
        if let preferred = request.preferredBackend, preferred != backend.identifier.rawValue, !request.allowsFallback {
            return rejected(request, .profileForbidden, "The requested backend is not enabled for this profile.")
        }
        return DicomCodecDecision(request: request, backend: backend, shadow: shadow,
                           qualification: qualification, fallbackReason: fallbackReason
                               ?? request.preferredBackend.flatMap {
                                   $0 == backend.identifier.rawValue ? nil : "The requested backend \($0) is unavailable for this profile."
                               })
    }

    private static func rejected(
        _ request: DicomCodecCapabilityRequest,
        _ code: DicomCodecDecision.ReasonCode,
        _ reason: String
    ) -> DicomCodecDecision {
        DicomCodecDecision(request: request, reasonCode: code, reason: reason)
    }
}
