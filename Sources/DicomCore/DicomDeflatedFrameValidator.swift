import DicomData
import Foundation

/// Composes PS3.5 Table 8.2.2-1 metadata with the actual Deflated Image Frame Compression fragment
/// (Section 8.2.16 / Annex A.4.9): one raw DEFLATE stream per frame whose inflated length is exactly the
/// native frame length, followed by at most one NULL pad byte. The codec places no restriction on the
/// pixel attributes, so the rules only check the Image Pixel module's own consistency.
public enum DicomDeflatedFrameValidator {
    public static var rules: [DicomAttributeRule] {
        [0x00280010, 0x00280011].map {
            .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...65535)])
        } + [
            .init(tag: 0x00280002, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...15)]),
            .init(tag: 0x00280004, requirement: .type1, constraints: [.valueCount(1...1)]),
            .init(tag: 0x00280006, requirement: .type1C, condition: .integerGreaterThan(0x00280002, 1),
                  constraints: [.valueCount(1...1), .integers([0, 1])]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.valueCount(1...1), .integers([1, 8, 16, 32, 64])]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...64), .integerLessThanOrEqualAttribute(0x00280100)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.valueCount(1...1), .integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.valueCount(1...1), .integers([0, 1])])
        ]
    }

    /// The caller supplies one assembled frame (the whole fragment) and its original zero-based index.
    public static func validate(_ dataSet: DicomDataSet, frame: Data?, frameIndex: Int = 0,
                                transferSyntax: DicomTransferSyntax = .deflatedImageFrameCompression,
                                maximumEncodedBytes: Int = 64 * 1024 * 1024,
                                attributeLimits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let location: [DicomValidationReport.PathComponent] = [.tag(0x7FE00010)] + (frameIndex >= 0 ? [.frame(frameIndex)] : [])
        guard transferSyntax == .deflatedImageFrameCompression else {
            return .init(diagnostics: [.init(code: .codestreamRuleUnavailable, severity: .limitation, layer: .codestream, path: location)])
        }
        var state = DicomCodestreamFrameState(dataSet: dataSet, frameIndex: frameIndex, attributeLimits: attributeLimits,
                                              diagnostics: DicomAttributeValidator.validate(dataSet, rules: rules, limits: attributeLimits).diagnostics)
        guard state.begin(frame: frame) else { return state.report }
        state.checkPhotometricCompanions(colorValues: ["RGB", "YBR_FULL", "YBR_FULL_422", "YBR_PARTIAL_420", "YBR_ICT", "YBR_RCT"],
                                         knownValues: ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL", "YBR_FULL_422",
                                                       "YBR_PARTIAL_420", "YBR_ICT", "YBR_RCT"])
        guard let frame, !state.stopped else { return state.report }
        guard let rows = state.number(0x00280010), let columns = state.number(0x00280011), let samples = state.number(0x00280002),
              let bits = state.number(0x00280100),
              let expected = DicomDeflatedFrameCodec.frameByteCount(rows: rows, columns: columns, samplesPerPixel: samples, bitsAllocated: bits,
                                                                   photometricInterpretation: state.string(0x00280004) ?? "") else {
            state.record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
            state.record(.valueUnavailable, .codestream, severity: .limitation)
            return state.report
        }
        guard frame.count <= maximumEncodedBytes else { state.stop(); return state.report }
        do {
            let actual = try DicomDeflatedFrameCodec.inspect(frame, expectedByteCount: expected)
            if actual.trailingByteCount > 1 { state.record(.invalidCodestream, .codestream) }
            if !actual.fragmentLengthIsEven { state.record(.codestreamSegmentPaddingMissing, .codestream) }
        } catch DicomDeflatedFrameError.lengthMismatch, DicomDeflatedFrameError.outputExceedsFrame {
            // The stream is well formed but does not carry the declared frame: metadata and payload disagree.
            state.record(.pixelMetadataContradiction, .pixelsAndGeometry)
            state.record(.invalidCodestream, .codestream)
        } catch {
            state.record(.invalidCodestream, .codestream)
            state.record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
        }
        return state.report
    }
}
