import Foundation

/// Current single-frame Overlay Plane requirements (C.9.2), independently of tolerant legacy display.
public enum DicomOverlayPlaneModule {
    private static let elements = [0x0010, 0x0011, 0x0015, 0x0022, 0x0040, 0x0045, 0x0050,
        0x0051, 0x0100, 0x0102, 0x1301, 0x1302, 0x1303, 0x1500, 0x3000]

    public static func validate(_ dataSet: DicomDataSet,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        var report = DicomValidationReport()
        var remaining = limits.maximumRuleEvaluations
        for group in stride(from: 0x6000, through: 0x601E, by: 2) {
            let base = group << 16
            guard elements.contains(where: { dataSet.contains(base | $0) }) else { continue }
            guard report.diagnostics.count < limits.maximumDiagnostics else { return report }
            guard remaining > 0 else {
                return report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached,
                    severity: .limitation, layer: .pixelsAndGeometry, path: [.tag(base | 0x3000)])]))
            }
            let rules: [DicomAttributeRule] = [
                .init(tag: base | 0x0010, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...65535)]),
                .init(tag: base | 0x0011, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...65535)]),
                .init(tag: base | 0x0040, requirement: .type1, constraints: [.strings(["G", "R"])]),
                .init(tag: base | 0x0050, requirement: .type1, constraints: [.valueCount(2...2)]),
                .init(tag: base | 0x0100, requirement: .type1, constraints: [.integers([1])]),
                .init(tag: base | 0x0102, requirement: .type1, constraints: [.integers([0])]),
                .init(tag: base | 0x3000, requirement: .type1)
            ]
            let attributes = DicomAttributeValidator.evaluate(dataSet, rules: rules,
                limits: .init(maximumDepth: limits.maximumDepth, maximumRuleEvaluations: remaining,
                              maximumDiagnostics: limits.maximumDiagnostics - report.diagnostics.count))
            remaining -= attributes.evaluations
            report = report.merging(attributes.report).limitingDiagnostics(to: limits.maximumDiagnostics)
            guard report.diagnostics.count < limits.maximumDiagnostics else { return report }
            guard !attributes.report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else {
                return report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached,
                    severity: .limitation, layer: .pixelsAndGeometry, path: [.tag(base | 0x3000)])]))
            }
            guard remaining > 0 else {
                return report.merging(.init(diagnostics: [.init(code: .evaluationLimitReached,
                    severity: .limitation, layer: .pixelsAndGeometry, path: [.tag(base | 0x3000)])]))
            }
            remaining -= 1
            let code: DicomValidationReport.Code?
            let severity: DicomValidationReport.Severity
            if dataSet.contains(base | 0x0015) || dataSet.contains(base | 0x0051) {
                // The Multi-frame Overlay module is separate; do not assume one frame or repair its metadata.
                code = .moduleRuleUnavailable
                severity = .limitation
            } else if let rows = dimension(dataSet[base | 0x0010]),
                      let columns = dimension(dataSet[base | 0x0011]),
                      let element = dataSet[base | 0x3000], [.OB, .OW].contains(element.vr),
                      case .bytes(let bytes) = element.value {
                let bits = UInt64(rows) * UInt64(columns)
                let byteCount = (bits + 7) / 8
                let paddedCount = byteCount + byteCount % 2
                if UInt64(bytes.count) != paddedCount {
                    code = .pixelDataLengthMismatch
                    severity = .error
                } else if [0x1301, 0x1302, 0x1303].contains(where: { dataSet.contains(base | $0) }) {
                    code = .semanticScopeUnavailable
                    severity = .limitation
                } else {
                    code = nil
                    severity = .error
                }
            } else {
                code = .valueUnavailable
                severity = .limitation
            }
            report = report.merging(.init(evaluatedLayers: [.pixelsAndGeometry], diagnostics: code.map {
                [.init(code: $0, severity: severity, layer: .pixelsAndGeometry, path: [.tag(base | 0x3000)])]
            } ?? []))
        }
        return report
    }

    private static func dimension(_ element: DicomDataElement?) -> Int? {
        guard let element, element.vr == .US, element.vm.count == 1,
              let value = element.intValue, (1...65535).contains(value) else { return nil }
        return value
    }
}
