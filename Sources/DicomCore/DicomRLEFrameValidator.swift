import Foundation

/// Composes PS3.5 Table 8.2.2-1 metadata with the actual Annex G frame stream.
/// Encapsulation/frame mapping, full Image Pixel/IOD rules and display operations remain separate.
public enum DicomRLEFrameValidator {
    public static var rules: [DicomAttributeRule] {
        [0x00280010, 0x00280011].map {
            .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...65535)])
        } + [
            .init(tag: 0x00280002, requirement: .type1, constraints: [.valueCount(1...1), .integers([1, 3])]),
            .init(tag: 0x00280004, requirement: .type1, constraints: [.valueCount(1...1), .strings(["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL"])]),
            .init(tag: 0x00280006, requirement: .type1C, condition: .integerGreaterThan(0x00280002, 1),
                  constraints: [.valueCount(1...1), .integers([0, 1])]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.valueCount(1...1), .integers([1, 8, 16])]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...16), .integerLessThanOrEqualAttribute(0x00280100)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.valueCount(1...1), .integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.valueCount(1...1), .integers([0, 1])])
        ]
    }

    /// The caller supplies one assembled frame and its original zero-based index, not a fragment or repaired payload.
    public static func validate(_ dataSet: DicomDataSet, frame: Data?, frameIndex: Int = 0,
                                transferSyntax: DicomTransferSyntax = .rleLossless,
                                limits: DicomRLECodec.Limits = .init(),
                                attributeLimits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let location: [DicomValidationReport.PathComponent] = [.tag(0x7FE00010)] + (frameIndex >= 0 ? [.frame(frameIndex)] : [])
        guard transferSyntax == .rleLossless else {
            return .init(diagnostics: [.init(code: .codestreamRuleUnavailable, severity: .limitation, layer: .codestream, path: location)])
        }
        var diagnostics = DicomAttributeValidator.validate(dataSet, rules: rules, limits: attributeLimits).diagnostics
        var stopped = false
        func stop() {
            guard !stopped else { return }
            for layer in [DicomValidationReport.Layer.codestream, .pixelsAndGeometry] {
                diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: layer, path: location))
            }
            stopped = true
        }
        func record(_ code: DicomValidationReport.Code, _ layer: DicomValidationReport.Layer, tag: Int? = nil,
                    severity: DicomValidationReport.Severity = .error) {
            guard !stopped else { return }
            guard diagnostics.count < attributeLimits.maximumDiagnostics else { stop(); return }
            diagnostics.append(.init(code: code, severity: severity, layer: layer, path: tag.map { [.tag($0), .frame(max(0, frameIndex))] } ?? location, requirement: .type1))
        }
        func number(_ tag: Int) -> Int? {
            guard let element = dataSet[tag], element.vr == .US, element.vm.count == 1, let value = element.intValue,
                  (0...65535).contains(value) else { return nil }
            return value
        }
        let evaluated: Set<DicomValidationReport.Layer> = [.attributes, .codestream, .pixelsAndGeometry]
        guard frameIndex >= 0 else {
            record(.referenceSelectionInvalid, .pixelsAndGeometry)
            record(.valueUnavailable, .codestream, severity: .limitation)
            return .init(evaluatedLayers: evaluated, diagnostics: diagnostics)
        }
        guard !diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else {
            stop()
            return .init(evaluatedLayers: evaluated, diagnostics: diagnostics)
        }
        guard let rows = number(0x00280010), let columns = number(0x00280011), rows > 0, columns > 0,
              let bits = number(0x00280100), [1, 8, 16].contains(bits), let samples = number(0x00280002), [1, 3].contains(samples) else {
            record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
            record(.valueUnavailable, .codestream, severity: .limitation)
            return .init(evaluatedLayers: evaluated, diagnostics: diagnostics)
        }
        if let photo = dataSet[0x00280004], photo.vr == .CS, case .strings(let values) = photo.value, values.count == 1, values[0].utf8.count <= 16 {
            let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            if ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL"].contains(value) {
                let monochrome = ["MONOCHROME1", "MONOCHROME2"].contains(value)
                if samples != (["RGB", "YBR_FULL"].contains(value) ? 3 : 1) { record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280002) }
                if !monochrome && bits == 1 { record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280100) }
                if !monochrome, let representation = number(0x00280103), representation != 0 { record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280103) }
            } else { record(.valueUnavailable, .pixelsAndGeometry, tag: 0x00280004, severity: .limitation) }
        } else { record(.valueUnavailable, .pixelsAndGeometry, tag: 0x00280004, severity: .limitation) }
        for tag in [0x00280101, 0x00280102, 0x00280103] where number(tag) == nil {
            record(.valueUnavailable, .pixelsAndGeometry, tag: tag, severity: .limitation)
        }
        guard !stopped else { return .init(evaluatedLayers: evaluated, diagnostics: diagnostics) }
        guard let frame else {
            record(.valueUnavailable, .codestream, severity: .limitation)
            record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
            return .init(evaluatedLayers: evaluated, diagnostics: diagnostics)
        }
        do {
            let actual = try DicomRLECodec.inspect(frame, width: columns, height: rows, limits: limits)
            if actual.segmentCount != samples * ((bits + 7) / 8) { record(.pixelMetadataContradiction, .pixelsAndGeometry) }
            if actual.runsCrossRowBoundaries { record(.codestreamRowBoundaryViolation, .codestream) }
            if actual.literalTriples { record(.codestreamReplicateRunRequired, .codestream) }
            if actual.oddSegmentLength { record(.codestreamSegmentPaddingMissing, .codestream) }
            if bits == 1 && actual.containsNonBinarySamples { record(.pixelMetadataContradiction, .pixelsAndGeometry, tag: 0x00280100) }
        } catch DicomRLECodec.Failure.limitExceeded {
            stop()
        } catch {
            record(.invalidCodestream, .codestream)
            record(.valueUnavailable, .pixelsAndGeometry, severity: .limitation)
        }
        return .init(evaluatedLayers: evaluated, diagnostics: diagnostics)
    }
}
