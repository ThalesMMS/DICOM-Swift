import DicomCodecs
import Foundation

/// PS3.5 8.2.3 pixel metadata composed with SOF55/LSE/SOS evidence from one assembled JPEG-LS frame.
public enum DicomJPEGLSFrameValidator {
    public static func rules(for syntax: DicomTransferSyntax) -> [DicomAttributeRule] {
        guard supported.contains(syntax) else { return [] }
        let photos: Set<String> = syntax == .jpegLSLossless ? ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL"]
            : ["MONOCHROME1", "MONOCHROME2", "RGB", "YBR_FULL"]
        return [0x00280010, 0x00280011].map {
            .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...65535)])
        } + [
            .init(tag: 0x00280002, requirement: .type1, constraints: [.valueCount(1...1), .integers([1, 3])]),
            .init(tag: 0x00280004, requirement: .type1, constraints: [.valueCount(1...1), .strings(photos)]),
            .init(tag: 0x00280006, requirement: .type1C, condition: .integerGreaterThan(0x00280002, 1), constraints: [.valueCount(1...1), .integers([0])]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.valueCount(1...1), .integers([8, 16])]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(2...16), .integerLessThanOrEqualAttribute(0x00280100)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.valueCount(1...1), .integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.valueCount(1...1), .integers([0, 1])])
        ]
    }

    /// Header evidence never promotes entropy validity, ICC matching or an entire IOD to passed.
    public static func validate(_ dataSet: DicomDataSet, frame: Data?, transferSyntax: DicomTransferSyntax, frameIndex: Int = 0,
                                maximumEncodedBytes: Int = 64 * 1024 * 1024, attributeLimits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let location: [DicomValidationReport.PathComponent] = [.tag(0x7FE00010)] + (frameIndex >= 0 ? [.frame(frameIndex)] : [])
        guard supported.contains(transferSyntax) else {
            return .init(diagnostics: [.init(code: .codestreamRuleUnavailable, severity: .limitation, layer: .codestream, path: location)])
        }
        var state = DicomCodestreamFrameState(dataSet: dataSet, frameIndex: frameIndex, attributeLimits: attributeLimits,
                                              diagnostics: DicomAttributeValidator.validate(dataSet, rules: rules(for: transferSyntax), limits: attributeLimits).diagnostics)
        guard state.begin(frame: frame) else { return state.report }
        state.checkPhotometricCompanions(colorValues: ["RGB", "YBR_FULL"], knownValues: ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL"])
        guard let frame, !state.stopped else { return state.report }
        do {
            let actual = try DicomJPEGLSFrameInspector.inspect(frame, maximumEncodedBytes: maximumEncodedBytes)
            // 8.2.3: the lossless syntax carries NEAR 0 in every scan; near-lossless permits either.
            if transferSyntax == .jpegLSLossless, !actual.isLossless { state.record(.codestreamProfileMismatch, .codestream) }
            state.compare([(0x00280010, actual.height), (0x00280011, actual.width), (0x00280002, actual.components.count)])
            state.compareBitsStored(actual.precision)
            if actual.components.count > 1 { state.record(.codestreamColorProfileUnavailable, .pixelsAndGeometry, severity: .limitation) }
            // SOF55/SOS evidence does not establish the correctness of the entropy-coded segments.
            state.record(.codestreamPayloadUnverified, .codestream, severity: .limitation)
        } catch DicomJPEGLSFrameInspector.Failure.limitExceeded {
            state.stop()
        } catch DicomJPEGLSFrameInspector.Failure.unsupportedProcess {
            state.record(.codestreamRuleUnavailable, .codestream, severity: .limitation)
            state.record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
        } catch {
            state.record(.invalidCodestream, .codestream)
            state.record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
        }
        return state.report
    }

    private static let supported: Set<DicomTransferSyntax> = [.jpegLSLossless, .jpegLSNearLossless]
}

/// Bookkeeping shared by the per-frame codestream validators: diagnostic budget, frame scope and the
/// metadata cross-checks every encapsulated syntax performs.
struct DicomCodestreamFrameState {
    let dataSet: DicomDataSet
    let frameIndex: Int
    let attributeLimits: DicomAttributeValidator.Limits
    var diagnostics: [DicomValidationReport.Diagnostic]
    private(set) var stopped = false
    static let evaluated: Set<DicomValidationReport.Layer> = [.attributes, .pixelsAndGeometry, .codestream]

