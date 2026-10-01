import Foundation

/// Shared C.7.6.1.1.6 icon restrictions, with the additional C.18.4 SR size limit by default.
public enum DicomSRIconImageValidator {
    public enum Kind: Sendable { case structuredReport, generalImage }
    public enum PixelDataSource: Sendable {
        /// Pixel Data contains the native encoded value, including even-length padding.
        case native
        /// Pixel Data contains encapsulated bytes; decoding is not supplied by this component.
        case encapsulated
        /// The parser/caller omitted Pixel Data. Absence in the owned metadata is not source absence.
        case omitted
    }

    /// Metadata only, suitable for nested parsed icons whose Pixel Data was intentionally omitted.
    public static var rules: [DicomAttributeRule] { rules(for: .structuredReport) }

    public static func rules(for kind: Kind) -> [DicomAttributeRule] {
        let maximumDimension = kind == .structuredReport ? 128 : 65535
        let palette = DicomAttributeRule.Condition.any([
            .stringEquals(0x00280004, "PALETTE COLOR"),
            .all([.present(0x00089205), .any([.stringEquals(0x00089205, "COLOR"), .stringEquals(0x00089205, "MIXED")])])
        ])
        return [
            .init(tag: 0x00280002, requirement: .type1, constraints: [.integerRange(1...1), .valueCount(1...1)]),
            .init(tag: 0x00280004, requirement: .type1, constraints: [.strings(["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR"]), .valueCount(1...1)]),
            .init(tag: 0x00280010, requirement: .type1, constraints: [.integerRange(1...maximumDimension), .valueCount(1...1)]),
            .init(tag: 0x00280011, requirement: .type1, constraints: [.integerRange(1...maximumDimension), .valueCount(1...1)]),
            .init(tag: 0x00280100, requirement: .type1, constraints: [.integers([1, 8]), .valueCount(1...1),
                .requiredCondition(.any([.not(palette), .integerGreaterThan(0x00280100, 7)]))]),
            .init(tag: 0x00280101, requirement: .type1, constraints: [.integers([1, 8]), .valueCount(1...1),
                .integerLessThanOrEqualAttribute(0x00280100)]),
            .init(tag: 0x00280102, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280101, offset: -1)]),
            .init(tag: 0x00280103, requirement: .type1, constraints: [.integerRange(0...0), .valueCount(1...1)])
        ] + [0x00280006, 0x00280034].map {
            .init(tag: $0, requirement: .type3, constraints: [.forbiddenWhen(.known(.satisfied))])
        } + [0x00281101, 0x00281102, 0x00281103].map {
            .init(tag: $0, requirement: .type1C, condition: palette, constraints: [.valueCount(3...3)])
        } + [0x00281201, 0x00281202, 0x00281203].map {
            .init(tag: $0, requirement: .type1C, condition: palette)
        } + [0x00282000, 0x00282002].map {
            .init(tag: $0, requirement: .type3, constraints: [.forbiddenWhen(.present(0x00480105))])
        }
    }

    public static func validate(_ icon: DicomDataSet, pixelDataSource: PixelDataSource,
                                kind: Kind = .structuredReport,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let pixelRule: [DicomAttributeRule] = pixelDataSource == .omitted ? [] : [.init(tag: 0x7FE00010, requirement: .type1)]
        let attributes = DicomAttributeValidator.evaluate(icon, rules: rules(for: kind) + pixelRule, limits: limits)
        var state = State(limits: limits, maximumDimension: kind == .structuredReport ? 128 : 65535,
                          work: attributes.evaluations, diagnostics: attributes.report.diagnostics,
                          stopped: attributes.report.diagnostics.contains { $0.code == .evaluationLimitReached })
        if state.stopped {
            state.diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .pixelsAndGeometry))
        } else {
            state.validatePixels(icon, source: pixelDataSource)
        }
        return .init(evaluatedLayers: [.attributes, .pixelsAndGeometry], diagnostics: state.diagnostics)
    }

    private struct State {
        let limits: DicomAttributeValidator.Limits
        let maximumDimension: Int
        var work: Int
        var diagnostics: [DicomValidationReport.Diagnostic]
        var stopped: Bool

        mutating func record(_ code: DicomValidationReport.Code, tag: Int,
                             severity: DicomValidationReport.Severity = .error) {
            guard !stopped else { return }
            guard diagnostics.count < limits.maximumDiagnostics, work < limits.maximumRuleEvaluations else {
                diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation,
                    layer: .pixelsAndGeometry, path: [.tag(tag)]))
                stopped = true
                return
            }
            work += 1
            diagnostics.append(.init(code: code, severity: severity, layer: .pixelsAndGeometry, path: [.tag(tag)]))
        }

        mutating func numbers(_ icon: DicomDataSet, tag: Int, count: Int) -> [Int]? {
            guard !stopped else { return nil }
            guard work < limits.maximumRuleEvaluations else {
                record(.evaluationLimitReached, tag: tag, severity: .limitation)
                return nil
            }
            work += 1
            guard let element = icon[tag], element.vr == .US, element.vm.count == count,
                  element.intValues.count == count, element.intValues.allSatisfy({ (0...65535).contains($0) }) else {
                record(.valueUnavailable, tag: tag, severity: .limitation)
                return nil
            }
            return element.intValues
        }

        mutating func validatePixels(_ icon: DicomDataSet, source: PixelDataSource) {
            if source == .omitted {
                record(.valueUnavailable, tag: 0x7FE00010, severity: .limitation)
            } else if source == .encapsulated {
                record(.moduleRuleUnavailable, tag: 0x7FE00010, severity: .limitation)
            } else if let rows = numbers(icon, tag: 0x00280010, count: 1)?.first,
                      let columns = numbers(icon, tag: 0x00280011, count: 1)?.first,
                      let bits = numbers(icon, tag: 0x00280100, count: 1)?.first,
                      let samples = numbers(icon, tag: 0x00280002, count: 1)?.first {
                if !(1...maximumDimension).contains(rows) || !(1...maximumDimension).contains(columns) || ![1, 8].contains(bits) || samples != 1 {
                    record(.pixelMetadataContradiction, tag: 0x7FE00010)
                } else if let pixel = icon[0x7FE00010], [.OB, .OW].contains(pixel.vr), case .bytes(let data) = pixel.value {
                    // Scalars are bounded above; rows * columns * bits cannot overflow.
                    let bytes = (rows * columns * bits + 7) / 8
                    if data.count != bytes + bytes % 2 { record(.pixelDataLengthMismatch, tag: 0x7FE00010) }
                } else {
                    record(.valueUnavailable, tag: 0x7FE00010, severity: .limitation)
                }
            }
            var previous: [Int]?
            for channel in 1...3 where icon.contains(0x00281100 + channel) || icon.contains(0x00281200 + channel) {
                guard !stopped, let descriptor = numbers(icon, tag: 0x00281100 + channel, count: 3) else { continue }
                if let previous, previous != descriptor { record(.pixelMetadataContradiction, tag: 0x00281100 + channel) }
                previous = descriptor
                guard [8, 16].contains(descriptor[2]) else { record(.pixelMetadataContradiction, tag: 0x00281100 + channel); continue }
                guard let element = icon[0x00281200 + channel], element.vr == .OW, case .bytes(let data) = element.value else {
                    record(.valueUnavailable, tag: 0x00281200 + channel, severity: .limitation)
                    continue
                }
                let entries = descriptor[0] == 0 ? 65536 : descriptor[0]
                let bytes = entries * (descriptor[2] / 8)
                if data.count != bytes + bytes % 2 { record(.pixelDataLengthMismatch, tag: 0x00281200 + channel) }
            }
            // ICC/color-space semantics and actual extrema require additional interpretation.
            for tag in [0x00282000, 0x00282002, 0x00280106, 0x00280107] where icon.contains(tag) {
                record(.moduleRuleUnavailable, tag: tag, severity: .limitation)
            }
        }
    }
}
