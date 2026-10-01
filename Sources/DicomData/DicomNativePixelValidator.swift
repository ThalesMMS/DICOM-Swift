import Foundation

/// Native Pixel Data allocation/length evidence from PS3.5 8.1/8.2, not full IOD or patient-space geometry.
public enum DicomNativePixelValidator {
    public static func validate(_ parsed: DicomDataSetValidationResult, transferSyntax: DicomTransferSyntax,
                                maximumFrames: Int = 1024, maximumFrameBytes: Int = 64 * 1024 * 1024,
                                attributeLimits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var report = DicomValidationReport(evaluatedLayers: [.pixelsAndGeometry])
        var stopped = false
        func record(_ code: DicomValidationReport.Code, tag: Int = 0x7FE00010,
                    severity: DicomValidationReport.Severity = .error, layer: DicomValidationReport.Layer = .pixelsAndGeometry) {
            guard !stopped else { return }
            if report.diagnostics.count >= attributeLimits.maximumDiagnostics {
                report = report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached, severity: .limitation, layer: .pixelsAndGeometry),
                    .init(code: .evaluationLimitReached, severity: .limitation, layer: .attributes)]))
                stopped = true; return
            }
            report = report.merging(.init(diagnostics: [.init(code: code, severity: severity, layer: layer, path: [.tag(tag)])]))
        }
        guard parsed.purpose == .instance, let dataSet = parsed.dataSet,
              !transferSyntax.registryEntry.isEncapsulated, !transferSyntax.usesDataSetDeflate else {
            record(.valueUnavailable, severity: .limitation); return report
        }
        guard !parsed.pixelDataHeadersTruncated else { record(.evaluationLimitReached, severity: .limitation); return report }
        let headers = parsed.pixelDataHeaders.filter { $0.path.count == 1 }
        let alternatives = headers.count + (dataSet.contains(0x00287FE0) ? 1 : 0)
        guard alternatives <= 1 else { record(.exclusiveAttributeChoiceInvalid); return report }
        guard let header = headers.first, case .tag(let tag) = header.path[0] else {
            record(.valueUnavailable, severity: .limitation); return report
        }
        let floating = tag != 0x7FE00010
        let rules: [DicomAttributeRule] = [0x00280010, 0x00280011, 0x00280002, 0x00280100].map {
            .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...65535)])
        } + [
            .init(tag: 0x00280004, requirement: .type1, constraints: [.valueCount(1...1)]),
            .init(tag: 0x00280008, requirement: .type3, constraints: [.valueCount(1...1), .integerRange(1...Int.max)]),
            .init(tag: 0x00280006, requirement: .type1C, condition: .integerGreaterThan(0x00280002, 1), constraints: [.valueCount(1...1), .integers([0, 1])]),
            .init(tag: 0x00280101, requirement: .type1C, condition: .known(floating ? .unsatisfied : .satisfied),
                  constraints: [.valueCount(1...1), .integerRange(1...65535), .integerLessThanOrEqualAttribute(0x00280100)]),
            .init(tag: 0x00280102, requirement: .type1C, condition: .known(floating ? .unsatisfied : .satisfied),
                  constraints: [.valueCount(1...1), .integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1C, condition: .known(floating ? .unsatisfied : .satisfied), constraints: [.valueCount(1...1), .integers([0, 1])])
        ]
        report = report.merging(DicomAttributeValidator.validate(dataSet, rules: rules, limits: attributeLimits))
        guard !report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else {
            record(.evaluationLimitReached, severity: .limitation); return report
        }
        func number(_ tag: Int, vr: DicomVR = .US) -> Int? {
            guard let element = dataSet[tag], element.vr == vr, element.vm.count == 1, let value = element.intValue, value > 0 else { return nil }
            return value
        }
        guard let rows = number(0x00280010), let columns = number(0x00280011), let samples = number(0x00280002), let bits = number(0x00280100),
              [rows, columns, samples, bits].allSatisfy({ $0 <= 65535 }),
              let frames = dataSet.contains(0x00280008) ? number(0x00280008, vr: .IS) : 1 else {
            record(.valueUnavailable, tag: tag, severity: .limitation); return report
        }
        guard frames <= max(0, maximumFrames) else { record(.evaluationLimitReached, tag: tag, severity: .limitation); return report }
        if floating {
            let expectedBits = tag == 0x7FE00008 ? 32 : 64
            if bits != expectedBits { record(.pixelMetadataContradiction, tag: 0x00280100) }
            if header.vr != (tag == 0x7FE00008 ? .OF : .OD) { record(.incompatibleVR, tag: tag) }
        } else {
            guard bits == 1 || bits.isMultiple(of: 8) else {
                record(.pixelMetadataContradiction, tag: 0x00280100); return report
            }
            if header.vr != .OW && !(transferSyntax.isExplicitVR && bits <= 8 && header.vr == .OB) {
                // PS3.5 A.2: word samples take OW. Under little endian an OB header reads the same bytes, so the
                // wrong VR is a warning; under big endian the VR decides the byte order and stays an error (#2487).
                let readable = transferSyntax.isExplicitVR && !transferSyntax.isBigEndian && header.vr == .OB
                record(.incompatibleVR, tag: tag, severity: readable ? .warning : .error)
            }
            for required in [0x00280101, 0x00280102, 0x00280103] {
                guard let element = dataSet[required], element.vr == .US, element.vm.count == 1 else {
                    record(.valueUnavailable, tag: required, severity: .limitation); continue
                }
            }
        }
        guard header.valueLength != UInt32.max else { record(.invalidValueLength, tag: tag); return report }
        guard let photo = dataSet[0x00280004], photo.vr == .CS, case .strings(let values) = photo.value,
              values.count == 1, values[0].utf8.count <= 16 else { record(.valueUnavailable, severity: .limitation); return report }
        let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        if ["YBR_RCT", "YBR_ICT", "YBR_PARTIAL_420"].contains(value) { record(.pixelMetadataContradiction, tag: 0x00280004); return report }
        guard ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR", "RGB", "YBR_FULL", "YBR_FULL_422"].contains(value) else {
            record(.valueUnavailable, tag: 0x00280004, severity: .limitation); return report
        }
        let color = ["RGB", "YBR_FULL", "YBR_FULL_422"].contains(value)
        if samples != (color ? 3 : 1) { record(.pixelMetadataContradiction, tag: 0x00280002) }
        let subsampled = value == "YBR_FULL_422"
        if subsampled {
            if dataSet[0x00280006]?.intValue != 0 { record(.pixelMetadataContradiction, tag: 0x00280006) }
            if !columns.isMultiple(of: 2) { record(.pixelMetadataContradiction, tag: 0x00280011); return report }
            // PS3.3's row example is inconsistent with horizontal-only sampling; odd rows remain unqualified.
            if !rows.isMultiple(of: 2) { record(.valueUnavailable, tag: 0x00280010, severity: .limitation) }
        }
        var frameBits: UInt64 = 1
        for factor in [rows, columns, subsampled ? 2 : samples, bits] {
            let product = frameBits.multipliedReportingOverflow(by: UInt64(factor))
            guard !product.overflow else { record(.evaluationLimitReached, tag: tag, severity: .limitation); return report }
            frameBits = product.partialValue
        }
        let frameBytes = frameBits / 8 + (frameBits.isMultiple(of: 8) ? 0 : 1)
        guard frameBytes <= UInt64(max(0, maximumFrameBytes)) else { record(.evaluationLimitReached, tag: tag, severity: .limitation); return report }
        let total = frameBits.multipliedReportingOverflow(by: UInt64(frames))
        guard !total.overflow else { record(.evaluationLimitReached, tag: tag, severity: .limitation); return report }
        let bytes = total.partialValue / 8 + (total.partialValue.isMultiple(of: 8) ? 0 : 1)
        let evenBytes = bytes + (bytes.isMultiple(of: 2) ? 0 : 1)
        if UInt64(header.valueLength) != evenBytes { record(.pixelDataLengthMismatch, tag: tag) }
        // Padding and unused high bits are not required to be zero. No sample-value or patient-space claims are made.
        return report
    }
}
