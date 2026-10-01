import DicomCodecs
import Foundation

/// PS3.5 8.2.1 pixel metadata composed with actual SOF/SOS evidence from one assembled JPEG frame.
public enum DicomJPEGFrameValidator {
    public static func rules(for syntax: DicomTransferSyntax) -> [DicomAttributeRule] {
        guard supported.contains(syntax) else { return [] }
        let lossless = syntax == .jpegLossless || syntax == .jpegLosslessFirstOrder
        let precision: [Int] = lossless ? Array(1...16) : syntax == .jpegBaseline ? [8] : [8, 12]
        let photos = lossless ? ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL"] :
            syntax == .jpegBaseline ? ["MONOCHROME1", "MONOCHROME2", "RGB", "YBR_FULL_422"] : ["MONOCHROME1", "MONOCHROME2"]
        return [0x00280010, 0x00280011].map {
            .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...65535)])
        } + [
            .init(tag: 0x00280002, requirement: .type1, constraints: [.valueCount(1...1), .integers(syntax == .jpegExtended ? [1] : [1, 3])]),
            .init(tag: 0x00280004, requirement: .type1, constraints: [.valueCount(1...1), .strings(Set(photos))]),
            .init(tag: 0x00280006, requirement: .type1C, condition: .integerGreaterThan(0x00280002, 1), constraints: [.valueCount(1...1), .integers([0])]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.valueCount(1...1), .integers(syntax == .jpegBaseline ? [8] : [8, 16])]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.valueCount(1...1), .integers(Set(precision)), .integerLessThanOrEqualAttribute(0x00280100)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.valueCount(1...1), .integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.valueCount(1...1), .integers(lossless ? [0, 1] : [0])])
        ]
    }

    /// Header evidence never silently promotes entropy, table correctness, ICC matching or an entire IOD to passed.
    public static func validate(_ dataSet: DicomDataSet, frame: Data?, transferSyntax: DicomTransferSyntax,
                                frameIndex: Int = 0, maximumEncodedBytes: Int = 64 * 1024 * 1024,
                                attributeLimits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let location: [DicomValidationReport.PathComponent] = [.tag(0x7FE00010)] + (frameIndex >= 0 ? [.frame(frameIndex)] : [])
        guard supported.contains(transferSyntax) else {
            return .init(diagnostics: [.init(code: .codestreamRuleUnavailable, severity: .limitation, layer: .codestream, path: location)])
        }
        let evaluated: Set<DicomValidationReport.Layer> = [.attributes, .pixelsAndGeometry, .codestream]
        var diagnostics = DicomAttributeValidator.validate(dataSet, rules: rules(for: transferSyntax), limits: attributeLimits).diagnostics
        var stopped = false
        func stop() {
            guard !stopped else { return }
            for layer in [DicomValidationReport.Layer.codestream, .pixelsAndGeometry] {
                diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: layer, path: location))
            }
            stopped = true
        }
        func record(_ code: DicomValidationReport.Code, _ layer: DicomValidationReport.Layer, tag: Int = 0x7FE00010,
                    severity: DicomValidationReport.Severity = .error) {
            guard !stopped else { return }
            guard diagnostics.count < attributeLimits.maximumDiagnostics else { stop(); return }
            diagnostics.append(.init(code: code, severity: severity, layer: layer,
                path: [.tag(tag)] + (frameIndex >= 0 ? [.frame(frameIndex)] : []), requirement: .type1))
        }
        func number(_ tag: Int) -> Int? {
            guard let element = dataSet[tag], element.vr == .US, element.vm.count == 1,
                  let value = element.intValue, (0...65535).contains(value) else { return nil }
            return value
        }
        if diagnostics.contains(where: { $0.code == .evaluationLimitReached }) { stop() }
        guard !stopped else { return .init(evaluatedLayers: evaluated, diagnostics: diagnostics) }
        guard frameIndex >= 0 else {
            record(.referenceSelectionInvalid, .pixelsAndGeometry)
            record(.valueUnavailable, .codestream, severity: .limitation)
            return .init(evaluatedLayers: evaluated, diagnostics: diagnostics)
        }
        let lossless = transferSyntax == .jpegLossless || transferSyntax == .jpegLosslessFirstOrder
        if let photo = dataSet[0x00280004], photo.vr == .CS, case .strings(let values) = photo.value, values.count == 1, values[0].utf8.count <= 16 {
            let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            if ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL", "YBR_FULL_422"].contains(value) {
                let monochrome = ["MONOCHROME1", "MONOCHROME2"].contains(value)
                if let samples = number(0x00280002), samples != (["RGB", "YBR_FULL", "YBR_FULL_422"].contains(value) ? 3 : 1) {
                    record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280002)
                }
                if !monochrome, let signed = number(0x00280103), signed != 0 { record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280103) }
            } else { record(.valueUnavailable, .pixelsAndGeometry, tag: 0x00280004, severity: .limitation) }
        } else { record(.valueUnavailable, .pixelsAndGeometry, tag: 0x00280004, severity: .limitation) }
        for tag in [0x00280100, 0x00280102, 0x00280103] where number(tag) == nil {
            record(.valueUnavailable, .pixelsAndGeometry, tag: tag, severity: .limitation)
        }
        if !lossless, let stored = number(0x00280101), [8, 12].contains(stored),
           let allocated = number(0x00280100), allocated != (stored == 8 ? 8 : 16) {
            record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280100)
        }
        guard !stopped else { return .init(evaluatedLayers: evaluated, diagnostics: diagnostics) }
        guard let frame else {
            record(.valueUnavailable, .codestream, severity: .limitation)
            record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
            return .init(evaluatedLayers: evaluated, diagnostics: diagnostics)
        }
        do {
            let actual = try DicomJPEGFrameInspector.inspect(frame, maximumEncodedBytes: maximumEncodedBytes)
            let expected: UInt8 = lossless ? 0xC3 : transferSyntax == .jpegBaseline ? 0xC0 : 0xC1
            if actual.startOfFrame != expected || (transferSyntax == .jpegLosslessFirstOrder && actual.scans.contains(where: { $0.predictor != 1 })) {
                record(.codestreamProfileMismatch, .codestream)
            }
            for (tag, actualValue) in [(0x00280010, actual.height), (0x00280011, actual.width), (0x00280002, actual.components.count)] {
                if let declared = number(tag) {
                    if declared != actualValue { record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: tag) }
                } else { record(.valueUnavailable, .pixelsAndGeometry, tag: tag, severity: .limitation) }
            }
            // Bits Stored: a precision that fits Bits Allocated still decodes into the declared container, so the
            // contradiction is a warning; one above it stays an error (issue #2487, as in the other codestreams).
            if let declaredStored = number(0x00280101) {
                if declaredStored != actual.precision {
                    let fits = number(0x00280100).map { actual.precision <= $0 } ?? false
                    record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280101, severity: fits ? .warning : .error)
                }
            } else { record(.valueUnavailable, .pixelsAndGeometry, tag: 0x00280101, severity: .limitation) }
            if actual.components.count > 1 {
                record(.codestreamColorProfileUnavailable, .pixelsAndGeometry, severity: .limitation)
            }
            // B.2.3: a scan that selects an undefined Huffman or quantization table cannot be decoded.
            if actual.scans.contains(where: { !$0.tablesDefined }) { record(.invalidCodestream, .codestream) }
            // PS3.5 8.2.1: YBR_FULL_422 subsamples the chroma components horizontally; every other value is 1:1.
            if let photo = dataSet[0x00280004], case .strings(let values) = photo.value, values.count == 1, actual.components.count == 3 {
                let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
                let sampling = actual.components.map { ($0.horizontalSampling, $0.verticalSampling) }
                let subsampled = sampling[0] == (2, 1) && sampling[1] == (1, 1) && sampling[2] == (1, 1)
                let full = sampling.allSatisfy { $0 == sampling[0] }
                // A 4:2:0 frame declared YBR_FULL_422 (or a subsampled frame declared YBR_FULL) is what most
                // vendors write for JPEG cine: decoders take the sampling from the frame, so the contradiction
                // is a warning, not an integrity error (issue #2487). The component count stays an error above.
                if value == "YBR_FULL_422" ? !subsampled : ["RGB", "YBR_FULL"].contains(value) && !full {
                    record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280004, severity: .warning)
                }
            }
            // The toolkit decodes lossless (Annex H) and extended 12-bit (Annex F) frames natively; that decode verifies the
            // entropy-coded segments. Baseline frames are delegated to ImageIO and stay unverified here.
            switch actual.startOfFrame {
            case 0xC3:
                if let result = try? JPEGLosslessDecoder().decode(data: frame),
                   result.width == actual.width, result.height == actual.height, result.componentCount == actual.components.count,
                   result.pixels.count == actual.width * actual.height * actual.components.count {} else { record(.invalidCodestream, .codestream) }
            case 0xC1:
                if let result = try? JPEGExtendedDecoder.decode(frame), result.width == actual.width, result.height == actual.height,
                   result.pixels.count == actual.width * actual.height {} else { record(.invalidCodestream, .codestream) }
            case 0xC0, 0xC2:
                // The own DCT decoder (DicomJPEG) verifies the entropy-coded segments of baseline and progressive frames.
                let descriptor = DicomCompressedFrameDescriptor(
                    transferSyntaxUID: transferSyntax.rawValue, rows: actual.height, columns: actual.width,
                    bitsAllocated: actual.precision > 8 ? 16 : 8, bitsStored: actual.precision, highBit: actual.precision - 1,
                    pixelRepresentation: 0, samplesPerPixel: actual.components.count,
                    photometricInterpretation: actual.components.count == 3 ? "YBR_FULL" : "MONOCHROME2", planarConfiguration: nil)
                if (try? DicomJPEGSwiftBackend.decodeSynchronously(frame, descriptor: descriptor)) == nil { record(.invalidCodestream, .codestream) }
            default:
                record(.codestreamPayloadUnverified, .codestream, severity: .limitation)
            }
        } catch DicomJPEGFrameInspector.Failure.limitExceeded {
            stop()
        } catch DicomJPEGFrameInspector.Failure.unsupportedProcess {
            record(.codestreamRuleUnavailable, .codestream, severity: .limitation)
            record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
        } catch {
            record(.invalidCodestream, .codestream)
            record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
        }
        return .init(evaluatedLayers: evaluated, diagnostics: diagnostics)
    }

    private static let supported: Set<DicomTransferSyntax> = [.jpegBaseline, .jpegExtended, .jpegLossless, .jpegLosslessFirstOrder]
}
