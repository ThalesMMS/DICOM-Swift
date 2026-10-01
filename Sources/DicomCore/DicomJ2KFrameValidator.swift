import DicomCodecs
import Foundation

/// PS3.5 8.2.4 and 8.2.14 pixel metadata composed with SIZ/COD/QCD/CAP evidence from one assembled JPEG 2000 or
/// HTJ2K codestream: dimensions, components, precision and sign, the multiple component transformation against the
/// Photometric Interpretation, reversible coding for the lossless syntaxes, HT capabilities and the .202 progressive
/// options (RPCL order, TLM marker segment, thumbnail resolution).
public enum DicomJ2KFrameValidator {
    public static func rules(for syntax: DicomTransferSyntax) -> [DicomAttributeRule] {
        guard let profile = Profile(syntax) else { return [] }
        var photos: Set<String> = ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "YBR_RCT", "RGB", "YBR_FULL"]
        if !profile.losslessOnly { photos.insert("YBR_ICT") }
        return [0x00280010, 0x00280011].map {
            .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...65535)])
        } + [
            .init(tag: 0x00280002, requirement: .type1, constraints: [.valueCount(1...1), .integers([1, 3])]),
            .init(tag: 0x00280004, requirement: .type1, constraints: [.valueCount(1...1), .strings(photos)]),
            .init(tag: 0x00280006, requirement: .type1C, condition: .integerGreaterThan(0x00280002, 1), constraints: [.valueCount(1...1), .integers([0])]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.valueCount(1...1), .integers(profile.highThroughput ? [8, 16, 24, 32, 40] : [1, 8, 16, 24, 32, 40])]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...38), .integerLessThanOrEqualAttribute(0x00280100)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.valueCount(1...1), .integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.valueCount(1...1), .integers([0, 1])])
        ]
    }

    /// Header evidence never promotes packet validity, ICC matching or an entire IOD to passed.
    public static func validate(_ dataSet: DicomDataSet, frame: Data?, transferSyntax: DicomTransferSyntax, frameIndex: Int = 0,
                                maximumEncodedBytes: Int = 64 * 1024 * 1024, attributeLimits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let location: [DicomValidationReport.PathComponent] = [.tag(0x7FE00010)] + (frameIndex >= 0 ? [.frame(frameIndex)] : [])
        guard let profile = Profile(transferSyntax) else {
            return .init(diagnostics: [.init(code: .codestreamRuleUnavailable, severity: .limitation, layer: .codestream, path: location)])
        }
        var state = DicomCodestreamFrameState(dataSet: dataSet, frameIndex: frameIndex, attributeLimits: attributeLimits,
                                              diagnostics: DicomAttributeValidator.validate(dataSet, rules: rules(for: transferSyntax), limits: attributeLimits).diagnostics)
        guard state.begin(frame: frame) else { return state.report }
        let transformed: Set<String> = ["YBR_RCT", "YBR_ICT"]
        state.checkPhotometricCompanions(colorValues: ["RGB", "YBR_FULL", "YBR_RCT", "YBR_ICT"],
                                         knownValues: ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL", "YBR_RCT", "YBR_ICT"])
        guard let frame, !state.stopped else { return state.report }
        do {
            let actual = try DicomJ2KCodestreamInspector.inspect(frame, maximumEncodedBytes: maximumEncodedBytes)
            if !actual.hasEndOfCodestream { state.record(.invalidCodestream, .codestream) }
            // PS3.5 A.4.4: the frame shall carry the raw codestream; a JP2/JPX/JPH wrapper is a profile violation.
            if actual.container != nil { state.record(.codestreamProfileMismatch, .codestream) }
            // Part 15 codestreams belong to the HTJ2K syntaxes; Part 1 codestreams to the JPEG 2000 syntaxes.
            if actual.isHighThroughput != profile.highThroughput { state.record(.codestreamProfileMismatch, .codestream) }
            // ISO/IEC 15444-2: only the .92/.93 syntaxes carry Part 2 extensions, and only the Annex J transformation (8.2.4).
            if profile.part2 {
                if DicomJ2KPart2Profile.violation(of: transferSyntax.rawValue, in: actual) != nil { state.record(.codestreamProfileMismatch, .codestream) }
                if DicomJ2KPart2Profile.unsupportedReason(actual) != nil { state.record(.codestreamRuleUnavailable, .codestream, severity: .limitation) }
            } else if actual.usesPart2Extensions || actual.annexJ != nil {
                state.record(.codestreamProfileMismatch, .codestream)
            }
            // Lossless-only syntaxes carry the reversible 5-3 filter without quantization; RPCL is fixed by .202.
            if profile.losslessOnly, !actual.isLosslessCoding { state.record(.codestreamProfileMismatch, .codestream) }
            if profile.requiresRPCL, actual.progressionOrder != 2 { state.record(.codestreamProfileMismatch, .codestream) }
            // PS3.5 10.18.1: .202 also carries a TLM marker segment and enough decompositions for a <= 64-sample thumbnail.
            if profile.requiresRPCL, !actual.hasTileLengthMarkers { state.record(.codestreamProfileMismatch, .codestream) }
            if profile.requiresRPCL,
               !DicomHTJ2KProfile.hasThumbnailResolution(width: actual.width, height: actual.height, decompositionLevels: actual.decompositionLevels) {
                state.record(.codestreamProfileMismatch, .codestream)
            }
            // A Part 2 collection's components are frames, not samples per pixel; its reconstructed depths come from CBD.
            let reconstructed = profile.part2 ? (actual.annexJ?.outputComponents ?? actual.components) : actual.components
            state.compare([(0x00280010, actual.height), (0x00280011, actual.width), (0x00280002, profile.part2 ? 1 : actual.components.count)])
            if let first = reconstructed.first {
                state.compareBitsStored(first.precision)
                if reconstructed.contains(where: { $0.precision != first.precision || $0.isSigned != first.isSigned }) {
                    state.record(.codestreamRuleUnavailable, .codestream, severity: .limitation)
                }
                if let signed = state.number(0x00280103), (signed == 1) != first.isSigned { state.record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280103) }
            }
            if let photo = state.string(0x00280004) {
                // 8.2.4: SGcod MCT 1 requires YBR_RCT (reversible) or YBR_ICT (irreversible); MCT 0 forbids both.
                let expected = actual.usesMultipleComponentTransform ? (actual.usesReversibleTransform ? "YBR_RCT" : "YBR_ICT") : nil
                if let expected, photo != expected { state.record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280004) }
                if expected == nil, transformed.contains(photo) { state.record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280004) }
            }
            if actual.components.count > 1, !profile.part2 { state.record(.codestreamColorProfileUnavailable, .pixelsAndGeometry, severity: .limitation) }
            // Main-header evidence does not establish the correctness of the tile-parts and packets.
            state.record(.codestreamPayloadUnverified, .codestream, severity: .limitation)
        } catch DicomJ2KCodestreamInspector.Failure.limitExceeded {
            state.stop()
        } catch {
            state.record(.invalidCodestream, .codestream)
            state.record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
        }
        return state.report
    }

    struct Profile {
        let losslessOnly: Bool
        let highThroughput: Bool
        let requiresRPCL: Bool
        /// JPEG 2000 Part 2 Multi-component (#2331): the frame is a component collection (every component a frame).
        let part2: Bool

        init?(_ syntax: DicomTransferSyntax) {
            switch syntax {
            case .jpeg2000Lossless: self.init(losslessOnly: true, highThroughput: false, requiresRPCL: false)
            case .jpeg2000: self.init(losslessOnly: false, highThroughput: false, requiresRPCL: false)
            case .htj2kLossless: self.init(losslessOnly: true, highThroughput: true, requiresRPCL: false)
            case .htj2kLosslessRPCL: self.init(losslessOnly: true, highThroughput: true, requiresRPCL: true)
            case .htj2k: self.init(losslessOnly: false, highThroughput: true, requiresRPCL: false)
            case .jpeg2000Part2MulticomponentLossless: self.init(losslessOnly: true, highThroughput: false, requiresRPCL: false, part2: true)
            case .jpeg2000Part2Multicomponent: self.init(losslessOnly: false, highThroughput: false, requiresRPCL: false, part2: true)
            default: return nil
            }
        }

        private init(losslessOnly: Bool, highThroughput: Bool, requiresRPCL: Bool, part2: Bool = false) {
            self.losslessOnly = losslessOnly; self.highThroughput = highThroughput; self.requiresRPCL = requiresRPCL; self.part2 = part2
        }
    }

    public static let supported: Set<DicomTransferSyntax> = [.jpeg2000Lossless, .jpeg2000, .htj2kLossless, .htj2kLosslessRPCL, .htj2k,
                                                             .jpeg2000Part2MulticomponentLossless, .jpeg2000Part2Multicomponent]
}