    init(dataSet: DicomDataSet, frameIndex: Int, attributeLimits: DicomAttributeValidator.Limits, diagnostics: [DicomValidationReport.Diagnostic]) {
        self.dataSet = dataSet; self.frameIndex = frameIndex; self.attributeLimits = attributeLimits; self.diagnostics = diagnostics
    }

    var report: DicomValidationReport { .init(evaluatedLayers: Self.evaluated, diagnostics: diagnostics) }
    private var location: [DicomValidationReport.PathComponent] { [.tag(0x7FE00010)] + (frameIndex >= 0 ? [.frame(frameIndex)] : []) }

    mutating func stop() {
        guard !stopped else { return }
        for layer in [DicomValidationReport.Layer.codestream, .pixelsAndGeometry] {
            diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: layer, path: location))
        }
        stopped = true
    }

    mutating func record(_ code: DicomValidationReport.Code, _ layer: DicomValidationReport.Layer, tag: Int = 0x7FE00010,
                         severity: DicomValidationReport.Severity = .error) {
        guard !stopped else { return }
        guard diagnostics.count < attributeLimits.maximumDiagnostics else { stop(); return }
        diagnostics.append(.init(code: code, severity: severity, layer: layer,
                                 path: [.tag(tag)] + (frameIndex >= 0 ? [.frame(frameIndex)] : []), requirement: .type1))
    }

    func number(_ tag: Int) -> Int? {
        guard let element = dataSet[tag], element.vr == .US, element.vm.count == 1, let value = element.intValue, (0...65535).contains(value) else { return nil }
        return value
    }

    func string(_ tag: Int) -> String? {
        guard let element = dataSet[tag], element.vr == .CS, case .strings(let values) = element.value, values.count == 1, values[0].utf8.count <= 16 else { return nil }
        return values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    /// Diagnostic-budget check, frame scope and the frame presence; false when nothing more can be evaluated.
    mutating func begin(frame: Data?) -> Bool {
        if diagnostics.contains(where: { $0.code == .evaluationLimitReached }) { stop() }
        guard !stopped else { return false }
        guard frameIndex >= 0 else {
            record(.referenceSelectionInvalid, .pixelsAndGeometry)
            record(.valueUnavailable, .codestream, severity: .limitation)
            return false
        }
        for tag in [0x00280100, 0x00280102, 0x00280103] where number(tag) == nil {
            record(.valueUnavailable, .pixelsAndGeometry, tag: tag, severity: .limitation)
        }
        if frame == nil {
            record(.valueUnavailable, .codestream, severity: .limitation)
            record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
        }
        return !stopped
    }

    /// Samples per Pixel follows the Photometric Interpretation; color samples are unsigned.
    mutating func checkPhotometricCompanions(colorValues: Set<String>, knownValues: Set<String>) {
        guard let value = string(0x00280004), knownValues.contains(value) else {
            record(.valueUnavailable, .pixelsAndGeometry, tag: 0x00280004, severity: .limitation); return
        }
        let color = colorValues.contains(value)
        if let samples = number(0x00280002), samples != (color ? 3 : 1) { record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280002) }
        if color, let signed = number(0x00280103), signed != 0 { record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280103) }
    }

    /// Declared attribute values against the codestream's own.
    mutating func compare(_ pairs: [(tag: Int, actual: Int)]) {
        for (tag, actual) in pairs {
            if let declared = number(tag) {
                if declared != actual { record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: tag) }
            } else { record(.valueUnavailable, .pixelsAndGeometry, tag: tag, severity: .limitation) }
        }
    }

    /// Bits Stored against the codestream's sample precision. A codestream whose precision differs from
    /// Bits Stored but fits Bits Allocated still decodes into the declared container (GDCM writes JPEG-LS and
    /// JPEG 2000 at the allocated depth): the header contradicts the payload, the samples stay readable, so
    /// the contradiction is a warning. A precision above Bits Allocated cannot be stored and stays an error
    /// (issue #2487).
    mutating func compareBitsStored(_ actual: Int) {
        guard let declared = number(0x00280101) else {
            record(.valueUnavailable, .pixelsAndGeometry, tag: 0x00280101, severity: .limitation); return
        }
        guard declared != actual else { return }
        let fits = number(0x00280100).map { actual <= $0 } ?? false
        record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280101, severity: fits ? .warning : .error)
    }
}
